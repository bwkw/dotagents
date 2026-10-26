// 外部エンジンとの境界をHTTPで再現する。APIの引数と返された音声の保存を検証する。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

async function fixture(t, mode = 'ok') {
  const work = await fs.mkdtemp(path.join(os.tmpdir(), 'demo-voicevox-test-'));
  t.after(() => fs.rm(work, { recursive: true, force: true }));
  // 24kHz、モノラル、16bit、1秒のPCM WAV。
  const wav = Buffer.alloc(48044);
  wav.write('RIFF'); wav.writeUInt32LE(48036, 4); wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(24000, 24); wav.writeUInt32LE(48000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
  wav.write('data', 36); wav.writeUInt32LE(48000, 40);
  const requests = [];
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let body = ''; for await (const chunk of req) body += chunk;
    requests.push({ method: req.method, url, body });
    if (url.pathname === '/speakers') {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify([{ name: '四国めたん', styles: [{ name: 'ノーマル', id: 2, type: 'streaming_talk' }, { name: 'あまあま', id: 0 }] }]));
    } else if (mode === 'error') {
      res.writeHead(503); res.end('unavailable');
    } else if (url.pathname === '/audio_query') {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ speedScale: 1, accent_phrases: [], outputSamplingRate: 24000 }));
    } else if (url.pathname === '/synthesis') {
      res.setHeader('Content-Type', 'audio/wav');
      res.end(mode === 'bad-wav' ? Buffer.from('not audio') : wav);
    } else { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return { work, wav, requests, url: `http://127.0.0.1:${server.address().port}` };
}

test('日本語のクエリ、話者、話速を渡し、返ったWAVと正しいクレジットを保存する', async t => {
  const f = await fixture(t);
  const { synthesizeVoicevox } = await import('../skills/da-demo-video/scripts/voicevox.mjs');
  await synthesizeVoicevox({ scenes: [{ id: 'intro', say: '確認の手間を減らします。' }], voicevox: { url: f.url, speedScale: 1.08 } }, f.work);
  assert.deepEqual(await fs.readFile(path.join(f.work, 'intro.wav')), f.wav);
  const query = f.requests.find(r => r.url.pathname === '/audio_query');
  assert.equal(query.method, 'POST');
  assert.equal(query.url.searchParams.get('speaker'), '2');
  assert.equal(query.url.searchParams.get('text'), '確認の手間を減らします。');
  const synthesis = f.requests.find(r => r.url.pathname === '/synthesis');
  assert.equal(synthesis.method, 'POST');
  assert.equal(synthesis.url.searchParams.get('speaker'), '2');
  assert.equal(JSON.parse(synthesis.body).speedScale, 1.08);
  assert.equal(JSON.parse(synthesis.body).outputSamplingRate, 24000);
  assert.equal(JSON.parse(await fs.readFile(path.join(f.work, 'voicevox.json'), 'utf8')).credit, 'VOICEVOX:四国めたん');
});

test('話者IDの0を既定値で上書きしない', async t => {
  const f = await fixture(t);
  const { synthesizeVoicevox } = await import('../skills/da-demo-video/scripts/voicevox.mjs');
  await synthesizeVoicevox({ scenes: [{ id: 'zero', say: 'テストです。' }], voicevox: { url: f.url, speaker: 0 } }, f.work);
  assert.equal(f.requests.find(r => r.url.pathname === '/synthesis').url.searchParams.get('speaker'), '0');
});

for (const mode of ['error', 'bad-wav']) {
  test(`${mode}では成功扱いにせず、音声を書き出さない`, async t => {
    const f = await fixture(t, mode);
    const { synthesizeVoicevox } = await import('../skills/da-demo-video/scripts/voicevox.mjs');
    await assert.rejects(synthesizeVoicevox({ scenes: [{ id: 'bad', say: 'テストです。' }], voicevox: { url: f.url } }, f.work), mode === 'error' ? /503/ : /WAV/);
    await assert.rejects(fs.access(path.join(f.work, 'bad.wav')));
  });
}

test('存在しない話者を指定したら音声生成前に止まる', async t => {
  const f = await fixture(t);
  const { synthesizeVoicevox } = await import('../skills/da-demo-video/scripts/voicevox.mjs');
  await assert.rejects(synthesizeVoicevox({ scenes: [{ id: 'bad', say: 'テストです。' }], voicevox: { url: f.url, speaker: 9999 } }, f.work), /9999/);
  assert.equal(f.requests.length, 1);
});
