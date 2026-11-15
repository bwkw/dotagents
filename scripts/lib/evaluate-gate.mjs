// 実ゲートの固定課題を正常版と故障版へ同じ条件で適用する。ゲートの代わりに合否を決めるものではない。
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, copyFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const defaultRoot = fileURLToPath(new URL('../../', import.meta.url));
const hash = value => createHash('sha256').update(value).digest('hex');
const parse = value => { try { return JSON.parse(value); } catch { return null; } };

// 期待値は実装から計算しない。通過の終了コードだけでは未実行や Cursor の赤を見分けられない。
const scenarios = [
  { id: 'unarmed', expected: { exit: 0, ran: false } },
  { id: 'green', expected: { exit: 0, ran: true } },
  { id: 'red', expected: { exit: 2, ran: true } },
  { id: 'delegated', expected: { exit: 2, ran: false } },
  { id: 'no-profile', expected: { exit: 0, ran: false, checked: false, profile: null } },
  { id: 'uncovered', expected: { exit: 1, ran: false, checked: false, kind: 'not_checked' } },
  { id: 'cursor-red', expected: { exit: 0, ran: true, followup: true } },
];

function run(command, cwd, env, input = '') {
  const start = performance.now();
  const result = spawnSync(command[0], command.slice(1), {
    cwd, env, input, encoding: 'utf8', timeout: 20_000, maxBuffer: 2 * 1024 * 1024,
  });
  return {
    command, exit: result.status ?? -1, signal: result.signal,
    stdout: result.stdout ?? '', stderr: result.stderr ?? '',
    error: result.error?.message ?? null, durationMs: Math.round(performance.now() - start),
  };
}

