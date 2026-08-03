# FEATURE_SCOPE.md — GZ-BT PHOENIX EDITION v1.0
**Ratified by TyPod 2026-07-19.** Source: privacyai.acmeup.com feature page (v1.8.4–v2.2.0),
re-fetched same day. This file ships in the repo root and outranks any chat session's opinion.

**Clean-room rule:** GZ-BT clones *behavior from the public feature descriptions* below.
No decompiled code, no extracted assets, no copied UI art. Names, layouts, and copy are original.

**Engineering note (accepted, not a veto):** LLM Council on 8GB devices runs council rounds
*sequentially* when members are local models (one resident model at a time); parallel fan-out
is for remote/API members. Design accordingly.

---

## TIER 1 — RATIFIED IN (dictated explicitly)

### LLM Council (complete)
LLM Council (multi-model parallel answers) · Council Templates (7 presets incl. Debate,
Research, Game Theory) · Council Discussion Modes (Standard + Role Assignment/chairman) ·
Game Theory Mode (Classic Games + Custom Scenario, multi-round)

### Local Models (entire fold-down)
GGUF via llama.cpp engine · MLX via MLX Swift engine · Apple on-device Foundation Model ·
GGUF Vision models (Qwen-VL, PaddleOCR-VL class) · MLX Vision models · MLX Audio models
(Qwen3 TTS / ASR / VAD) · Whisper transcription (WhisperKit) · Local model tool calling ·
Local Model Template (full param surface: ctx, seed, temp, mirostat, top_k/p, min_p,
repeat penalty, batch, BOS/EOS, tool result limit…) · Download models from HuggingFace
(resumable, in-app browser) · iCloud Model Sync · Import GGUF from Files · Separate
vision projection (mmproj) auto-link · Live Transcription + Real-time Translation (11
languages, on-device) · File Transcription (SRT/VTT/text export) · Offline TTS (Kokoro-82M,
53 voices, audio export) · Read Aloud (Apple + Kokoro + MLX engines) · Voice Recognition
(dictation) · Cloud TTS (OpenAI-compatible endpoints) · Siri Integration

### Remote API (entire fold-down)
API Providers, full matrix — LLM: OpenAI, Anthropic, DeepSeek, xAI, OpenRouter, Gemini,
Perplexity, Mistral, MiniMax, HuggingFace, Kimi, Groq, Z.ai, Nvidia, GitHub, Vercel,
Nous Research, LongCat; Self-hosted: Ollama, LM Studio, llama.cpp server, vLLM, omlx,
LocalAI, Jan AI, own-gateway; Multimedia: ElevenLabs, Replicate, Fal.ai, Stability,
Runway · Remote Model Template (clone/duplicate) · Model Cost Estimation & Comparison ·
4 protocols (OpenAI Chat Completions, OpenAI Responses, Anthropic, HF Inference) ·
Multiple Named Endpoints per API key · Self-Hosted Server Support (address+port, no key) ·
API Rate & Credit Monitoring · Local HTTP AI Gateway (device as OpenAI-compatible server)
· Gateway vision input · Token Statistics

### Tools & Features (as dictated)
**HATS** — the persona system (Souls, renamed). Character identity per chat: name,
personality, scenario, background, auto-injected; built-in library; custom HAT creation;
avatar in chat view. **Explicitly excluded: TavernAI card import/export** — HATS is
personas without the card ecosystem.
**Prompts** — reusable saved prompts · curated community library · pin favorites
**Memory** — memory store (add/edit/delete) · Memory Sectors (life/work/study) · Chat
with Memory (auto-inject) · Import Memory from Conversation (one-tap extraction) ·
Semantic Memory Search
**KNOWLEDGE WIKI (complete, flagship)** — Add Sources From Anywhere (PDF/Word/EPUB/web/
MD/CSV/photos/video, whole-document reads, batch w/ progress) · Ask Your Knowledge Base
(cited answers, Quick/Thorough, save-back) · Interactive Knowledge Graph (clusters,
pinch/drag/tap) · Automatic Overview & Insights · Wikis In Your Language · Git Sync
(publish/pull/clone, history, line diffs, restore) · Wiki Health Check (orphans, broken
links, optional AI contradiction review) · on-device Markdown, Obsidian-compatible
**Reader** — Enhanced Web Reader: URL → clean Markdown, batch URLs, JS rendering

