import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, existsSync, rmSync, mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const evaluator = join(root, 'scripts/lib/evaluate-gate.mjs');
const run = (args) => spawnSync(process.execPath, [evaluator, ...args], { encoding: 'utf8', timeout: 120_000 });

// ブロック処理が消えた時に、正常版と故障版の比較が成功と報告される事故を捕まえる。
test('実ゲートの固定シナリオを観測し、故障版だけを検出して証拠を残す', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'dotagents-evidence-test-'));
  try {
    const output = join(scratch, 'proof');
    const result = run(['--output', output]);
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(readFileSync(join(output, 'report.json'), 'utf8'));
    assert.equal(report.baseline.falseAllows, 0);
    assert.equal(report.baseline.falseBlocks, 0);
    assert.equal(report.baseline.passed, true);
    assert.deepEqual(report.baseline.cases.map(c => c.id), [
      'unarmed', 'green', 'red', 'delegated', 'no-profile', 'uncovered', 'cursor-red',
    ]);
    assert.equal(report.mutations.length, 3);
    assert.equal(report.mutations.find(m => m.id === 'cursor-followup-removed').falseAllows, 1);
    for (const mutation of report.mutations) {
      assert.equal(mutation.detected, true, mutation.id);
      assert.ok(mutation.failedCases.length > 0);
    }
    assert.match(report.target.hookSha256, /^[a-f0-9]{64}$/);
    for (const variant of [report.baseline, ...report.mutations]) {
      for (const c of variant.cases) {
        assert.equal(typeof c.observed.exit, 'number');
        assert.ok(Array.isArray(c.command));
        assert.ok(c.durationMs >= 0);
        assert.ok(existsSync(resolve(output, c.artifact)));
      }
    }
    // 一時領域を片付けても、保存した実物から同じ評価を再実行できること。
    const replay = run(['--source', join(output, 'target'), '--output', join(scratch, 'replay')]);
    assert.equal(replay.status, 0, replay.stderr);
    // 二度目の実行で、最初の証拠を消す事故を捕まえる。
    const before = readFileSync(join(output, 'report.json'), 'utf8');
    const rerun = run(['--output', output]);
    assert.equal(rerun.status, 1);
    assert.equal(readFileSync(join(output, 'report.json'), 'utf8'), before);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// 評価器自身が「故障を検出した」だけで、入力版の欠陥まで合格にする事故を捕まえる。
test('入力された hook が素通りする版なら、失敗と生出力を残す', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'dotagents-evidence-broken-'));
  try {
    const source = join(scratch, 'source');
    mkdirSync(join(source, 'hooks'), { recursive: true });
    mkdirSync(join(source, 'scripts'), { recursive: true });
    copyFileSync(join(root, 'scripts/gate.sh'), join(source, 'scripts/gate.sh'));
    writeFileSync(join(source, 'hooks/dotagents-verify-gate.sh'), '#!/usr/bin/env bash\nexit 0\n');
    const output = join(scratch, 'proof');
    const result = run(['--source', source, '--output', output]);
    assert.equal(result.status, 1);
    const report = JSON.parse(readFileSync(join(output, 'report.json'), 'utf8'));
    assert.equal(report.baseline.passed, false);
    assert.ok(report.baseline.falseAllows >= 2);
    assert.ok(report.baseline.cases.find(c => c.id === 'red').passed === false);
    assert.equal(report.passed, false);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