function evaluateVariant(id, hook, gate, scratch, output) {
  const toolkit = join(scratch, id, 'toolkit');
  mkdirSync(join(toolkit, 'hooks'), { recursive: true });
  mkdirSync(join(toolkit, 'scripts'), { recursive: true });
  writeFileSync(join(toolkit, 'hooks/dotagents-verify-gate.sh'), hook);
  writeFileSync(join(toolkit, 'scripts/gate.sh'), gate);
  const cases = [];
  for (const scenario of scenarios) {
    const dir = join(scratch, id, scenario.id);
    const repo = join(dir, 'repo with spaces');
    const profiles = join(dir, 'profiles');
    mkdirSync(repo, { recursive: true });
    mkdirSync(profiles);
    // 親の verify の dry・時計・記録先や git の作業ツリー指定が、独立した課題へ漏れないようにする。
    const env = { ...process.env };
    for (const key of Object.keys(env)) {
      if (key.startsWith('DOTAGENTS_') || key.startsWith('GIT_')) delete env[key];
    }
    Object.assign(env, {
      DOTAGENTS_GATE_DIR: join(dir, 'state'), DOTAGENTS_PROFILES: profiles,
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    });
    const setup = [];
    const must = command => {
      const result = run(command, repo, env);
      setup.push(result);
      if (result.exit !== 0) throw new Error(`課題の準備に失敗: ${JSON.stringify(result)}`);
    };
    must(['git', 'init', '-q']);
    must(['git', 'remote', 'add', 'origin', 'https://example.invalid/fixture/evidence.git']);
    writeFileSync(join(repo, 'tracked.txt'), 'initial\n');
    must(['git', 'add', 'tracked.txt']);
    must(['git', '-c', 'user.name=検証', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', '初期状態']);
    const check = {
      id: 'fixture', cmd: 'printf ran > check-ran; test -f allow',
      gate: true, agent_may_run: scenario.id !== 'delegated',
      ...(scenario.id === 'uncovered' ? { paths: ['src/**'] } : {}),
    };
    const profile = {
      match: { remote: scenario.id === 'no-profile' ? 'unrelated/repository' : 'fixture/evidence' },
      checks: [check],
    };
    writeFileSync(join(profiles, 'fixture.json'), JSON.stringify(profile));
    if (scenario.id === 'green') writeFileSync(join(repo, 'allow'), 'yes');
    if (scenario.id === 'uncovered') writeFileSync(join(repo, 'tracked.txt'), 'changed\n');
    const gatePath = join(toolkit, 'scripts/gate.sh');
    // これはテスト用リポジトリの操作。実作業の arm は従来どおり da-verify だけが行う。
    if (!['unarmed', 'no-profile', 'uncovered'].includes(scenario.id)) must(['bash', gatePath, 'arm', repo]);
    const dry = ['no-profile', 'uncovered'].includes(scenario.id);
    const command = dry ? ['bash', gatePath, 'verify', '--json', repo]
      : ['bash', join(toolkit, 'hooks/dotagents-verify-gate.sh')];
    const payload = scenario.id === 'cursor-red'
      ? { cwd: repo, status: 'completed', loop_count: 0 }
      : { cwd: repo, hook_event_name: 'Stop' };
    const execution = run(command, repo, env, dry ? '' : JSON.stringify(payload));
    const parsed = parse(execution.stdout);
    const observed = { exit: execution.exit, ran: existsSync(join(repo, 'check-ran')) };
    if (dry) {
      observed.checked = parsed?.checked ?? null;
      if (scenario.id === 'no-profile') observed.profile = parsed?.profile ?? null;
      else observed.kind = parsed?.kind ?? null;
    }
    if (scenario.id === 'cursor-red') observed.followup = typeof parsed?.followup_message === 'string' && parsed.followup_message.length > 0;
    const artifact = `${id}/${scenario.id}.json`;
    mkdirSync(dirname(join(output, artifact)), { recursive: true });
    writeFileSync(join(output, artifact), JSON.stringify({
      scenario: scenario.id, profile, payload: dry ? null : payload, setup, execution,
      expected: scenario.expected, observed,
    }, null, 2) + '\n');
    cases.push({
      id: scenario.id, expected: scenario.expected, observed,
      passed: !execution.error && isDeepStrictEqual(observed, scenario.expected),
      command, artifact, durationMs: execution.durationMs,
    });
  }
  return {
    id, passed: cases.every(c => c.passed), cases,
    falseAllows: cases.filter(c => c.observed.exit === 0 && (
      [1, 2].includes(c.expected.exit) || (c.expected.followup === true && !c.observed.followup)
    )).length,
    falseBlocks: cases.filter(c => c.expected.exit === 0 && [1, 2].includes(c.observed.exit)).length,
  };
}

function main() {
  const args = process.argv.slice(2);
  let source = defaultRoot, output;
  for (let i = 0; i < args.length; i += 2) {
    if (!args[i + 1]) throw new Error('使い方: node scripts/lib/evaluate-gate.mjs --output <新規ディレクトリ> [--source <比較する checkout>]');
    if (args[i] === '--source') source = resolve(args[i + 1]);
    else if (args[i] === '--output') output = resolve(args[i + 1]);
    else throw new Error(`不明な引数: ${args[i]}`);
  }
  if (!output) throw new Error('--output に証拠を保持する新規ディレクトリが必要');
  const hook = readFileSync(join(source, 'hooks/dotagents-verify-gate.sh'), 'utf8');
  const gate = readFileSync(join(source, 'scripts/gate.sh'), 'utf8');
  // 排他的な mkdir で、過去の証拠を上書きしない。作業用領域と証拠の寿命を分ける。
  mkdirSync(output);
  const scratch = mkdtempSync(join(tmpdir(), 'dotagents-gate-evaluation-'));
  const start = performance.now();
  try {
    const baseline = evaluateVariant('baseline', hook, gate, scratch, output);
    const definitions = [
      { id: 'block-exit-removed', from: /exit 2/g, to: 'exit 0', reason: '拒否すべきターンが終了する' },
      { id: 'uncovered-accepted', from: '"$gate_ran" == "0"', to: '"$gate_ran" == "-1"', reason: '変更を受け持つ検査が無くても緑になる' },
      { id: 'cursor-followup-removed', from: 'followup_message: s.trimEnd()', to: 'ignored_message: s.trimEnd()', reason: '赤の続行要求がホストへ届かない' },
    ];
    const mutations = definitions.map(definition => {
      const changed = hook.replace(definition.from, definition.to);
      if (changed === hook) return { id: definition.id, reason: definition.reason, applied: false, detected: false, failedCases: [], cases: [] };
      const variant = evaluateVariant(definition.id, changed, gate, scratch, output);
      const failedCases = variant.cases.filter(c => !c.passed).map(c => c.id);
      return { ...variant, applied: true, reason: definition.reason, detected: failedCases.length > 0, failedCases };
    });
    const report = {
      version: 1, createdAt: new Date().toISOString(),
      target: {
        source, hookSha256: hash(hook), gateSha256: hash(gate),
        evaluatorSha256: hash(readFileSync(fileURLToPath(import.meta.url))),
        node: process.version, platform: process.platform,
      },
      baseline, mutations, durationMs: Math.round(performance.now() - start),
      limits: ['固定シナリオのみ。状態遷移の網羅的な証明ではない', 'ホストの実アプリ内での hook 配線・スキル選択は未確認', 'AIレビューの精度・トークン費用は測定していない'],
      passed: baseline.passed && mutations.every(m => m.applied && m.detected),
    };
    writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    // 再実行時に対象を取り違えないよう、観測対象の実バイト列も証拠側へ保持する。
    mkdirSync(join(output, 'target/hooks'), { recursive: true });
    mkdirSync(join(output, 'target/scripts/lib'), { recursive: true });
    // 実行中に元ファイルが編集されても、観測した版と保存する版は同じにする。
    writeFileSync(join(output, 'target/hooks/dotagents-verify-gate.sh'), hook);
    writeFileSync(join(output, 'target/scripts/gate.sh'), gate);
    copyFileSync(fileURLToPath(import.meta.url), join(output, 'target/scripts/lib/evaluate-gate.mjs'));
    console.log(JSON.stringify({ passed: report.passed, report: join(output, 'report.json') }));
    process.exitCode = report.passed ? 0 : 1;
  } catch (error) {
    writeFileSync(join(output, 'error.json'), JSON.stringify({ error: error.message }, null, 2) + '\n');
    throw error;
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

try { main(); } catch (error) { console.error(`[dotagents] ${error.message}`); process.exitCode = 1; }
