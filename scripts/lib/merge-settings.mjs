#!/usr/bin/env node
// スニペットが宣言するキーだけを ~/.claude/settings.json へマージし、書いたものを正確に記録する。
// uninstall はその記録の分だけを取り戻す。
//
// 編集対象には他人の秘密が入っている（env.OTEL_EXPORTER_OTLP_HEADERS は Datadog の API キーを平文で
// 持つ）。自分で書いていない値は読まず、写さず、書き直さない。スニペットに無いキーは、マージ先の
// オブジェクトの中でも触らない。
//
//   merge-settings.mjs <snippet> <target> <manifest>          マージして記録
//   merge-settings.mjs --revert <target> <manifest>           記録した分だけを戻す
//   merge-settings.mjs --print-keys <snippet>                 マージが触るキーの一覧
//   merge-settings.mjs --cursor <snippet> <target> <manifest> 同じことを ~/.cursor/hooks.json に
//   merge-settings.mjs --revert-cursor <target> <manifest>    Cursor 側を戻す
//
// Cursor の hooks.json は形が違う（camelCase のイベント、平らな `hooks`、{ command, matcher } の項目）
// ので、Claude Code 用に押し込まず専用のマージを持つ。

import { readFileSync, writeFileSync, existsSync } from "node:fs";

const HOOK_EVENTS = new Set([
  "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop",
  "SubagentStop", "Notification", "SessionStart", "SessionEnd", "PreCompact",
]);

const readJson = (p, fallback = {}) => {
  if (!existsSync(p)) return fallback;
  const raw = readFileSync(p, "utf8").trim();
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch (e) {
    console.error(`error: ${p} が正しい JSON ではない。触らずに中止する。\n  ${e.message}`);
    process.exit(1);
  }
};

const writeJson = (p, v) => writeFileSync(p, JSON.stringify(v, null, 2) + "\n");

const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// command がこちらの hook を指す記録だけがこちらのもの（下の `dropOurs` と同じ判定）。それ以外は
// 他人が置いたもので残す。uninstall はマニフェストを読むので、落とすと他人の hook を外してしまう。
const keepForeignHooks = (records) =>
  (records ?? []).filter((r) => !/dotagents-/.test(r.command ?? ""));

const HOME = process.env.HOME ?? "";
// エージェントが hook の command 内の $HOME を展開するかは未確認。展開されないと hook が起動せず、
// ガードレールが開く側に倒れる。ここで置換して、その答えに依存しない。
const resolveHome = (cmd) =>
  typeof cmd === "string" ? cmd.replace(/\$\{?HOME\}?/g, HOME).replace(/^~(?=\/)/, HOME) : cmd;

// 以前に登録した hook 項目を、綴りを問わず落とす。落とさないと command を変えたとき（$HOME の解決、
// スクリプトの改名）に旧項目が残り、何も指さない方も含めて両方が発火する。
const dropOurs = (slots) =>
  (slots ?? [])
    .map((slot) => ({ ...slot, hooks: (slot.hooks ?? []).filter((h) => !/dotagents-/.test(h.command ?? "")) }))
    .filter((slot) => (slot.hooks ?? []).length > 0);

/**
 * プレーンオブジェクトとスカラーについて `src` を `dst` へ深くマージし、設定した葉のパスを記録する。
 * hook のイベントは置き換えでなく追記すべき配列なので別に扱う。
 */
function mergeLeaves(dst, src, recorded, prefix = "") {
  for (const [key, value] of Object.entries(src)) {
    if (key.startsWith("$")) continue; // スニペットのメタデータで、設定ではない
    const path = prefix ? `${prefix}.${key}` : key;

    if (isPlainObject(value)) {
      if (!isPlainObject(dst[key])) dst[key] = {};
      mergeLeaves(dst[key], value, recorded, path);
      continue;
    }

    // 以前こちらが書いた値でなければ既存の値は残す。意図して変えた人がいるかもしれず、install の
    // たびに上書きするツールは外される。
    if (key in dst && dst[key] !== value && !recorded.previous.includes(path)) {
      console.error(`  スキップ ${path}: 既に別の値が入っている（こちらが変えるものではない）`);
      continue;
    }

    dst[key] = value;
    recorded.keys.push(path);
  }
}

/**
 * こちらの hook command を該当イベントへ追記する。command 文字列で照合するので、install の再実行は
 * 冪等で、他人が登録した hook（rtk、notify-stop など）も乱さない。
 */
function mergeHooks(dst, src, recorded) {
  dst.hooks ??= {};
  for (const [event, matchers] of Object.entries(src)) {
    if (!HOOK_EVENTS.has(event)) {
      console.error(`  スキップ hooks.${event}: 既知の hook イベントではない`);
      continue;
    }
    dst.hooks[event] = dropOurs(dst.hooks[event]);

    for (const incoming of matchers) {
      const matcher = incoming.matcher ?? "";
      let slot = dst.hooks[event].find((m) => (m.matcher ?? "") === matcher);
      if (!slot) {
        slot = { matcher, hooks: [] };
        dst.hooks[event].push(slot);
      }
      slot.hooks ??= [];

      for (const hook of incoming.hooks ?? []) {
        const resolved = { ...hook, command: resolveHome(hook.command) };
        if (slot.hooks.some((h) => h.command === resolved.command)) continue; // 既にある
        slot.hooks.push(resolved);
        recorded.hooks.push({ event, matcher, command: resolved.command });
      }
    }
  }
}

function deletePath(obj, path) {
  const parts = path.split(".");
  const last = parts.pop();
  let cur = obj;
  for (const p of parts) {
    if (!isPlainObject(cur[p])) return;
    cur = cur[p];
  }
  delete cur[last];
}

