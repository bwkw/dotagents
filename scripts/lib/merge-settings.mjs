#!/usr/bin/env node
// Merge only the keys our snippet declares into ~/.claude/settings.json, and record exactly what
// we wrote so uninstall can take back precisely that much.
//
// The file we are editing contains secrets that are not ours -- env.OTEL_EXPORTER_OTLP_HEADERS
// carries a Datadog API key in plaintext. We never read, copy, or rewrite a value we did not
// write ourselves. Keys absent from the snippet are untouched, including inside objects we do
// merge into.
//
//   merge-settings.mjs <snippet> <target> <manifest>          merge and record
//   merge-settings.mjs --revert <target> <manifest>           undo exactly what was recorded
//   merge-settings.mjs --print-keys <snippet>                 list what a merge would touch
//   merge-settings.mjs --cursor <snippet> <target> <manifest> same, for ~/.cursor/hooks.json
//   merge-settings.mjs --revert-cursor <target> <manifest>    undo the Cursor side
//
// Cursor's hooks.json has its own shape -- camelCase events, a flat `hooks` object, and entries of
// { command, matcher } -- so it gets its own merge rather than being forced through Claude Code's.

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
    console.error(`error: ${p} is not valid JSON -- refusing to touch it.\n  ${e.message}`);
    process.exit(1);
  }
};

const writeJson = (p, v) => writeFileSync(p, JSON.stringify(v, null, 2) + "\n");

const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

const HOME = process.env.HOME ?? "";
// Whether an agent expands $HOME inside a hook command was never verified. An unexpanded path is a
// command that does not exist, which is a hook that never starts, which is a guardrail that fails
// open. Substitute here and stop depending on the answer.
const resolveHome = (cmd) =>
  typeof cmd === "string" ? cmd.replace(/\$\{?HOME\}?/g, HOME).replace(/^~(?=\/)/, HOME) : cmd;

// Drop hook entries this toolkit registered before, whatever spelling they used. Without this,
// changing a command string (a literal $HOME that is now resolved, a renamed script) leaves the old
// entry in place and both fire -- one of them pointing at nothing.
const dropOurs = (slots) =>
  (slots ?? [])
    .map((slot) => ({ ...slot, hooks: (slot.hooks ?? []).filter((h) => !/dotagents-/.test(h.command ?? "")) }))
    .filter((slot) => (slot.hooks ?? []).length > 0);

/**
 * Deep-merge `src` into `dst` for plain-object and scalar values, recording each leaf path we set.
 * Hook events are handled separately because they are arrays that must be appended to, not replaced.
 */
function mergeLeaves(dst, src, recorded, prefix = "") {
  for (const [key, value] of Object.entries(src)) {
    if (key.startsWith("$")) continue; // metadata in the snippet, not settings
    const path = prefix ? `${prefix}.${key}` : key;

    if (isPlainObject(value)) {
      if (!isPlainObject(dst[key])) dst[key] = {};
      mergeLeaves(dst[key], value, recorded, path);
      continue;
    }

    // Leave an existing value alone unless it is one we previously wrote. Someone may have
    // deliberately changed it, and clobbering that on every install is how tools get uninstalled.
    if (key in dst && dst[key] !== value && !recorded.previous.includes(path)) {
      console.error(`  skipped ${path} -- already set to a different value (not ours to change)`);
      continue;
    }

    dst[key] = value;
    recorded.keys.push(path);
  }
}

/**
 * Append our hook commands to the matching event, keyed by command string so re-running install
 * is idempotent and so we never disturb hooks someone else registered (rtk, notify-stop, ...).
 */
function mergeHooks(dst, src, recorded) {
  dst.hooks ??= {};
  for (const [event, matchers] of Object.entries(src)) {
    if (!HOOK_EVENTS.has(event)) {
      console.error(`  skipped hooks.${event} -- not a known hook event`);
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
        if (slot.hooks.some((h) => h.command === resolved.command)) continue; // already present
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

/** Drop containers that became empty once our keys were removed, so we leave no residue. */
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
    // Cursor's shape is a flat list of {command, matcher}, so ours are filtered directly.
    target.hooks[event] = (target.hooks[event] ?? []).filter((h) => !/dotagents-/.test(h.command ?? ""));
    for (const entry of entries) {
      const resolved = { ...entry, command: resolveHome(entry.command) };
      // Key on the command so re-running install is idempotent, and so hooks someone else
      // registered here -- rtk, for one -- are never disturbed.
      if (target.hooks[event].some((h) => h.command === resolved.command)) continue;
      target.hooks[event].push(resolved);
      added.push({ event, command: resolved.command });
    }
    if (target.hooks[event].length === 0) delete target.hooks[event];
  }

  writeJson(targetPath, target);
  manifest.cursorHooks = [
    ...(manifest.cursorHooks ?? []),
    ...added.filter(
      (a) => !(manifest.cursorHooks ?? []).some((e) => e.event === a.event && e.command === a.command),
    ),
  ];
  writeJson(manifestPath, manifest);

  for (const a of added) console.error(`  added cursor hooks.${a.event}: ${a.command}`);
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
  if (!target) { console.error("nothing to revert -- target does not exist"); process.exit(0); }

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
    // Remove the matcher slot only if we emptied it; keep slots that still hold others' hooks.
    if (slot.hooks.length === 0) target.hooks[event] = slots.filter((m) => m !== slot);
    if (target.hooks[event]?.length === 0) delete target.hooks[event];
  }
  if (target.hooks && Object.keys(target.hooks).length === 0) delete target.hooks;

  writeJson(targetPath, target);
  process.exit(0);
}

// default: merge
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
manifest.settingsHooks = [
  ...(manifest.settingsHooks ?? []),
  ...recorded.hooks.filter(
    (h) => !(manifest.settingsHooks ?? []).some((e) => e.event === h.event && e.command === h.command),
  ),
];
writeJson(manifestPath, manifest);

for (const k of recorded.keys) console.error(`  set ${k}`);
for (const h of recorded.hooks) console.error(`  added hooks.${h.event}: ${h.command}`);
