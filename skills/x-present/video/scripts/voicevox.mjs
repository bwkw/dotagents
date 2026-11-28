import fs from 'node:fs/promises';
import path from 'node:path';

export function voicevoxOptions(sc) {
  if (sc.voice !== undefined || sc.rate !== undefined) throw new Error('旧voice/rateは使えません。voicevox.speaker / voicevox.speedScaleへ移してください');
  const v = sc.voicevox ?? {};
  if (typeof v !== 'object' || Array.isArray(v)) throw new Error('voicevoxは設定オブジェクトにしてください');
  const url = new URL(v.url ?? 'http://127.0.0.1:50021');
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('VOICEVOXはローカルのHTTPエンジンを指定してください');
  }
  const speaker = v.speaker ?? 2;
  const speedScale = v.speedScale ?? 1.05;
  if (!Number.isInteger(speaker) || speaker < 0) throw new Error('voicevox.speakerは0以上の整数にしてください');
  if (!Number.isFinite(speedScale) || speedScale <= 0 || speedScale > 2) throw new Error('voicevox.speedScaleは0より大きく2以下にしてください');
  return { url, speaker, speedScale };
}

export async function synthesizeVoicevox(sc, audioDir) {
  const { url, speaker, speedScale } = voicevoxOptions(sc);
  async function request(route, init = {}, params = {}) {
    const endpoint = new URL(route, url);
    endpoint.search = new URLSearchParams(params).toString();
    let response;
    try {
      response = await fetch(endpoint, { ...init, redirect: 'error', signal: AbortSignal.timeout(120_000) });
    } catch (cause) {
      throw new Error(`VOICEVOX ${url.origin}に接続できません。エンジンを起動してください（macOS: open -a VOICEVOX）`, { cause });
    }
    if (!response.ok) throw new Error(`VOICEVOX ${route}: HTTP ${response.status}`);
    return response;
  }
  const speakers = await (await request('/speakers')).json();
  const owner = speakers.find(s => s.styles.some(style => style.id === speaker && (!style.type || ['talk', 'streaming_talk'].includes(style.type))));
  if (!owner) throw new Error(`VOICEVOXの話者ID ${speaker}が見つかりません。/speakersのトーク用スタイルを指定してください`);
  const style = owner.styles.find(s => s.id === speaker);
  await fs.mkdir(audioDir, { recursive: true });
  for (const scene of sc.scenes) {
    const query = await (await request('/audio_query', { method: 'POST' }, { text: scene.say, speaker })).json();
    query.speedScale = speedScale;
    const response = await request('/synthesis', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(query) }, { speaker });
    const wav = Buffer.from(await response.arrayBuffer());
    if (wav.length <= 44 || wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') throw new Error(`VOICEVOX ${scene.id}: WAV音声ではありません`);
    await fs.writeFile(path.join(audioDir, `${scene.id}.wav`), wav);
  }
  const metadata = { speaker, speakerName: owner.name, styleName: style.name, speedScale, credit: `VOICEVOX:${owner.name}` };
  await fs.writeFile(path.join(audioDir, 'voicevox.json'), JSON.stringify(metadata, null, 2) + '\n');
  return metadata;
}
