// ADR の判断を 1 枚の図解にする。中身は JSON の定義 1 ファイルに書く。
//   node figure.mjs setup                      依存を ~/.cache/da-adr-figure に入れる（初回だけ）
//   node figure.mjs check <figure.json>        定義の形だけ検査する（依存パッケージ不要）
//   node figure.mjs html  <figure.json> <out.html>   HTML を書く（依存パッケージ不要）
//   node figure.mjs build <figure.json> <out.png>    HTML と PNG を書き、文字があふれていたら失敗する
// 定義の書き方は reference/figure-format.md。出力はすべて引数で指定した場所に書く。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// 依存（node_modules）はスキルの外に置く。スキルのディレクトリはリンクで配られ、中身がすべて lint される。
const DEPS = process.env.DA_ADR_FIGURE_HOME
  ?? path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'da-adr-figure');

const TAGS = {
  決定: 'ketsu', なぜ: 'naze', 例: 'rei', ボツ案: 'botsu', 見直す条件: 'amber', 限界: 'amber', ポイント: 'rei',
};
const REQUIRED_TAGS = ['決定', 'なぜ'];
// 図は判断の入口で、細部は ADR に任せる。上限を超えたら削る（枠を広げない）
const LIMIT = { lead: 1, leadText: 80, cardTitle: 55, text: 90, points: 2, point: 70, alts: 2, altName: 25, altResult: 60, tables: 1, tableRows: 4, cell: 30, sub: 30 };
const len = (s) => String(s ?? '').replace(/`|\*\*/g, '').length;

export function validate(f) {
  const bad = [];
  const str = (v) => typeof v === 'string' && v.trim() !== '';
  const over = (at, v, max, what) => { if (len(v) > max) bad.push(`${at} が ${len(v)} 字（${what}は ${max} 字まで）`); };
  if (!str(f?.title)) bad.push('title が無い');
  if (f?.lead !== undefined && !(Array.isArray(f.lead) && f.lead.every(str))) bad.push('lead は空でない文字列の配列にする');
  else if (f?.lead) {
    if (f.lead.length > LIMIT.lead) bad.push(`lead が ${f.lead.length} 行（${LIMIT.lead} 行まで）`);
    for (const [i, l] of f.lead.entries()) over(`lead[${i}]`, l, LIMIT.leadText, 'lead');
  }
  for (const [i, s] of (f?.overview?.stages ?? []).entries()) {
    if (!str(s.title)) bad.push(`overview.stages[${i}].title が無い`);
    if (!Array.isArray(s.rows) || !s.rows.length) bad.push(`overview.stages[${i}].rows が空`);
    for (const row of s.rows ?? []) for (const item of row) for (const b of [item].flat()) {
      if (!str(b?.name)) bad.push(`overview.stages[${i}] に name の無い箱がある`);
      if (b?.sub) over(`overview.stages[${i}] の「${b.name}」の sub`, b.sub, LIMIT.sub, '箱の補足');
    }
  }
  if (!Array.isArray(f?.cards) || !f.cards.length) bad.push('cards が空');
  for (const [i, c] of (f?.cards ?? []).entries()) {
    const at = `cards[${i}]`;
    if (!str(c?.title)) bad.push(`${at}.title が無い`);
    else over(`${at}.title`, c.title, LIMIT.cardTitle, 'カードの見出し');
    const tables = (c?.parts ?? []).filter((p) => p.table).length;
    if (tables > LIMIT.tables) bad.push(`${at} に表が ${tables} つ（${LIMIT.tables} つまで）`);
    const tags = (c?.parts ?? []).filter((p) => p.tag).map((p) => p.tag);
    for (const t of REQUIRED_TAGS) if (!tags.includes(t)) bad.push(`${at} に「${t}」が無い（図だけで判断の正しさを確かめられない）`);
    for (const [j, p] of (c?.parts ?? []).entries()) {
      const pat = `${at}.parts[${j}]`;
      if (p.table) {
        const { head, rows } = p.table;
        if (!Array.isArray(head) || !head.length || !Array.isArray(rows) || !rows.length) bad.push(`${pat}.table に head か rows が無い`);
        else {
          if (rows.length > LIMIT.tableRows) bad.push(`${pat}.table が ${rows.length} 行（${LIMIT.tableRows} 行まで）`);
          for (const [k, r] of rows.entries()) {
            if (r.length !== head.length) bad.push(`${pat}.table.rows[${k}] の列の数が head と違う`);
            for (const cell of r) over(`${pat}.table.rows[${k}]`, cell, LIMIT.cell, '表のセル');
          }
        }
        continue;
      }
      if (!(p.tag in TAGS)) { bad.push(`${pat}.tag「${p.tag}」は使えない（${Object.keys(TAGS).join('・')}）`); continue; }
      if (p.tag === 'ボツ案') {
        if (!Array.isArray(p.alternatives) || !p.alternatives.length) bad.push(`${pat} のボツ案に alternatives が無い`);
        else if (p.alternatives.length > LIMIT.alts) bad.push(`${pat} のボツ案が ${p.alternatives.length} 件（${LIMIT.alts} 件まで。一番強い対抗案を残す）`);
        for (const [k, a] of (p.alternatives ?? []).entries()) {
          if (!str(a.name)) bad.push(`${pat}.alternatives[${k}].name が無い`);
          else over(`${pat}.alternatives[${k}].name`, a.name, LIMIT.altName, 'ボツ案の名前');
          if (!str(a.result)) bad.push(`${pat}.alternatives[${k}].result が無い（その案だと何が起きるかを書く）`);
          else over(`${pat}.alternatives[${k}].result`, a.result, LIMIT.altResult, 'ボツ案の結果');
        }
      } else if (!str(p.text) && !(Array.isArray(p.points) && p.points.length && p.points.every(str))) {
        bad.push(`${pat} に text か points が無い`);
      } else {
        if (str(p.text)) over(`${pat}.text`, p.text, LIMIT.text, `「${p.tag}」`);
        if (Array.isArray(p.points)) {
          if (p.points.length > LIMIT.points) bad.push(`${pat} の points が ${p.points.length} 個（${LIMIT.points} 個まで。一番強い理由を残す）`);
          for (const [k, t] of p.points.entries()) over(`${pat}.points[${k}]`, t, LIMIT.point, `「${p.tag}」の項目`);
        }
      }
    }
  }
  return bad;
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
// 利用者の文は必ずエスケープし、`code` と **強調** だけを書式として解釈する
const ink = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');

const CSS = `
:root { --ink:#1d2433; --sub:#4a5568; --line:#c9d2e3; --bg:#f7f4ec; --blue:#2f6fb5; --blue-bg:#e6f0fb;
  --green:#2f8a57; --green-bg:#e5f4ea; --red:#c0392b; --red-bg:#fbeceb; --amber:#b7791f; --amber-bg:#fdf3dc;
  --violet:#5a4fcf; --violet-bg:#eeecfb; --gray-bg:#eef1f6; }
* { box-sizing:border-box; margin:0; padding:0; }
body { background:var(--bg); color:var(--ink); padding:24px 28px; display:flex; flex-direction:column; gap:14px;
  font-family:"Hiragino Sans","Hiragino Kaku Gothic ProN","Noto Sans JP","Yu Gothic",sans-serif; }
h1 { font-size:38px; font-weight:800; }
.lead { display:flex; gap:10px; flex-wrap:wrap; }
.pill { background:#fff; border:2px solid var(--ink); border-radius:999px; padding:6px 18px; font-size:17px; font-weight:700; }
.pill b { color:var(--blue); }
section.overview { background:#fff; border:2px solid var(--line); border-radius:16px; padding:14px 18px; display:flex; flex-direction:column; gap:10px; }
h2 { font-size:23px; font-weight:800; }
.flow { display:flex; gap:10px; align-items:stretch; }
.stage { flex:1 1 0; min-width:0; border:2px solid var(--line); border-radius:12px; padding:10px; display:flex; flex-direction:column; gap:8px; }
.stage.dashed { border-style:dashed; border-color:var(--blue); background:var(--blue-bg); }
.big-arrow { align-self:center; font-size:34px; color:var(--sub); font-weight:800; }
.step { display:flex; align-items:center; gap:8px; font-size:16px; font-weight:800; color:var(--blue); }
.num { background:var(--blue); color:#fff; border-radius:999px; width:26px; height:26px; display:grid; place-items:center; font-size:14px; flex:none; }
.row { display:flex; align-items:center; justify-content:center; gap:6px; }
.col { display:flex; flex-direction:column; gap:6px; }
.box { background:#fff; border:2px solid var(--ink); border-radius:10px; padding:7px 10px; font-size:15px; font-weight:700; text-align:center; line-height:1.3; min-width:0; overflow:hidden; }
.box.nowrap { white-space:nowrap; }
.box small { display:block; font-weight:500; font-size:12.5px; color:var(--sub); }
.box.store { background:var(--amber-bg); border-color:var(--amber); }
.box.queue { background:var(--gray-bg); }
.arrow { font-size:18px; color:var(--sub); font-weight:700; text-align:center; }
.note { font-size:13.5px; color:var(--sub); line-height:1.45; }
.aside { border:2px solid var(--green); background:var(--green-bg); border-radius:12px; padding:9px 12px; font-size:14.5px; line-height:1.5; }
.aside b.label { color:var(--green); }
code { font-family:"SF Mono",Menlo,monospace; font-size:.85em; background:var(--gray-bg); padding:0 3px; border-radius:3px; }
.cards { display:grid; grid-template-columns:1fr 1fr; gap:14px; }
.card { background:#fff; border:2px solid var(--line); border-radius:14px; padding:13px 16px; display:flex; flex-direction:column; gap:9px; overflow:hidden; }
.card h3 { font-size:21px; font-weight:800; line-height:1.3; display:flex; gap:8px; align-items:flex-start; }
.line { display:flex; gap:8px; font-size:15.5px; line-height:1.55; }
.tag { flex:none; width:78px; text-align:center; white-space:nowrap; font-size:12.5px; font-weight:800; border-radius:6px; padding:1px 4px; height:fit-content; margin-top:2px; border:1.5px solid; }
.ketsu { color:var(--green); background:var(--green-bg); }
.naze { color:var(--violet); background:var(--violet-bg); }
.rei { color:var(--blue); background:var(--blue-bg); }
.botsu { color:var(--red); background:var(--red-bg); }
.amber { color:var(--amber); background:var(--amber-bg); }
ul.pts { list-style:none; display:flex; flex-direction:column; gap:3px; }
ul.pts li { padding-left:14px; position:relative; }
ul.pts li::before { content:"・"; position:absolute; left:0; color:var(--violet); font-weight:800; }
.alt { font-size:15px; line-height:1.5; }
.alt .x { color:var(--red); font-weight:800; }
.alt .why { color:var(--sub); }
table.cmp { border-collapse:collapse; width:100%; font-size:14.5px; line-height:1.45; }
table.cmp th, table.cmp td { border:1.5px solid var(--line); padding:5px 7px; vertical-align:top; text-align:left; }
table.cmp th { background:var(--gray-bg); font-weight:800; white-space:nowrap; }
table.cmp td:first-child { font-weight:800; }
`;

const box = (b) => `<div class="box ${b.kind ?? ''} ${b.nowrap ? 'nowrap' : ''}">${ink(b.name)}${b.sub ? `<small>${ink(b.sub)}</small>` : ''}</div>`;
const item = (it) => (Array.isArray(it) ? `<div class="col">${it.map(box).join('')}</div>` : box(it));
function stage(s, n) {
  const rows = s.rows.map((r) => `<div class="row">${r.map(item).join('<span class="arrow">→</span>')}</div>`);
  return `<div class="stage ${s.dashed ? 'dashed' : ''}"><div class="step"><span class="num">${n}</span>${ink(s.title)}</div>`
    + rows.join(s.down ? '<div class="arrow">↓</div>' : '')
    + (s.note ? `<div class="note">${ink(s.note)}</div>` : '') + '</div>';
}
function part(p) {
  if (p.table) {
    const h = p.table.head.map((c) => `<th>${ink(c)}</th>`).join('');
    const b = p.table.rows.map((r) => `<tr>${r.map((c) => `<td>${ink(c)}</td>`).join('')}</tr>`).join('');
    return `<table class="cmp"><tr>${h}</tr>${b}</table>`;
  }
  let body;
  if (p.tag === 'ボツ案') body = p.alternatives.map((a) => `<div class="alt"><span class="x">✕ ${ink(a.name)}</span> <span class="why">→ ${ink(a.result)}</span></div>`).join('');
  else if (p.points) body = `<ul class="pts">${p.points.map((x) => `<li>${ink(x)}</li>`).join('')}</ul>`;
  else body = ink(p.text);
  return `<div class="line"><span class="tag ${TAGS[p.tag]}">${esc(p.tag)}</span><div style="flex:1">${body}</div></div>`;
}

export function toHtml(f) {
  const width = f.width ?? 1600;
  const ov = f.overview;
  const overview = ov ? `<section class="overview"><h2>${ink(ov.title ?? 'アーキテクチャ全体像')}</h2><div class="flow">`
    + ov.stages.map((s, i) => stage(s, i + 1)).join('<div class="big-arrow">→</div>') + '</div>'
    + (ov.aside ? `<div class="aside"><b class="label">${ink(ov.aside.label)}：</b>${ink(ov.aside.text)}</div>` : '') + '</section>' : '';
  const cards = f.cards.map((c, i) => `<div class="card"><h3><span class="num">${i + 1}</span>${ink(c.title)}</h3>${c.parts.map(part).join('')}</div>`).join('');
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>${esc(f.title)}</title><style>${CSS}</style></head>`
    + `<body style="width:${width}px"><h1>${ink(f.title)}</h1>`
    + (f.lead ? `<div class="lead">${f.lead.map((l) => `<div class="pill">${ink(l)}</div>`).join('')}</div>` : '')
    + `${overview}<section class="cards">${cards}</section></body></html>`;
}

function load(file) {
  const f = JSON.parse(fs.readFileSync(file, 'utf8'));
  const bad = validate(f);
  if (bad.length) { console.error('定義が不正:\n- ' + bad.join('\n- ')); process.exit(2); }
  return f;
}

async function build(f, html, png) {
  if (!fs.existsSync(path.join(DEPS, 'node_modules', 'playwright'))) {
    console.error(`依存が無い。先に: node ${path.join(HERE, 'figure.mjs')} setup`); process.exit(1);
  }
  const { chromium } = createRequire(path.join(DEPS, 'package.json'))('playwright');
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: f.width ?? 1600, height: 200 }, deviceScaleFactor: 2 });
    await page.goto('file://' + path.resolve(html));
    const over = await page.evaluate(() => [...document.querySelectorAll('.card, .stage, .box, .pill, h1')]
      .filter((e) => e.scrollWidth > e.clientWidth + 1 || e.scrollHeight > e.clientHeight + 1)
      .map((e) => e.textContent.trim().slice(0, 40)));
    await page.screenshot({ path: png, fullPage: true });
    if (over.length) {
      console.error(`文字が枠からあふれた（${png} は確認用に書いた）:\n- ` + over.join('\n- '));
      process.exit(3);
    }
  } finally { await browser.close(); }
}

function setup() {
  fs.mkdirSync(DEPS, { recursive: true });
  for (const f of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(HERE, '..', f), path.join(DEPS, f));
  const run = (c, a) => { const r = spawnSync(c, a, { cwd: DEPS, stdio: 'inherit' }); if (r.status) throw new Error(`${c} ${a.join(' ')} が失敗`); };
  run('npm', ['ci', '--no-audit', '--no-fund']); // lock の版で入れる
  run('npx', ['playwright', 'install', 'chromium']);
  console.log('ok', DEPS);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, file, out] = process.argv.slice(2);
  if (cmd === 'setup') setup();
  else if (!['check', 'html', 'build'].includes(cmd) || !file || (cmd !== 'check' && !out)) {
    console.error('usage: node figure.mjs <setup | check <figure.json> | html <figure.json> <out.html> | build <figure.json> <out.png>>');
    process.exit(1);
  } else {
    const f = load(file);
    if (cmd === 'check') console.log('ok', f.cards.length, 'cards');
    else if (cmd === 'html') { fs.writeFileSync(out, toHtml(f)); console.log('ok', out); }
    else {
      const html = out.replace(/\.png$/i, '') + '.html';
      fs.writeFileSync(html, toHtml(f));
      await build(f, html, out);
      console.log('ok', out);
    }
  }
}
