# 0007 — Cross-repository search stays agentic, no vector index

- **Status**: accepted, 2026-07-29
- **決定**: 複数リポジトリ横断の調査に**ベクトルDB（Milvus × Ollama + claude-context MCP）を採用しない**。virtual monorepo ディレクトリ＋エージェント検索で回す。`codegraph` は未検証のまま残す。

> **日本語の要約** — 横断調査の候補として Milvus×Ollama のローカルベクトルDBを claude-context MCP から引く構成を検討したが、採用しない。理由は4つ: ① 上流のメンテが停滞（直近30日で3コミット）② **インデックスが絶対パス単位**なので symlink で作る virtual monorepo は実体パスと別インデックスになり二重化・鮮度不整合を起こす（公式FAQに明記）③ Milvus Lite 非対応で docker 常駐（etcd＋MinIO＋Milvus）が必須、対価は自己申告の「40%トークン削減」④ **Claude Code 自身が初期の RAG＋ベクトルDB を agentic search に置き換えている**（作者が security / privacy / **staleness** / reliability を理由に挙げている）。代わりに virtual monorepo のディレクトリ、`rg` → `ast-grep` → LSP → 通読の段階的探索、そして `da-investigate` の予算と `x-codebase-explorer` の並列展開で回す。**この判断は計画ファイルにしか書かれておらず、リポジトリには残っていなかった** —— それがこの ADR を書いた理由。

## Context

The work this toolkit supports spans several repositories — a backend, a frontend, an admin surface,
infrastructure. "What would this change touch" frequently crosses those boundaries, and a
single-repository search cannot answer it.

The obvious candidate was a local vector index: build one with **Milvus × Ollama**, expose it to the
agent through the **`claude-context` MCP server**, and search semantically across a **virtual monorepo**
— a directory of symlinks to each real checkout. A comparison against **`codegraph`** was also planned.

That was investigated during the original design, decided against, and then **the decision was recorded
only in a plan file that is not part of this repository.** Which means it was, in practice, not recorded:
the reasoning was unavailable to anyone reading the repo, including a future session of the agent that
made it. This ADR exists to fix that, and the omission is itself worth noting as a pattern — the same
thing happened to the skill inventory and to the measurement gap (ADR 0006).

## Decision

**No vector index.** Cross-repository search is agentic: a virtual monorepo directory plus staged
searching, with the exploration budget doing the work an index would otherwise do.

### Why not the vector index

Four reasons, in descending order of how decisive they are:

**1. It breaks on exactly the layout it was for.** `claude-context` indexes **per absolute path**. A
virtual monorepo made of symlinks therefore produces a *different* index from the real checkout, so the
same file is indexed twice under two paths, and the two go stale independently. This is documented
upstream rather than discovered — it is a stated limitation, not a bug that might be fixed.

**2. The staleness problem is the one that matters, and Anthropic already resolved it the other way.**
Claude Code originally used RAG over a vector database and **replaced it with agentic search**, citing
security, privacy, **staleness**, and reliability. An index is a snapshot; code is not. In a workflow
where an agent is writing code continuously, the index is wrong in exactly the moments it is consulted.
Adopting an approach the tool's own authors moved away from, for the reason that most applies here, needs
a stronger argument than "semantic search sounds better".

**3. Operational cost is permanent; the benefit is self-reported.** Milvus Lite is not supported for this
use, so it means a resident docker stack — etcd, MinIO, Milvus — running to serve a personal toolkit. The
return quoted upstream is a self-reported ~40% token reduction. That trade might be right for a team with
a platform to maintain it; it is not right for something whose whole premise is that it adds nothing to
any product repository (`docs/design.md`).

**4. Upstream maintenance is thin.** Roughly three commits in the preceding thirty days, against 100+ for
comparable actively-developed tooling in the same space. A stalled dependency in the search path is a
dependency that will eventually break silently.

### What we do instead

| Layer | What |
|---|---|
| **Virtual monorepo** | A plain directory of symlinks to each checkout. It costs nothing, needs no daemon, and works with every tool below. Keep it; it was never the problematic part. |
| **Staged search** | `rg` for exact strings → `ast-grep` for structural patterns → LSP for real call graphs → reading whole files. `da-investigate` encodes this ladder, cheapest rung first, and treats reading files as the *last* rung. |
| **A budget instead of an index** | 25 file reads, 3 rounds of search refinement, then **stop and report what remains unverified**. A vector index is one way to avoid reading too much; a stated budget with an honest boundary is another, and it cannot go stale. |
| **Parallel exploration** | `x-codebase-explorer` subagents, one per independent part. The reading stays in their context and only the conclusion returns — which is the context-protection benefit an index was supposed to provide. |

The thing an index would genuinely add is *semantic* recall: finding code that is about a concept without
sharing its vocabulary. The staged ladder does not do that well, and this decision accepts the gap
rather than pretending otherwise. In practice `da-investigate`'s requirement to **retry a negative result
with different vocabulary** — aliases, indirect reach, names built from strings, non-code call sites —
covers part of it, and states which vocabularies were tried so the gap is visible.

### `codegraph`: still untested, and honestly so

A structural code-graph index was to be compared against the vector approach and **never was.** It is not
rejected — it is unevaluated, and the difference matters because a graph index has a different staleness
profile from an embedding index: it answers "what calls what", which is checkable and invalidated by
parse, rather than "what is similar to this", which is not.

If it is evaluated later, the bar it has to clear is set by reason 2 above: **what happens to it while
the agent is writing code**, and how the answer degrades when it is out of date. An index that returns
confidently wrong call graphs is worse than no index, because `da-investigate` would then cite it as
Confirmed.

## Consequences

- No daemon, no container, nothing to keep running for the toolkit to work. Consistent with the hard
  constraint that product repositories stay untouched — an index is not in a repository, but a required
  local service is the same class of coupling.
- **Semantic recall is a stated gap**, not a solved problem. When a search should have found something and
  did not, that is the gap rather than a bug in the ladder.
- The virtual monorepo stays, and stays dumb. Its value was never the indexing.
- `codegraph` remains an open question with a written bar to clear, rather than an unexamined "maybe
  later".
- MCP servers are still absent from this toolkit entirely, which keeps ADR 0003's compatibility story
  simple: nothing here depends on a server being up.
