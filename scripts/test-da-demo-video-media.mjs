import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const deps = process.env.DA_DEMO_VIDEO_HOME ?? path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'da-demo-video');
let ffmpeg, chromium;
try {
  const require = createRequire(path.join(deps, 'package.json'));
  ffmpeg = require('ffmpeg-static');
  ({ chromium } = require('playwright'));
} catch (error) {
  if (process.env.DA_DEMO_VIDEO_REQUIRE_MEDIA_TESTS === '1') throw error;
}
const options = { skip: !ffmpeg && 'setup 後に実行。CI の media ジョブでは省略不可' };
function run(command, args) {
  const result = spawnSync(command, args, { maxBuffer: 32 * 1024 * 1024 });
  assert.equal(result.status, 0, result.stderr?.toString());
  return result.stdout;
}
function decode(file) {
  return run(ffmpeg, ['-v', 'error', '-i', file, '-vn', '-ac', '1', '-ar', '24000', '-f', 's16le', '-']);
}
function tone(file, frequency, seconds) {
  const pcm = Buffer.alloc(Math.round(24000 * seconds) * 2);
  for (let i = 0; i < pcm.length / 2; i++) {
    const amplitude = i < 2400 || i > pcm.length / 2 - 2400 ? 0 : 6000 * Math.sin(2 * Math.PI * frequency * i / 24000);
    pcm.writeInt16LE(Math.round(amplitude), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write('RIFF'); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(24000, 24); header.writeUInt32LE(48000, 28); header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(pcm.length, 40);
  fs.writeFileSync(file, Buffer.concat([header, pcm]));
}

test('compose は30秒以降を含む全7シーンの音声を所定の時刻に残し、欠落した完成音声を拒否する', options, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-media-'));
  try {
    fs.mkdirSync(path.join(work, 'audio'));
    run(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=navy:s=320x200', '-frames:v', '1', path.join(work, 'frame.jpg')]);
    const ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
    const lengths = [11.019, 12.437, 11.051, 7.904, 8.416, 15.669, 12.213];
    const starts = [0.3, 11.864, 25.489, 37.053, 45.476, 57.845, 74.065];
    ids.forEach((id, i) => tone(path.join(work, 'audio', `${id}.wav`), 223 + i * 137, lengths[i]));
    const scenario = path.join(work, 'scenario.mjs');
    fs.writeFileSync(scenario, `export default {url:'https://example.com',ready:p=>p.locator('body'),scenes:${JSON.stringify(ids.map(id => ({ id, say: id })))}};`);
    fs.writeFileSync(path.join(work, 'timeline.json'), JSON.stringify({
      frames: Array.from({ length: 880 }, (_, i) => ({ t: 1000 + i * 0.0995, file: path.join(work, 'frame.jpg') })),
      timeline: ids.map((id, i) => ({ id, t: 1000 + starts[i] })), end: 1087.62,
    }));
    const demo = path.join(repo, 'skills/da-demo-video/scripts/demo.mjs');
    run(process.execPath, [demo, 'compose', scenario]);
    const movie = path.join(work, 'out.mp4'), audio = decode(movie);
    assert.ok(Math.abs(audio.length / 48000 - 87.62) < 0.1, `音声の実サンプル長: ${audio.length / 48000}秒`);
    // 撮影時刻に合成余白0.3秒を足した位置で、元WAVと比較する。
    ids.forEach((id, i) => {
      const source = decode(path.join(work, 'audio', `${id}.wav`));
      const start = Math.round((starts[i] + 0.3) * 24000);
      let xy = 0, xx = 0, yy = 0;
      for (let n = 4800; n < source.length / 2 - 4800; n++) {
        const x = source.readInt16LE(n * 2), y = audio.readInt16LE((start + n) * 2);
        xy += x * y; xx += x * x; yy += y * y;
      }
      assert.ok(xy / Math.sqrt(xx * yy) > 0.98, `${id}: 完成動画の音声が欠落・移動しています`);
    });
    run(process.execPath, [demo, 'verify', scenario]);
    fs.renameSync(movie, path.join(work, 'good.mp4'));
    run(ffmpeg, ['-v', 'error', '-i', path.join(work, 'good.mp4'), '-map', '0:v', '-map', '0:a', '-c:v', 'copy', '-af', "volume=enable='gte(t,74)':volume=0", '-c:a', 'aac', movie]);
    const invalid = spawnSync(process.execPath, [demo, 'verify', scenario], { encoding: 'utf8' });
    assert.notEqual(invalid.status, 0, '末尾の音声が消えた動画を検証が通しました');
    assert.match(invalid.stderr, /g.*音声|音声.*g/);
    const report = JSON.parse(fs.readFileSync(path.join(work, 'audio-verification.json'), 'utf8'));
    assert.equal(report.ok, false, '以前の成功レポートが残っています');
    fs.copyFileSync(path.join(work, 'good.mp4'), movie);
    run(process.execPath, [demo, 'verify', scenario]);
    fs.rmSync(path.join(work, 'audio', 'g.wav'));
    const failedCompose = spawnSync(process.execPath, [demo, 'compose', scenario], { encoding: 'utf8' });
    assert.notEqual(failedCompose.status, 0);
    const stale = path.join(work, 'audio-verification.json');
    assert.ok(!fs.existsSync(stale) || JSON.parse(fs.readFileSync(stale, 'utf8')).ok !== true, '書き出し失敗後も成功レポートが残っています');
  } finally { fs.rmSync(work, { recursive: true, force: true }); }
});

test('強調枠はズーム途中・拡大後・解除後・スクロール中に対象へ追従する', options, async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await page.setContent('<style>body{margin:0;width:1440px;height:1800px}#target{position:absolute;left:1050px;top:370px;width:260px;height:90px}</style><div id="target">対象</div>');
    await page.evaluate(fs.readFileSync(path.join(repo, 'skills/da-demo-video/scripts/overlay.js'), 'utf8'));
    const errors = await page.evaluate(async () => {
      const target = document.querySelector('#target');
      window.__ov.hl(target.getBoundingClientRect(), 8, target);
      const errors = [];
      const sample = async () => {
        for (let i = 0; i < 50; i++) {
          await new Promise(resolve => requestAnimationFrame(resolve));
          const t = target.getBoundingClientRect(), h = document.querySelector('ov-host').shadowRoot.querySelector('#ov-hl').getBoundingClientRect();
          errors.push(Math.max(Math.abs(h.x - t.x + 8), Math.abs(h.y - t.y + 8), Math.abs(h.width - t.width - 16), Math.abs(h.height - t.height - 16)));
        }
      };
      window.__ov.zoom(target.getBoundingClientRect(), 1.5); await sample();
      window.__ov.unzoom(); await sample();
      window.scrollTo(0, 200); await sample();
      window.__ov.hlOff();
      return errors;
    });
    assert.ok(Math.max(...errors) < 2, `強調枠の最大ずれ: ${Math.max(...errors)}px`);
  } finally { await browser.close(); }
});