### Tools & MCP (entire fold-down — all ~50 tools)
**Search & Info:** search_web · search_news · search_wikipedia · search_paper ·
read_hackernews · search_podcast · search_places · search_book · search_steam
**Finance:** search_stock · search_crypto · search_exchange_rate · search_polymarket
**Data & Analysis:** analyze_data · correlate_data · regress_data · calculate_expression
· create_chart · sequential_thinking
**System & Device:** get_date · get_my_location · get_weather · get_health_data ·
get_direction · manage_calendar · manage_reminder · manage_alarm · send_email ·
send_sms · search_contact · call_shortcut
**File & Workspace:** use_workspace · use_filesystem · read_file · edit_file ·
run_shell (iOS sandboxed 150+ cmds / macOS full zsh) · grep_file · fetch_url
**Scripting & Dev:** run_javascript · search_database · manage_appstore_connect
**Memory tools:** search_memory · manage_memory · tidy_memory
**AI Generation tools:** generate_image · generate_voice · generate_video · generate_music
**Utilities:** use_clipboard · create_note · post_tweet · tools (self-discovery)
**Orchestration:** run_agent (sub-agents) · manage_plan
**MCP:** MCP Protocol Support · MCP Market · MCP Authorization headers

### Settings / System Integration (entire fold-down)
iPhone + iPad native · macOS native (menu bar, shortcuts, resizable windows) · Theme
support (Light/Dark/Auto, iOS 18 dark icon) · Model Settings (full local + remote param
surfaces) · Auto Tool Selector · Chat Theme Customization (fonts/colors/display modes/FPS)
· Multiple Search Engines w/ fallback · Storage Management (breakdown + one-tap cleanup) ·
System Prompt (per-model + per-chat) · Share Extension family: Share Anything, Prompt
Template & quick actions, Model/Folder Selection, Attachment Preprocessing, Tool
Configuration · iCloud Sync (chats/memories/templates/settings) · Clipboard Integration ·
Image Text Extraction (on-device OCR) · Natural Talk UI (hands-free voice loop) · Quick
Actions (Home Screen) · What's New screen · Cost Report + Export

---

## TIER 2 — STUBS (tab exists, minimal viable content, wired for later)
- **RSAI tab** — recursive propose-test-keep-kill researcher. Stub: tab + placeholder
  pipeline UI. Scope its real v1 in its own doc.
- **OSINTINEL tab** — OSINT sentinel. Stub: tab + bridge to the existing Python engine
  (repo: ChckaX2-slimshady/OSINTINEL) via local server or MCP. Scope separately.

## TIER 3 — GZ-BT ONLY (the reasons this app exists)
- **Spectre tab** — metrics + benchmarks surface for the inference optimization layer.
  **Global toggle, default OFF** — Spectre incorporates at will, never blocks the app.
  Seam contract underneath (engine-neutral, per-engine bindings), per Spectre SSOT v2.3.
- **Stone #1 substrate** — arrives via the ratified MCP support + one server entry
  pointing at the Mac over Tailscale. No bespoke client code.

## RATIFIED OUT (do not build, do not stub)
- Novel Writer
- TavernAI character-card import/export (HATS keeps the persona concept only)
- AI Keyboard

## DEFAULT-IN (came with "clone the website"; not individually dictated — strike freely)
- **Smart Chat suite:** Automatic Model Routing · Tiered Model Setups · Privacy-Aware
  Routing · Cost Budgets & Statistics
- **Chat features (all):** pin · year-month groups · 3-level folders · passcode ·
  collapsible messages · tool-call history panel · rethinking · refresh · attachments
  (6 entry paths + to-Markdown converter) · attachment preview · chat copy · clone/fork ·
  parallel conversations (8/12) · edit sent messages · context usage indicator · drafts ·
  drag-and-drop (iPad) · multi-image · chat share (7 formats) · thinking content view ·
  thinking model support · full Markdown + LaTeX · citation preview cards · WebView code
  preview · SVG render · Mermaid render · syntax highlighting
