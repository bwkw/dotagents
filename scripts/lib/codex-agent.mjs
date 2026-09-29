// agents/<name>.md（Claude Code / Cursor 形式）を Codex の ~/.codex/agents/<name>.toml に変換して stdout へ出す。
//
//   node codex-agent.mjs <agents/name.md>
//
// Codex が必須とするのは name・description・developer_instructions。`model` は書かない（不変条件 10:
// 書くとセッションで選んだモデルを黙って上書きする）。`readonly: true` は sandbox_mode = "read-only" に写す。
// 文字列は JSON.stringify で出す。JSON の文字列は TOML の basic string としてそのまま有効。
// 先頭行のマーカーが「こちらの生成物」の目印で、setup.sh の刈り取りと uninstall はこれを見て消す。
import fs from "node:fs";

const src = process.argv[2];
const text = fs.readFileSync(src, "utf8");
const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
if (!m) { console.error(`${src}: frontmatter が無い`); process.exit(1); }

const field = (k) => m[1].match(new RegExp(`^${k}:\\s*(.*)$`, "m"))?.[1].trim().replace(/^(["'])(.*)\1$/, "$2");
const name = field("name"), description = field("description");
if (!name || !description) { console.error(`${src}: name か description が無い`); process.exit(1); }

const out = [
  `# dotagents:generated -- ${src} から setup.sh が生成。ここを直さず元の .md を直して install する`,
  `name = ${JSON.stringify(name)}`,
  `description = ${JSON.stringify(description)}`,
];
if (field("readonly") === "true") out.push(`sandbox_mode = "read-only"`);
out.push(`developer_instructions = ${JSON.stringify(m[2].trim() + "\n")}`);
process.stdout.write(out.join("\n") + "\n");