/** こちらのキーを消して空になった入れ物を落とし、痕跡を残さない。 */
function pruneEmpty(obj, path) {
  const parts = path.split(".");
  parts.pop();
  while (parts.length) {
    let cur = obj;
    let ok = true;
    for (const p of parts) {
      if (!isPlainObject(cur[p])) { ok = false; break; }
      cur = cur[p];
    }
    if (!ok) return;
    if (Object.keys(cur).length > 0) return;
    deletePath(obj, parts.join("."));
    parts.pop();
  }
}

// ------------------------------------------------------------------ modes

const [mode, ...rest] = process.argv.slice(2);

if (mode === "--print-keys") {
  const snippet = readJson(rest[0]);
  for (const [k, v] of Object.entries(snippet)) {
    if (k.startsWith("$")) continue;
    if (k === "hooks") {
      for (const [event, matchers] of Object.entries(v))
        for (const m of matchers)
          for (const h of m.hooks ?? []) console.log(`hooks.${event}: ${h.command}`);
    } else if (isPlainObject(v)) {
      for (const sub of Object.keys(v)) console.log(`${k}.${sub}`);
    } else {
      console.log(k);
    }
  }
  process.exit(0);
}

if (mode === "--cursor") {
  const [snippetPath, targetPath, manifestPath] = rest;
  const snippet = readJson(snippetPath);
  const target = readJson(targetPath);
  const manifest = readJson(manifestPath);

  target.version ??= snippet.version ?? 1;
  target.hooks ??= {};
  const added = [];

  for (const [event, entries] of Object.entries(snippet.hooks ?? {})) {
    // Cursor の形は {command, matcher} の平らな一覧なので、こちらの項目を直接ふるい落とす。
    target.hooks[event] = (target.hooks[event] ?? []).filter((h) => !/dotagents-/.test(h.command ?? ""));
    for (const entry of entries) {
      const resolved = { ...entry, command: resolveHome(entry.command) };
      // command で照合する。install の再実行が冪等になり、他人の hook（rtk など）も乱さない。
      if (target.hooks[event].some((h) => h.command === resolved.command)) continue;
      target.hooks[event].push(resolved);
      added.push({ event, command: resolved.command });
    }
    if (target.hooks[event].length === 0) delete target.hooks[event];
  }

  writeJson(targetPath, target);
  // 追記ではなく置き換え。下の manifest.settingsHooks の注記を参照。
  manifest.cursorHooks = keepForeignHooks(manifest.cursorHooks).concat(added);
  writeJson(manifestPath, manifest);

  for (const a of added) console.error(`  追加 cursor hooks.${a.event}: ${a.command}`);
  process.exit(0);
}

if (mode === "--revert-cursor") {
  const [targetPath, manifestPath] = rest;
  const target = readJson(targetPath, null);
  const manifest = readJson(manifestPath);
  if (!target) process.exit(0);

  for (const { event, command } of manifest.cursorHooks ?? []) {
    if (!Array.isArray(target.hooks?.[event])) continue;
    target.hooks[event] = target.hooks[event].filter((h) => h.command !== command);
    if (target.hooks[event].length === 0) delete target.hooks[event];
  }
  if (target.hooks && Object.keys(target.hooks).length === 0) delete target.hooks;

  writeJson(targetPath, target);
  process.exit(0);
}

if (mode === "--revert") {
  const [targetPath, manifestPath] = rest;
  const target = readJson(targetPath, null);
  const manifest = readJson(manifestPath);
  if (!target) { console.error("戻すものが無い。対象が存在しない"); process.exit(0); }

  for (const path of manifest.settingsKeys ?? []) {
    deletePath(target, path);
    pruneEmpty(target, path);
  }

  for (const { event, matcher, command } of manifest.settingsHooks ?? []) {
    const slots = target.hooks?.[event];
    if (!Array.isArray(slots)) continue;
    const slot = slots.find((m) => (m.matcher ?? "") === matcher);
    if (!slot) continue;
    slot.hooks = (slot.hooks ?? []).filter((h) => h.command !== command);
    // matcher の枠はこちらが空にしたときだけ消す。他人の hook が残る枠は残す。
    if (slot.hooks.length === 0) target.hooks[event] = slots.filter((m) => m !== slot);
    if (target.hooks[event]?.length === 0) delete target.hooks[event];
  }
  if (target.hooks && Object.keys(target.hooks).length === 0) delete target.hooks;

  writeJson(targetPath, target);
  process.exit(0);
}

// 既定: マージ
const [snippetPath, targetPath, manifestPath] = [mode, ...rest];
const snippet = readJson(snippetPath);
const target = readJson(targetPath);
const manifest = readJson(manifestPath);

const recorded = { keys: [], hooks: [], previous: manifest.settingsKeys ?? [] };

const { hooks: snippetHooks, ...plain } = snippet;
mergeLeaves(target, plain, recorded);
if (snippetHooks) mergeHooks(target, snippetHooks, recorded);

writeJson(targetPath, target);

manifest.settingsKeys = [...new Set([...(manifest.settingsKeys ?? []), ...recorded.keys])];

// 追記ではなく置き換え。`dropOurs` が書き直し前にこちらの hook を綴りを問わず消すので、「いま書いた
// もの」が導入状態のすべてになる。追記だと古い綴りが記録に残り続け、uninstall が存在しないものを
// 外しにいく。
manifest.settingsHooks = keepForeignHooks(manifest.settingsHooks).concat(recorded.hooks);
writeJson(manifestPath, manifest);

for (const k of recorded.keys) console.error(`  設定 ${k}`);
for (const h of recorded.hooks) console.error(`  追加 hooks.${h.event}: ${h.command}`);
