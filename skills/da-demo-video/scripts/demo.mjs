// 機能紹介動画を 1 本のシナリオから作る。
//   node demo.mjs setup   <scenario.mjs>   依存を ~/.cache/da-demo-video に入れる（初回だけ）
//   node demo.mjs login   <scenario.mjs>   ブラウザ窓を開き、手でログイン → <workdir>/auth.json
//   node demo.mjs tts     <scenario.mjs>   ナレーション → <workdir>/audio/*.mp3
//   node demo.mjs record  <scenario.mjs>   撮影（cleanup を前後に実行）→ frames/ timeline.json
//   node demo.mjs compose <scenario.mjs>   out.mp4 と確認用コンタクトシート stills/sheet*.jpg
//   node demo.mjs all     <scenario.mjs>   tts → record → compose
//   node demo.mjs check   <scenario.mjs>   シナリオの形だけ検査する（依存パッケージ不要）
// <workdir> はシナリオファイルと同じディレクトリ。auth.json・音声・フレームはすべてそこに書く。
// スキルのディレクトリには何も書かない（ログイン状態をリポジトリに近づけない）。
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import os from 'node:os';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// 依存（node_modules と edge-tts の venv）はスキルの外に置く。スキルのディレクトリはリンクで配られ、
// 中身がすべてエージェントの読む対象として lint される。依存をそこに置くと、入れた人の検査が落ちる。
const DEPS = process.env.DA_DEMO_VIDEO_HOME ?? path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'da-demo-video');
const [cmd, scenarioArg] = process.argv.slice(2);
if (!cmd || !scenarioArg) { console.error('usage: node demo.mjs <setup|login|tts|record|compose|all|check> <scenario.mjs>'); process.exit(1); }
// check と setup は依存無しで動く（CI は依存を入れない）
const needsDeps = !['check', 'setup'].includes(cmd);
if (needsDeps && !fs.existsSync(path.join(DEPS, 'node_modules'))) { console.error(`依存が無い。先に: node ${path.join(HERE, 'demo.mjs')} setup <scenario.mjs>`); process.exit(1); }
const req = createRequire(path.join(DEPS, 'package.json'));
const { chromium } = needsDeps ? req('playwright') : {};
const ffmpeg = needsDeps ? req('ffmpeg-static') : null;
const scenarioPath = path.resolve(scenarioArg);
const sc = (await import(pathToFileURL(scenarioPath))).default;
check(sc);
const W = path.dirname(scenarioPath);
const p = (...a) => path.join(W, ...a);
// 壊れたシナリオは撮影を数分走らせてから落ちる。先に形だけ見る
function check(s) {
  const bad = [];
  if (!/^https?:\/\//.test(s?.url ?? '')) bad.push('url が http(s) でない');
  if (typeof s?.ready !== 'function') bad.push('ready が関数でない');
  if (!Array.isArray(s?.scenes) || !s.scenes.length) bad.push('scenes が空');
  const ids = new Set();
  for (const [i, x] of (s?.scenes ?? []).entries()) {
    if (!/^[\w-]+$/.test(x.id ?? '')) bad.push(`scenes[${i}].id が無いかファイル名にできない`);
    else if (ids.has(x.id)) bad.push(`scenes[${i}].id "${x.id}" が重複（音声ファイルが上書きされる）`);
    ids.add(x.id);
    if (!x.say?.trim()) bad.push(`scenes[${i}].say が空（シーンの長さはナレーションで決まる）`);
    if (x.run && typeof x.run !== 'function') bad.push(`scenes[${i}].run が関数でない`);
  }
  if (bad.length) { console.error('シナリオが不正:\n- ' + bad.join('\n- ')); process.exit(2); }
}

const VIEW = { width: 1440, height: 900 };
const dur = (id) => +spawnSync(ffmpeg, ['-i', p('audio', `${id}.mp3`)], { encoding: 'utf8' }).stderr
  .match(/Duration: (\d+):(\d+):([\d.]+)/).slice(1).reduce((a, v) => a * 60 + +v, 0);

async function openPage(browser, extra = {}) {
  const auth = fs.existsSync(p('auth.json')) ? { storageState: p('auth.json') } : {}; // ログイン不要の画面もある
  const ctx = await browser.newContext({ viewport: VIEW, bypassCSP: true, ...auth, ...extra });
  const page = await ctx.newPage();
  await page.goto(sc.url);
  await sc.ready(page).waitFor({ timeout: 120_000 }); // STG は初回表示に 30 秒超かかることがある
  return { ctx, page };
}

async function login() {
  const browser = await chromium.launch({ headless: false });
  const ctx = await browser.newContext({ viewport: VIEW });
  const page = await ctx.newPage();
  await page.goto(sc.url);
  console.log('ブラウザ窓でログインしてください（最大 10 分待ちます）');
  await sc.ready(page).waitFor({ timeout: 600_000 });
  await ctx.storageState({ path: p('auth.json') });
  console.log('saved', p('auth.json'));
  await browser.close();
}

function tts() {
  fs.mkdirSync(p('audio'), { recursive: true });
  for (const s of sc.scenes) {
    const r = spawnSync(path.join(DEPS, '.venv/bin/edge-tts'), ['--voice', sc.voice ?? 'ja-JP-NanamiNeural', `--rate=${sc.rate ?? '+8%'}`,
      '--text', s.say, '--write-media', p('audio', `${s.id}.mp3`)], { encoding: 'utf8' });
    if (r.status) throw new Error(`tts ${s.id}: ${r.stderr}`);
    console.log(s.id, dur(s.id).toFixed(1), 's');
  }
}

async function cleanup() {
  if (!sc.cleanup) return;
  const browser = await chromium.launch();
  const { page } = await openPage(browser);
  await sc.cleanup(page);
  await browser.close();
}

async function record() {
  await cleanup();
  fs.rmSync(p('frames'), { recursive: true, force: true });
  fs.mkdirSync(p('frames'), { recursive: true });
  fs.mkdirSync(p('stills'), { recursive: true });
  const browser = await chromium.launch();
  const { ctx, page } = await openPage(browser, { deviceScaleFactor: 2 });
  await page.waitForTimeout(1500);
  await page.evaluate(fs.readFileSync(path.join(HERE, 'overlay.js'), 'utf8'));
  await page.evaluate((pats) => { // 映したくない文字列を含む葉要素を隠す
    const res = pats.map(s => new RegExp(s));
    for (const el of document.querySelectorAll('body *')) if (el.children.length === 0 && res.some(r => r.test(el.textContent))) el.style.visibility = 'hidden';
  }, (sc.hide ?? []).map(r => r.source));
  for (const sel of sc.hideSelectors ?? []) await page.locator(sel).evaluateAll(es => es.forEach(e => (e.style.visibility = 'hidden')));

  const ov = (fn, ...a) => page.evaluate(([fn, a]) => window.__ov[fn](...a), [fn, a]);
  const sleep = (ms) => page.waitForTimeout(ms);
  const box = async (loc) => { await loc.waitFor(); return loc.boundingBox(); };
  const center = (b) => [b.x + b.width / 2, b.y + b.height / 2];
  const h = {
    page, ov, sleep, box,
    // スムーズスクロールして止まるまで待つ。枠やカーソルはこの後に描く（先に描くと古い位置に残る）
    async scrollTo(loc) {
      await loc.evaluate(e => e.scrollIntoView({ behavior: 'smooth', block: 'center' }));
      let prev = null;
      for (let i = 0; i < 40; i++) { await sleep(150); const y = (await loc.boundingBox())?.y; if (prev !== null && Math.abs(y - prev) < 0.5) break; prev = y; }
      await sleep(150);
    },
    async moveTo(loc, ms = 600) { const [x, y] = center(await box(loc)); await ov('cursorTo', x, y, ms); await page.mouse.move(x, y); await sleep(ms + 100); },
    async click(loc, pause = 500) { await h.moveTo(loc); await ov('ripple'); await loc.click(); await sleep(pause); },
    // ページが動くクリック（アンカー・保存・ダイアログ開閉）は枠を消してから
    async clickAndClear(loc, pause = 1200) { await h.moveTo(loc); await ov('ripple'); await loc.click(); await ov('hlOff'); await sleep(pause); },
    async hl(locOrRect, pad = 8) { const r = locOrRect.boundingBox ? await box(locOrRect) : locOrRect; await ov('hl', r, pad); await sleep(500); },
    hlOff: () => ov('hlOff'),
    async type(loc, text) { await h.click(loc, 200); await page.keyboard.type(text, { delay: 110 }); await sleep(300); },
    async pick(combo, name) { await h.click(combo, 500); const o = page.getByRole('option', { name, exact: true }); await h.moveTo(o, 450); await ov('ripple'); await o.click(); await sleep(500); },
    // ズーム中はドロップダウンの位置がずれるので、ズームは「見せるだけ」の場面に使う
    async zoom(loc, s = 1.5) { await ov('zoom', await box(loc), s); await sleep(900); },
    async unzoom() { await ov('unzoom'); await sleep(700); },
    async card(html) { await ov('card', html); await sleep(700); await ov('cardShowCols'); },
    cardOff: () => ov('cardOff'),
    dur,
  };

  const frames = [];
  const cdp = await ctx.newCDPSession(page);
  cdp.on('Page.screencastFrame', async (f) => {
    const file = p('frames', `${String(frames.length).padStart(5, '0')}.jpg`);
    frames.push({ t: f.metadata.timestamp, file });
    fs.writeFileSync(file, Buffer.from(f.data, 'base64'));
    await cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {});
  });
  const timeline = [];
  // 最初のシーンがタイトルカードなら、撮影開始前に出しておく（動画の頭に素の画面が映らない）
  if (sc.scenes[0].card) { await ov('card', sc.scenes[0].card); await sleep(800); }
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 88, maxWidth: VIEW.width * 2, maxHeight: VIEW.height * 2 });
  await sleep(300);
  try {
    for (const [i, s] of sc.scenes.entries()) {
      const t0 = Date.now();
      timeline.push({ id: s.id, t: t0 / 1000 });
      await ov('cap', s.cap ?? '');
      if (s.card && s !== sc.scenes[0]) await h.card(s.card);
      else if (s.card) await ov('cardShowCols');
      await s.run?.(h);
      const rest = dur(s.id) * 1000 + 500 - (Date.now() - t0); // 次のシーンはナレーションが終わってから
      if (rest > 0) await sleep(rest);
      if (s.card && sc.scenes[i + 1] && !sc.scenes[i + 1].card) { await h.cardOff(); await sleep(600); } // カードから画面へ戻る
      console.log(s.id, ((Date.now() - t0) / 1000).toFixed(1), 's / audio', dur(s.id).toFixed(1));
    }
    await sleep(800);
  } catch (e) {
    await page.screenshot({ path: p('stills', 'fail.png') });
    throw e;
  } finally {
    await cdp.send('Page.stopScreencast').catch(() => {});
    fs.writeFileSync(p('timeline.json'), JSON.stringify({ frames, timeline, end: Date.now() / 1000 }));
    await browser.close();
    await cleanup();
  }
}

