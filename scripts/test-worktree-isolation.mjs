// 2 つの linked worktree を実際に作り、片方の失敗をもう片方の status から観測する。
// --shared-key は一時コピーにだけ故障を入れる。同じテストが失敗するのが期待値。
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 1 && args[0] === '--shared-key'),
  '使い方: node scripts/test-worktree-isolation.mjs [--shared-key]');
const root = join(import.meta.dirname, '..');
const scratch = mkdtempSync(join(tmpdir(), 'dotagents-worktree-'));
const repo = join(scratch, 'main');
const trees = ['A', 'B'].map(name => join(scratch, name));
const profiles = join(scratch, 'profiles');
const gate = join(scratch, 'scripts/gate.sh');
const hook = join(scratch, 'hooks/dotagents-verify-gate.sh');
const env = Object.fromEntries(Object.entries(process.env)
  .filter(([name]) => !name.startsWith('DOTAGENTS_') && !name.startsWith('GIT_')));
Object.assign(env, { DOTAGENTS_GATE_DIR: join(scratch, 'gate'), DOTAGENTS_PROFILES: profiles,
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' });

function run(cwd, command, expectedExit = 0, input = '') {
  const result = spawnSync(command[0], command.slice(1), {
    cwd, env, input, encoding: 'utf8', timeout: 30_000,
  });
  if (result.error) throw result.error;
  assert.equal(result.status, expectedExit, result.stderr);
  return result.stdout;
}

function counts() {
  return trees.map(tree => {
    const status = JSON.parse(run(tree, ['bash', gate, 'status', '--json', tree]));
    assert.equal(status.armed, true, '両方の作業ツリーがゲートを継ぐ');
    return status.attempts.red ?? 0;
  });
}

try {
  for (const rel of ['scripts/gate.sh', 'hooks/dotagents-verify-gate.sh']) {
    let source = readFileSync(join(root, rel), 'utf8');
    if (args.length) {
      const start = /^gate_worktree_key\(\) \{[^\n]*$/gm;
      assert.equal([...source.matchAll(start)].length, 1, rel + ' に故障を入れる箇所');
      source = source.replace(start, "$&\n  printf 'A'\n  return 0");
    }
    const target = join(scratch, rel);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, source);
  }
  mkdirSync(profiles);
  writeFileSync(join(profiles, 'fixture.json'), JSON.stringify({
    match: { remote: 'example/worktree-isolation' }, max_attempts: 3,
    checks: [{ id: 'red', cmd: 'echo ran > check-ran; false', gate: true, agent_may_run: true }],
  }));
  mkdirSync(repo);
  run(repo, ['git', 'init', '-q']);
  run(repo, ['git', '-c', 'user.name=検証', '-c', 'user.email=fixture@example.invalid',
    '-c', 'commit.gpgsign=false', 'commit', '-qm', '初期状態', '--allow-empty']);
  run(repo, ['git', 'remote', 'add', 'origin', 'https://example.invalid/example/worktree-isolation.git']);
  for (const tree of trees) run(repo, ['git', 'worktree', 'add', '-q', '--detach', tree]);
  run(repo, ['bash', gate, 'arm', repo]);
  assert.deepEqual(counts(), [0, 0]);
  run(trees[0], ['bash', hook], 2, JSON.stringify({ cwd: trees[0], hook_event_name: 'Stop' }));
  assert.equal(readFileSync(join(trees[0], 'check-ran'), 'utf8'), 'ran\n');
  const observed = counts();
  console.log('A を1回失敗させた後の試行回数', JSON.stringify({ A: observed[0], B: observed[1] }));
  assert.deepEqual(observed, [1, 0], 'B の試行回数を消費した');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