- **Document & Media:** Smart Document Processing (+OCR) · multi-file attachments ·
  multi-URL · Chat with Document · Chat Workspace · large-file chunking · ZIP · VCard/ICS
  · multi-sheet Excel · GZip · YouTube captions · Image Generation/Editor/Interactive ·
  Video/Voice/Music Generation (feature-level; the tools are already Tier 1)
- **Developer tools:** iOS sandboxed terminal · macOS full terminal · Chat Inspector ·
  External Proxy support
- **Flagged for your call:** View Assistant (camera scene-description mini-app)

## BUILD SESSION ROADMAP

**This block maps tiers above onto build sessions. It amends the scope of record; it does not
replace it.** Scope is still ratified by tier — a session number is a *delivery slot*, not a
new authority. Where the two disagree, the tier wins.

**Numbering is not contiguous and never was.** S4, S6 and S7 were named during Session 2 as
one-line forward slots, *before* S3.25/.5/.75 were inserted by BUILD_SESSION_3 §1. So "S4"
means "whenever HATS happens", not "the session after S3.75". There is no S5 — earlier greps
that appeared to find one were matching `FTS5`.

### Shipped

| Session | Tag | Delivered |
|---|---|---|
| **S1** | `v0.1.0-phoenix-s1` | Shell, DesignSystem, MLX chat vertical slice, Seam-1 |
| **S2** | `v0.2.0-phoenix-s2` | Persistence & session model; gates G1 (iPhone deploy), G2 (CI drift guard), G3 (S1 tagged) |
| **S2.5** | `v0.2.5-phoenix-s2.5` | Spectre view as Seam-1 falsification test |
| **S3 recon** | `v0.2.6-phoenix-s3-recon` | Read-only reconnaissance; `Sources/` byte-identical to S2.5 |
| **S3** | `v0.3.0-phoenix-s3` | Model download & management. Closes DECISIONS #26's hole: a fresh device fetches its own model |

Session specs exist for **S2** and **S3** only (`BUILD_SESSION_2.md`, `BUILD_SESSION_3.md`).
S1 and S2.5 are recorded in DECISIONS alone.

### Specced, in order — a dependency chain, not a preference

From BUILD_SESSION_3 §1, which routed S3 recon's deferred decisions:

| Session | Scope | Carries |
|---|---|---|
| **S3.25** | Seam-1 amendment. Half session | recon #10, #11 — `GenerationSummary` optionality; endpoint/credential seat on the load path |
| **S3.5** | One remote provider | recon #8, #9 — credentials, Keychain |
| **S3.75** | Benchmark harness | recon #12 — must run across *engines*, not just models, or it cannot test model-agnosticism. Also owns #13's real perf reconciliation |

S3.75 needs S3.25 and S3.5 to exist first; that ordering is structural.

### Named, not specced

One-line forward references. Listed so they are not mistaken for a plan:

| Session | Scope | Sole reference |
|---|---|---|
| **S4** | HATS (persona system) | `persona_id TEXT, -- forward slot for HATS (S4)` — BUILD_SESSION_2 §schema |
| **S6** | FTS5 / search; the point where GRDB is re-evaluated | DECISIONS #21 |
| **S7** | Sequential local council rounds on 8 GB | BUILD_SESSION_2 §G1 rationale, citing this doc's LLM Council |

### Unallocated

Everything else in Tier 1 has **no session number yet** — Tools & MCP (~50 tools), the Settings
/ System Integration fold-down, and the remainder of the Local Models and Remote API fold-downs.
Tier 2 (RSAI, OSINTINEL stubs) and Tier 3's Stone #1 substrate are likewise unassigned; Tier 3's
Spectre tab has a live dashboard from S2.5 but its internals — benchmarks, history — begin at
S3.75 and are otherwise unscoped.

Adding a session number to any of these is a ratification, not a planning exercise.

## OUT OF SCOPE FOR THIS DOC
Free/Pro plan structure (GZ-BT's own monetization is a separate decision), App Store
listing, marketing site.