function compose() {
  const { frames, timeline, end } = JSON.parse(fs.readFileSync(p('timeline.json'), 'utf8'));
  const t0 = frames[0].t;
  let list = '';
  frames.forEach((f, i) => { list += `file '${f.file}'\nduration ${Math.max(0.001, (frames[i + 1]?.t ?? end) - f.t).toFixed(4)}\n`; });
  list += `file '${frames.at(-1).file}'\n`;
  fs.writeFileSync(p('frames.txt'), list);
  const delays = timeline.map((s, i) => `[${i + 1}:a]adelay=${Math.round((s.t - t0) * 1000 + 300)}:all=1[a${i}]`).join(';');
  const mix = timeline.map((_, i) => `[a${i}]`).join('') + `amix=inputs=${timeline.length}:normalize=0,apad=whole_dur=${(end - t0).toFixed(2)}[aout]`; // 音声を映像の長さまで無音で伸ばす。-shortest が最後のカードを切らないように
  const out = p(sc.output ?? 'out.mp4');
  const r = spawnSync(ffmpeg, ['-y', '-f', 'concat', '-safe', '0', '-i', p('frames.txt'), ...timeline.flatMap(s => ['-i', p('audio', `${s.id}.mp3`)]),
    '-filter_complex', `[0:v]fps=30,scale=1920:1200:flags=lanczos,format=yuv420p[v];${delays};${mix}`,
    '-map', '[v]', '-map', '[aout]', '-c:v', 'libx264', '-crf', '18', '-preset', 'slow', '-c:a', 'aac', '-b:a', '160k',
    '-movflags', '+faststart', '-shortest', out], { encoding: 'utf8' });
  if (r.status) throw new Error(r.stderr.slice(-2000));
  // 確認用: 各シーンの 35% / 85% 地点を並べたコンタクトシート
  fs.mkdirSync(p('stills'), { recursive: true });
  for (const f of fs.readdirSync(p('stills'))) if (/^(c|sheet)/.test(f)) fs.rmSync(p('stills', f));
  timeline.forEach((s, i) => {
    const e = timeline[i + 1]?.t ?? end;
    [0.35, 0.85].forEach((q, j) => spawnSync(ffmpeg, ['-loglevel', 'error', '-y', '-ss', (s.t - t0 + (e - s.t) * q).toFixed(2), '-i', out,
      '-frames:v', '1', '-vf', 'scale=640:-1', p('stills', `c${String(i).padStart(2, '0')}-${j}.jpg`)]));
  });
  spawnSync(ffmpeg, ['-loglevel', 'error', '-y', '-pattern_type', 'glob', '-i', p('stills', 'c*.jpg'), '-vf', 'tile=4x2', p('stills', 'sheet%d.jpg')]);
  console.log('ok', out, (end - t0).toFixed(1), 's');
}

function setup() {
  fs.mkdirSync(DEPS, { recursive: true });
  for (const f of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(HERE, '..', f), path.join(DEPS, f));
  const run = (c, a) => { const r = spawnSync(c, a, { cwd: DEPS, stdio: 'inherit' }); if (r.status) throw new Error(`${c} ${a.join(' ')} が失敗`); };
  run('npm', ['ci', '--no-audit', '--no-fund']); // lock の版で入れる
  run('npx', ['playwright', 'install', 'chromium']);
  run('python3', ['-m', 'venv', '.venv']);
  run(path.join(DEPS, '.venv/bin/pip'), ['install', '-q', 'edge-tts']);
  console.log('ok', DEPS);
}

if (cmd === 'check') console.log('ok', sc.scenes.length, 'scenes');
else if (cmd === 'setup') setup();
else if (cmd === 'login') await login();
else if (cmd === 'tts') tts();
else if (cmd === 'record') await record();
else if (cmd === 'compose') compose();
else if (cmd === 'all') { tts(); await record(); compose(); }
else throw new Error(`unknown command: ${cmd}`);