test('record のh.hlもズームへ追従し、途中・拡大後・解除時の静止画を残す', options, async () => {
  const { createServer } = await import('node:http');
  const { execFile } = await import('node:child_process');
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-record-'));
  const server = createServer((_, response) => response.end('<style>body{margin:0;width:1440px;height:900px}#target{position:absolute;left:1050px;top:370px;width:260px;height:90px}</style><div id="target">対象</div>'));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    fs.mkdirSync(path.join(work, 'audio'));
    tone(path.join(work, 'audio', 'focus.wav'), 333, 2);
    fs.writeFileSync(path.join(work, 'audio', 'voicevox.json'), JSON.stringify({ credit: 'VOICEVOX:テスト' }));
    const scenario = path.join(work, 'scenario.mjs');
    fs.mkdirSync(path.join(work, 'stills'));
    fs.writeFileSync(path.join(work, 'stills', 'zoom-999-old.jpg'), 'old');
    fs.writeFileSync(scenario, `export default {
      url:'http://127.0.0.1:${server.address().port}',ready:p=>p.locator('#target'),
      scenes:[{id:'focus',say:'対象を拡大',async run(h){
        const target=h.page.locator('#target');await h.hl(target);await h.zoom(target,1.5);
        const error=await target.evaluate(e=>{const t=e.getBoundingClientRect(),f=document.querySelector('ov-host').shadowRoot.querySelector('#ov-hl').getBoundingClientRect();return Math.abs(f.x-t.x+8)});
        if(error>2)throw new Error('h.hlの枠がズームへ追従していません');
        await h.unzoom();await h.hlOff();
      }}]};`);
    await new Promise((resolve, reject) => execFile(process.execPath, [path.join(repo, 'skills/da-demo-video/scripts/demo.mjs'), 'record', scenario], { maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => error ? reject(new Error(stderr || error.message)) : resolve(stdout)));
    const stills = fs.readdirSync(path.join(work, 'stills')).filter(file => /^zoom-.*\.jpg$/.test(file));
    assert.equal(stills.length, 4, 'ズーム途中・拡大後・解除途中・解除後の静止画がありません');
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(work, { recursive: true, force: true });
  }
});
