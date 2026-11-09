import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function run(ffmpeg, args) {
  const result = spawnSync(ffmpeg, ['-v', 'error', ...args], { maxBuffer: 64 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`ffmpeg: ${result.error?.message ?? result.stderr?.toString().slice(-2000)}`);
  return result.stdout;
}

export function decodeAudio(ffmpeg, file) {
  return run(ffmpeg, ['-i', file, '-vn', '-ac', '1', '-ar', '24000', '-f', 's16le', '-']);
}

export function audioStartMs(scene, firstFrame) {
  return Math.round((scene.t - firstFrame) * 1000 + 300);
}

export function composeMedia(ffmpeg, work, recording, output) {
  const { frames, timeline, end } = recording, first = frames[0].t;
  // 同時合成で完成MP4の音声時刻が崩れたため、PCM音声と映像を独立して生成する。
  const delays = timeline.map((scene, i) => `[${i}:a]adelay=${audioStartMs(scene, first)}:all=1[a${i}]`).join(';');
  const mix = timeline.map((_, i) => `[a${i}]`).join('') + `amix=inputs=${timeline.length}:normalize=0,apad=whole_dur=${(end - first).toFixed(3)}[audio]`;
  run(ffmpeg, ['-y', ...timeline.flatMap(scene => ['-i', path.join(work, 'audio', `${scene.id}.wav`)]),
    '-filter_complex', `${delays};${mix}`, '-map', '[audio]', path.join(work, 'narration.wav')]);
  run(ffmpeg, ['-y', '-f', 'concat', '-safe', '0', '-i', path.join(work, 'frames.txt'),
    '-vf', 'fps=30,scale=1920:1200:flags=lanczos,format=yuv420p', '-an', '-c:v', 'libx264', '-crf', '18', '-preset', 'slow', path.join(work, 'video-only.mp4')]);
  run(ffmpeg, ['-y', '-i', path.join(work, 'video-only.mp4'), '-i', path.join(work, 'narration.wav'),
    '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
    '-t', (end - first).toFixed(3), '-movflags', '+faststart', output]);
}

export function verifyAudio(ffmpeg, work, recording, movie) {
  const reportFile = path.join(work, 'audio-verification.json');
  fs.rmSync(reportFile, { force: true });
  const report = { ok: false, scenes: [] };
  try {
    const actual = decodeAudio(ffmpeg, movie);
    report.audioSeconds = actual.length / 48000;
    report.expectedSeconds = recording.end - recording.frames[0].t;
    // AACの最終フレームの端数を許容し、コンテナ表示だけでは見えないサンプル長を調べる。
    if (Math.abs(report.audioSeconds - report.expectedSeconds) > 0.1) throw new Error('完成音声の実サンプル長が映像の尺と一致しません');
    for (const scene of recording.timeline) {
      const reference = decodeAudio(ffmpeg, path.join(work, 'audio', `${scene.id}.wav`));
      const startMs = audioStartMs(scene, recording.frames[0].t), start = Math.round(startMs * 24);
      if (!reference.length || start < 0 || start * 2 + reference.length > actual.length) throw new Error(`${scene.id}: 音声が完成動画に収まりません`);
      let xy = 0, xx = 0, yy = 0;
      for (let n = 0; n < reference.length / 2; n++) {
        const x = reference.readInt16LE(n * 2), y = actual.readInt16LE((start + n) * 2);
        xy += x * y; xx += x * x; yy += y * y;
      }
      const correlation = xx && yy ? xy / Math.sqrt(xx * yy) : 0;
      const levelDifferenceDb = xx && yy ? 10 * Math.log10(yy / xx) : null;
      const ok = correlation >= 0.98 && levelDifferenceDb !== null && Math.abs(levelDifferenceDb) <= 1;
      report.scenes.push({ id: scene.id, startMs, correlation, levelDifferenceDb, ok });
      if (!ok) throw new Error(`${scene.id}: 完成動画の音声が欠落・移動、または音量が変化しています`);
    }
    report.ok = true;
    return report;
  } catch (error) {
    report.error = error.message;
    throw error;
  } finally {
    fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n');
  }
}
