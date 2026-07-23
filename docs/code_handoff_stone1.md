# CODE HANDOFF — STONE #1: The Brobot Data Substrate (MCP server)

> Paste everything below into Claude Code as the task brief. It is scoped deliberately tight. Honor the NON-GOALS as hard as the goals — scope creep here is the failure mode.

---

## CONTEXT

I'm building a local-first personal-AI stack ("Brobot"). The topology is already running:

- **M1 MacBook Air** = always-on brain. **iPhone 15 Pro Max** = client. They reach each other over **Tailscale**.
- I already have, in Swift on-device: `BrobotMemory.swift` (SQLite + **FTS5** + semantic embeddings) and `EmbeddingStore.swift`.
- I already have, Mac-side in Python: an **MCP tool server** and `MemoryCurator.py` (a **launchd** agent — use it as the pattern for unattended jobs).
- Inference: **Ollama** serves models Mac-side (use it for both embeddings and synthesis).

This task builds the **aggregate data substrate** — the single Mac-side source that ingestion agents write to and that Brobot queries over Tailscale. It is the foundation every later piece plugs into.

## MISSION (one sentence)

Stand up a Mac-side **MCP server** backed by a **SQLite store with hybrid lexical+vector search (FTS5 + sqlite-vec)**, plus **one** reference ingestion adapter (RSS/Atom feeds + a local drop-folder), runnable unattended via launchd and queryable from the iPhone over Tailscale.

## HARD CONSTRAINTS

1. **Extend, don't greenfield.** Mirror `BrobotMemory`'s column naming so a future Mac↔device sync is trivial. Sit alongside the existing Python MCP server (same project/venv), don't replace it.
2. **Vector store = `sqlite-vec`. Do not introduce Chroma/LanceDB/a separate vector service.** Rationale: it's a SQLite extension, so vectors live in the *same single file* as FTS5 — continuous with the stack I already maintain. Single-file, no daemon. (Note this so you don't "helpfully" swap it later.)
3. **Embeddings + synthesis go through Ollama**, not a cloud API. Default embed model `nomic-embed-text` (768-d); default synth model whatever I have pulled (make it config). Assert embedding dimension on insert.
4. **Transport must be reachable from the iPhone over Tailscale** → use an **HTTP/SSE MCP transport bound to the tailnet interface**, not stdio. (stdio can't be queried from the phone.)
5. **Local-first, no secrets in code.** All config in `config.toml`.

## DELIVERABLES (file tree)

```
brobot-substrate/
├── server.py            # MCP server (HTTP/SSE), registers the 4 tools below
├── store.py             # CORE: SQLite + FTS5 + sqlite-vec data layer
├── embed.py             # Ollama embedding client (dim-checked)
├── synth.py             # Ollama synthesis (summaries + brief generation)
├── ingest/
│   ├── base.py          # IngestionAdapter ABC: fetch() -> list[Doc]
│   └── feeds.py         # reference adapter: RSS/Atom feeds + local drop-folder
├── agents/
│   └── curate.py        # unattended job: run adapters → synth → ingest
├── com.brobot.curate.plist   # launchd template (mirror MemoryCurator.py)
├── config.toml          # feeds[], inbox_path, ollama_url, models, db_path, bind_addr
└── README.md            # run / launchd install / Tailscale query instructions
```

## SCHEMA (`store.py`, single SQLite file at `config.db_path`)

- **`documents`** — `id` (pk), `content` (text), `source` (text), `url` (text), `why` (text — *why it mattered*, may be agent- or user-supplied), `tags` (json text), `created_at` (iso), `last_surfaced_at` (iso, nullable), `importance` (real, default 0.5).
- **`documents_fts`** — FTS5 virtual table over `content` (and `why`), kept in sync on write.
- **`vec_documents`** — sqlite-vec virtual table, `embedding float[768]`, keyed to `documents.id`.
- **`surfacing_log`** — `doc_id`, `query`, `surfaced_at`, `clicked` (int, default 0). Write-only for now; this is the seed for the future improvement loop. **Do not build reweighting logic yet** — just log.

## MCP TOOLS (`server.py`)

1. **`mem_ingest(content, source, url="", why="", tags=[])`** → embed via `embed.py`, write to `documents` + `documents_fts` + `vec_documents` atomically. Return doc id. Dedup on `url` if present.
2. **`mem_search(query, k=8, mode="hybrid")`** → `mode` ∈ `{hybrid, lexical, vector}`. Hybrid = run FTS5 + vector KNN, merge with reciprocal-rank fusion, return top-k with scores. Append each hit to `surfacing_log`.
3. **`mem_recall(window="14d", k=5)`** → "temporal echo": return high-`importance` docs with `created_at` older than `window` and a null/old `last_surfaced_at`, ranked by `importance` × age. Update `last_surfaced_at` on return. (Keep it this simple for v1; leave a `# TODO: relevance-weighted recall` marker.)
4. **`brief_generate(since="7d")`** → pull docs ingested since `since`, cluster loosely by tag/source, summarize each cluster via `synth.py`, return one consolidated **"Newsletter's Newsletter"** brief (markdown). This is the payoff — make its output genuinely readable.

## REFERENCE ADAPTER (`ingest/feeds.py`)

- Reads `config.feeds[]` (list of RSS/Atom URLs) + scans `config.inbox_path` for dropped `.txt/.md/.html` files.
- For each new item: extract text, generate a 2–3 sentence `why` via `synth.py`, call `mem_ingest`.
- Idempotent (track seen entries by guid/url + file hash).

## NON-GOALS — DO NOT BUILD (this is the discipline, enforce it)

- ❌ **No** market / paper / email adapters. **One** adapter only (`feeds.py`). Make adding a second trivial via `base.py`, but don't write it.
- ❌ **No** UI, no web front-end, no InterSpace anything.
- ❌ **No** autonomous self-modification, no auto-reweighting, no prompt self-editing. `surfacing_log` collects data; that's the whole loop for now.
- ❌ **No** swapping the vector layer, no extra services, no Docker.
- ❌ **No** Mac↔device sync implementation — just keep the schema sync-compatible.

## DEFINITION OF DONE (testable on my Mac)

1. `python server.py` starts an HTTP/SSE MCP server on `config.bind_addr`, exposing the 4 tools.
2. Adding a feed URL (or dropping a file in `inbox_path`) and running `python agents/curate.py` ingests it — embedded, lexically + vector searchable.
3. `mem_search("<topic>")` returns sensible hybrid results with scores.
4. `brief_generate(since="7d")` returns a coherent markdown brief synthesized by my local model.
5. `com.brobot.curate.plist` runs `curate.py` on a schedule unattended (give me the `launchctl load` command).
6. From my iPhone over Tailscale, an MCP client can reach the server and `mem_search` returns results — confirming the Mac-as-brain path end-to-end.

## GOTCHAS TO HANDLE

- `sqlite-vec`: use the `sqlite_vec` Python package; call `db.enable_load_extension(True)` + `sqlite_vec.load(db)`. Fail loudly if extension load fails.
- Confirm the running **Ollama embeddings endpoint** (`/api/embeddings` vs `/api/embed` — version-dependent); detect or make it config.
- Bind the server to the **Tailscale interface / `0.0.0.0`** so the phone can reach it; note the tailnet IP in the README.
- Keep `store.py` dependency-light and fully unit-testable without the MCP layer.

**Start by scaffolding the tree and `store.py` + `embed.py` first; prove ingest+search work in isolation before wiring the MCP server. Show me `store.py` before building outward.**
