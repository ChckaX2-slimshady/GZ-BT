# S3_RECON.md — Session 3 reconnaissance

**Read-only.** No code changed, no files added except this one. Every claim below was
verified in this session against the actual file on disk, per CLAUDE.md Gotcha #3.
Repo state at time of writing: `HEAD = d5be989`, tags `v0.1.0-phoenix-s1`,
`v0.2.0-phoenix-s2`, `v0.2.5-phoenix-s2.5`. `QUESTIONS.md` has no open items.

**No design proposals appear in this document.** Where a fact constrains a future
design, it is recorded as a constraint and nothing more.

### Path aliases used below

| Alias | Real path |
|---|---|
| `SHF/` | `~/Library/Developer/Xcode/DerivedData/GZ-BT-gmbzogmkhxoywgdwqpcsghxdbywp/SourcePackages/checkouts/swift-huggingface/` |
| `STF/` | `…/SourcePackages/checkouts/swift-transformers/` |
| `MLM/` | `…/SourcePackages/checkouts/mlx-swift-lm/` |

`SHF` HEAD verified as `b721959445b617d0bf03910b2b4aced345fd93bf`, tag `0.9.0` — exactly the
revision pinned in `GZ-BT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

---

## 1. What exists today

### 1.1 `ModelManager` (`Sources/Services/ModelManager.swift`)

`@MainActor @Observable final class`, 116 lines. Sole filesystem scanner (DECISIONS #18).

| Member | Line | Notes |
|---|---|---|
| `models: [DiscoveredModel]` | :14 | `private(set)`, sorted by name, case-insensitive |
| `isScanning: Bool` | :15 | `private(set)`; set/cleared synchronously inside `scan()` via `defer` |
| `activeModelID: String?` | :17–19 | writes through to `UserDefaults` key `models.activeModelID` on `didSet` |
| `static var modelsRoot: URL` | :23–27 | computed each access; see §1.3 |
| `resolve(_:) -> ResolvedModel` | :39–41 | copies `id`, `name`, `url`, `contextLength` |
| `scan()` | :43–63 | synchronous, blocking, on the main actor |
| `reconcileSelection()` | :65–71 | private |
| `static inspect(_:) -> DiscoveredModel?` | :75–105 | private; the discovery predicate |
| `static directorySize(_:) -> Int64` | :107–115 | private |

**`scan()` is synchronous and main-actor-bound** (`ModelManager.swift:43`). It is not
`async`. `isScanning` is therefore never observably `true` from the UI — it is set and
cleared inside one main-actor turn. `directorySize` (:107) walks every file in every
candidate directory with a `FileManager.enumerator`, on the main thread, once per `scan()`.

**Discovery predicate** (`ModelManager.swift:75–82`) — a directory qualifies iff **all three** hold:
1. `config.json` exists (`fileExists(atPath:)`),
2. some entry name `hasSuffix(".safetensors")`,
3. some entry name is exactly `tokenizer.json` **or** exactly `tokenizer.model`.

Only the **immediate children** of `modelsRoot` are considered (`contentsOfDirectory`,
`ModelManager.swift:48–51`), filtered to `isDirectory == true` (:58). Discovery is **not**
recursive — a model nested two levels deep is invisible.

Metadata parsed from `config.json` (`ModelManager.swift:84–95`), all optional and all
failure-tolerant (`try?` throughout):
- `architecture` ← `model_type`
- `quantization` ← `quantization.bits` formatted as `"\(bits)-bit"`
- `contextLength` ← `max_position_embeddings`, falling back to `text_config.max_position_embeddings`

`id` and `name` are both `dir.lastPathComponent` (`ModelManager.swift:98–99`) — **the
directory name is the model's identity**, and it is what `activeModelID` persists and what
`MessageTelemetry.modelID` records.

`reconcileSelection()` (:65–71) auto-selects when exactly one model is present and the
current selection is invalid; otherwise it falls back to `models.first`.

### 1.2 `DiscoveredModel` / `ResolvedModel`

`Sources/Models/DiscoveredModel.swift:5–13` — `Sendable, Identifiable, Hashable`; all `let`:
`id`, `name`, `url`, `architecture: String?`, `quantization: String?`, `sizeBytes: Int64`,
`contextLength: Int?`.

`Sources/Models/ResolvedModel.swift:7–19` — `Sendable, Identifiable, Hashable`; all `let`:
`id`, `name`, `url: URL` (**non-optional**), `contextLength: Int?`.

Neither type carries a remote identifier, a repo id, a revision/commit, a download state, a
provider, or a base URL. `ResolvedModel.url` is a non-optional local `URL` and is the only
thing the engine is handed (`MLXInferenceEngine.swift:36`).

### 1.3 How the store path resolves now — and what `GZBT_STORE_PATH` actually does

**Model store** (`ModelManager.swift:23–27`):

```swift
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "GZ-BT/Models", directoryHint: .isDirectory)
```

- macOS (non-sandboxed per DECISIONS #19 — confirmed: no `.entitlements` file in the repo,
  `ENABLE_HARDENED_RUNTIME: NO` at `project.yml:47`) → `~/Library/Application Support/GZ-BT/Models`.
- iOS → `<app container>/Library/Application Support/GZ-BT/Models`.

There is **no override, no setting, and no user control** over the model store path. It is a
computed `static var` with no injection point. `ModelsViewModel.storePath`
(`Sources/ViewModels/ModelsViewModel.swift:17`) only *displays* it.

`scan()` never creates the directory. If it does not exist, `contentsOfDirectory` fails, the
`guard` at `ModelManager.swift:48–55` takes the else branch, `models = []`, and discovery
reports empty — indistinguishable from "directory exists but is empty."

**`GZBT_STORE_PATH` does not touch the model store.** It overrides the **conversation SQLite
database** only, and only in DEBUG (`Sources/App/AppEnvironment.swift:30–39`):

```swift
#if DEBUG
let override = ProcessInfo.processInfo.environment["GZBT_STORE_PATH"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
let store = ConversationStore(url: override)
#else
let store = ConversationStore()
#endif
```

It is consumed by `ConversationStore.init(url:)` (`Sources/Services/ConversationStore.swift:28–30`)
and resolved at `ConversationStore.start()` as `url ?? ConversationDatabase.defaultURL()`
(`ConversationStore.swift:36`). **Setting `GZBT_STORE_PATH` redirects chat history and leaves
model discovery pointed at the real store.** QUESTIONS Q4 resolved to keep it.

Actual state on this machine:

```
~/Library/Application Support/GZ-BT/
├── gzbt.sqlite  (+ -shm, -wal)
└── Models/
    └── Ternary-Bonsai-1.7B-mlx-2bit/
```

### 1.4 `AppSettings` (`Sources/Services/AppSettings.swift`)

19 lines. Exactly **one** stored setting: `spectreEnabled: Bool` (:10–12), persisted to
`UserDefaults` key `settings.spectreEnabled` on `didSet`, read back in `init` via
`UserDefaults.standard.bool(forKey:)` (:17) — so the absent-key default is `false`, matching
the ratified default-OFF.

There is no settings storage abstraction: it is a direct `UserDefaults` read/write per
property. No token storage, no credential storage, no URL/endpoint storage, no
download-preference storage. Adding an *n*th setting means adding an *n*th property with its
own `didSet` and its own key constant.

Note the split: model selection (`activeModelID`) lives in `ModelManager`
(`ModelManager.swift:17–21`), not in `AppSettings`.

### 1.5 What a newly-downloaded model must look like on disk for discovery to find it unchanged

Given §1.1, a download would have to produce **exactly this shape**:

```
~/Library/Application Support/GZ-BT/Models/    ← ModelManager.modelsRoot, verbatim
└── <SomeDirectoryName>/                       ← immediate child; becomes id AND name
    ├── config.json                            ← required, must be real (not a symlink to nowhere)
    ├── <anything>.safetensors                 ← required, ≥1, by filename suffix
    └── tokenizer.json  (or tokenizer.model)   ← required, exact filename
```

Empirically confirmed against the working model:

```
Ternary-Bonsai-1.7B-mlx-2bit/     473 MB total (du -sh)
  model.safetensors               484,049,216 B
  tokenizer.json                   11,422,650 B
  config.json                           2,939 B
  chat_template.jinja / tokenizer_config.json / model.safetensors.index.json
  README.md / LICENSE / NOTICE.txt / .gitattributes / .hfmanifest.json
  assets/ .eval_results/
```

`config.json` yields `model_type: "qwen3"`, `quantization: {bits: 2, group_size: 128}`,
`max_position_embeddings: 32768`. Asserted by `Tests/ModelDiscoveryTests.swift:26–29`.

Constraints that fall out of this, stated as constraints only:

- **The directory name is the primary key.** A repo id like `mlx-community/Foo-4bit`
  contains a `/`; it cannot be a directory name at this level. Whatever name is chosen
  becomes `DiscoveredModel.id`, the `UserDefaults` selection value, and
  `message_telemetry.model_id` — and is the only handle discovery has.
- **Nesting breaks discovery.** `<root>/models/<org>/<name>/` is invisible; `scan()` looks
  one level down only.
- **Symlinked trees are partly hostile.** `fileExists` and `contentsOfDirectory` follow/list
  symlinks so `inspect` would still match, but `directorySize` (`ModelManager.swift:107–115`)
  reads `.fileSizeKey` off the enumerated URLs; for a tree of symlinks that is the link size,
  not the target size, so `sizeBytes` would be wrong (near zero) rather than absent.
- **There is no partial/incomplete state in the model.** A half-downloaded directory that
  happens to contain `config.json`, one `.safetensors` and `tokenizer.json` is
  indistinguishable from a complete one, and will be offered as selectable and loadable.
- **No trigger exists.** `scan()` runs from `ModelsViewModel.onAppear()` (:19–21, and only if
  `models.isEmpty`), `rescan()` (:23), and `ChatViewModel.ensureModelLoaded()`
  (`ChatViewModel.swift:269`, again only if empty). Nothing watches the directory.

---

## 2. swift-huggingface 0.9.0 — read in-session

### 2.0 Dependency status — precise, because it is not what the brief assumed

`project.yml` declares **two** packages (`project.yml:11–21`) and **two** product
dependencies: `MLXLLM` and `MLXLMCommon` (`project.yml:31–35`). swift-huggingface appears
nowhere in `project.yml`.

It arrives transitively: `mlx-swift-lm` → `swift-transformers 1.2.1` → `swift-huggingface 0.9.0`.
Confirmed by `STF/Sources/Hub/HubApi.swift:10` (`import HuggingFace`).

The modules **are built and present** for all three platforms — verified in
`Build/Products/{Debug,Debug-iphoneos,Debug-iphonesimulator}/`:
`HuggingFace.swiftmodule`, `Hub.swiftmodule`, `Tokenizers.swiftmodule`, `MLXLMCommon.swiftmodule`.
So `import HuggingFace` and `import Hub` are reachable today without a `project.yml` edit,
by implicit transitive module visibility rather than a declared dependency.

**There are two HF layers, not one, and the substrate uses the outer one.**
`MLM/Libraries/MLXLMCommon/Load.swift:22–39` — `downloadModel(hub:configuration:progressHandler:)`
calls `hub.snapshot(from:revision:matching:progressHandler:)` on **`HubApi` from
swift-transformers**, with `matching: ["*.safetensors", "*.json", "*.jinja"]`.
`HubApi` in turn delegates the byte transfer to swift-huggingface's `HubClient.downloadFile`
(`STF/Sources/Hub/HubApi.swift:849–856`). Both layers are described below because they
answer the brief's questions differently.

### 2.1 Capability matrix — swift-huggingface 0.9.0 (`HubClient`)

| Capability | Provided? | Evidence |
|---|---|---|
| File download to a destination | **Yes** | `downloadFile(at:from:to:kind:revision:endpoint:cachePolicy:progress:transport:localFilesOnly:)` — `SHF/…/HubClient+Files.swift:434–816` |
| File download to `Data` | Yes | `downloadContentsOfFile(at:from:…) -> Data` — :329–420 |
| Whole-repo snapshot | **Yes** | `downloadSnapshot(of:kind:to:revision:matching:localFilesOnly:maxConcurrentDownloads:progressHandler:)` — :1152–1173; glob-filtered via `fnmatch` (:1293) |
| **Resume after interruption** | **Yes, but only on the ETag+cache path** | :587–651. Sends `Range: bytes=<offset>-` (:591) from the size of an `.incomplete` blob (:589); handles `206` merge (:644, :658–679), `416` restart (:629–636), and servers that ignore `Range` and answer `200` (:647–651) |
| Resume from `URLSession` resume data | Yes (Apple platforms only) | `resumeDownloadFile(resumeData:to:progress:)` — :885–901, inside `#if !canImport(FoundationNetworking)` |
| Progress reporting | **Yes** | `progress: Progress?` param; `DownloadProgressDelegate` — :943–975. Correctly offsets by `resumeOffset` when status is `206` (:960–964). Snapshot progress: parent/child `Progress` tree (:1319) sampled every 100 ms (:1466) |
| Auth (gated repos) | **Yes** | `TokenProvider` — `SHF/…/Shared/TokenProvider.swift:92–208`; cases `.fixed`, `.environment`, `.oauth`, `.composite`, `.custom`, `.none`. Applied as `Authorization: Bearer <token>` at `Shared/HTTPClient.swift:370–372` |
| ETag verification | **Partial — used for cache identity, not integrity** | `FileMetadata` reads `X-Linked-Etag` / `ETag` / `X-Repo-Commit` (:281–294); normalized (:296–310) and used as the blob key. HEAD preflight at :507–512 |
| **Checksum verification** | **NO — dead code** | `computeFileHash(at:)` exists at :2009–2046 and is **never called**. `grep -rn "computeFileHash" SHF/Sources/` returns the definition only. Nothing in swift-huggingface compares a downloaded file against a hash |
| Repo/file listing | **Yes** | `listFiles(in:kind:revision:recursive:) -> [Git.TreeEntry]` — :1061–1077 (`entry.path`, `entry.size`); `getFile(at:in:kind:revision:) -> File` — :1086–1129 via `HEAD` + `Range: bytes=0-0`, returning `exists`/`size`/`etag`/`revision`/`isLFS` |
| Model search / browse | **Yes** | `listModels` / `getModel` / `getModelTags` — `SHF/…/Hub/HubClient+Models.swift:69, 126, 163` |
| Gated-repo access request | Yes | `requestModelAccess` — `HubClient+Models.swift:176` |

### 2.2 What swift-huggingface 0.9.0 does **not** provide

1. **No content integrity check.** `computeFileHash` is dead code (`HubClient+Files.swift:2009`).
   A truncated or corrupted body that arrives with a `200` and a plausible ETag is cached and
   returned as success.
2. **No background-session capability of its own.** `grep -rni "background" SHF/Sources/`
   returns **zero** matches. Every session is `URLSession(configuration: .default)` by default
   (`HubClient.swift:110, 133, 158`; `HTTPClient.swift:49`) — injectable, but see §3.1.
3. **No disk-space preflight.** Nothing queries free space before writing.
4. **No download queue, pause/cancel handle, or persisted job state.** Cancellation is
   Swift task cancellation only (`HubClient+Files.swift:608`); nothing survives process death
   except the on-disk `.incomplete` blob.
5. **No Keychain storage.** `TokenProvider` *reads* a token; it never stores one.
   `FileTokenStorage` (`SHF/…/OAuth/TokenStorage.swift:15–104`) is plaintext JSON at
   `~/Library/Caches/huggingface/token.json`, chmod `0600` (:70–75). See §5 for the one
   Keychain path that does exist.
6. **Resume is conditional, not guaranteed.** The resume loop at :587 is inside
   `if let cache, let etag = preflightMetadata?.normalizedEtag` (:519). With `cache: nil`, or
   when the HEAD preflight fails (it is `try?`, :509), control reaches the generic fallback at
   :732 where `let resumeOffset: Int64 = 0` (:733) is hardcoded — **no resume at all**.
7. **`downloadSnapshot(to:)` with `cache: nil` downloads everything and then throws.**
   The entry guard admits `cache == nil && destination != nil` (:1227–1229), all files
   download to `destination` (:1345–1361), then :1379–1381 executes
   `guard let cache else { throw HubCacheError.snapshotRequiresCacheOrDestination }`.
   The bytes land on disk; the call reports failure. Verified by reading the control flow;
   not reproduced at runtime in this session.
8. **Xet transport is compiled out.** All Xet paths are behind `#if HUGGINGFACE_ENABLE_XET`
   (:12, :358, :475), a package trait not enabled here. `transport: .xet` throws
   (:350–356). Large-file downloads are classic LFS.

### 2.3 What `HubApi` (swift-transformers 1.2.1) adds on top

This layer matters because it is what the ratified substrate actually calls.

| Capability | Status | Evidence |
|---|---|---|
| **SHA256 verification** | **Yes — live, not dead** | `isValidSHA256` (:679), `computeFileHash(file:)` (:685–~700), used at :813–821: when the remote ETag is a valid SHA256 (i.e. an LFS file), the local file is hashed and compared before being accepted as up-to-date |
| **Background session** | **Declared** | `useBackgroundSession: Bool = false` (:151); `URLSessionConfiguration.background(withIdentifier: "\(bundleIdentifier).hub.hubclient.background")` at :121–127; separate `backgroundCachedClient` / `backgroundUncachedClient` (:191–205), selected at :840–848. **See §3.1 — this is the finding to falsify.** |
| Offline mode | Yes | `useOfflineMode: Bool?` (:152); `NetworkMonitor.shared.state.shouldUseOfflineMode()` (:900) |
| Per-file local metadata | Yes | `.cache/huggingface/download/` sidecar under the repo dir (:897–899); `readDownloadMetadata` (:629), `writeDownloadMetadata` (commit\netag\ntimestamp) |
| Token | Yes | `hfToken: String?` (:149) → `.fixed`, else `.environment` (:154–159) |
| Default download location | **`Documents/huggingface`** | :160–165 — `FileManager.default.urls(for: .documentDirectory, …).first!.appending(component: "huggingface")`. Overridable via `downloadBase:` (:147) |
| Materialized layout | `downloadBase/<repoType>/<repo.id>/` | `localRepoLocation(_:)` :618–620 — e.g. `…/models/mlx-community/Foo-4bit/`, i.e. **two levels below** the type dir |
| Progress | Yes | `Progress` + `DownloadProgressBridge` (:828–831) |

Observation, recorded as fact: `HubApi` computes `incompleteDestination` and calls
`prepareCacheDestination` on it (:823–824), deletes any existing incomplete file (:825–827),
and then **never passes it to `downloadFile`** (:849–856). Resume in this version therefore
happens entirely inside swift-huggingface's cache-blob path, not in `downloadBase`.

---

## 3. iOS constraints

### 3.1 Background download of a 473 MB file — the structural conflict

> **RESOLVED EMPIRICALLY — 2026-07-31. The claim is confirmed, and the failure mode is
> worse than a thrown error: it is an uncatchable ObjC exception that aborts the process
> (SIGABRT). See §3.1a for the run.** The prose below is the pre-run source analysis and is
> left intact because the prediction and the result agree.

**Does swift-huggingface use `URLSession`?** Yes, exclusively —
`session.download(for:delegate:)` for files (`SHF/…/HubClient+Files.swift:600–606`),
`session.data(for:)` for metadata and JSON, `session.upload(...)` for uploads.

**Can it take a background configuration?** The session is injectable
(`HubClient.init(session:…)`, `HubClient.swift:157–180`), and `HubApi` already injects one
(`STF/…/HubApi.swift:240`). But the SDK documents the call it makes as unavailable there.

Verified in-session from
`$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Headers/NSURLSession.h:244–252`:

> ```
> /*
>  * NSURLSession convenience routines deliver results to
>  * a completion handler block.  These convenience routines
>  * are not available to NSURLSessions that are configured
>  * as background sessions.
>  * …
>  */
> @interface NSURLSession (NSURLSessionAsynchronousConvenience)
> ```

`URLSession.download(for:delegate:)` is the Swift async surface of that category. So:

- `HubApi(useBackgroundSession: true)` constructs a genuine background session
  (`HubApi.swift:121–127`) and hands it to a client whose only download path is a convenience
  routine the SDK declares unavailable on background sessions.
- **This is a documented conflict, not an observed failure.** It was not executed in this
  session. It is the single highest-value thing to falsify empirically before any S3 plan
  depends on background downloading, and it is stated here as a claim to test, not a defect
  to fix.

Related facts, same header:
- `sessionSendsLaunchEvents` defaults to `YES` for background configs, and
  **"macOS apps based on AppKit do not support background launch"** (`NSURLSession.h:793–799`)
  — the behaviour is asymmetric across the two platforms this app ships to.
- Redirects are always followed silently on background sessions and the delegate callback is
  never invoked (`NSURLSession.h:1035`). The Hub `resolve` endpoint redirects to a CDN host.
- `URLSessionConfiguration.sharedContainerIdentifier` is required for app **extensions**
  only (`NSURLSession.h:786–790`) — not applicable to the app target as it stands.

`Info.plist` is generated (`GENERATE_INFOPLIST_FILE: YES`, `project.yml:41`) and there is no
`.entitlements` file in the repo; nothing declares a background mode today.

### 3.1a Falsification run — executed, not reasoned

Two probes, both built against the **same prebuilt modules the app links**
(`Build/Products/Debug/{Hub,HuggingFace,…}.o`, i.e. swift-transformers 1.2.1 +
swift-huggingface 0.9.0 at the pinned revisions), run on macOS 26 / M1 Air.
Sources kept in the session scratchpad, not added to the repo.

**Probe 1 — the mechanism.** Raw `URLSession.download(for:)`, no HF code involved.

```
[CONTROL default]        OK status=200 bytes=2939
[BACKGROUND download(for:)]
*** Terminating app due to uncaught exception 'NSGenericException',
    reason: 'Completion handler blocks are not supported in background sessions.
             Use a delegate instead.'
exit=134 (SIGABRT)
```

The control proves the URL, the network and the CDN redirect chain are fine.

**Probe 2 — the full stack**, through `HubApi` exactly as `MLXLMCommon.downloadModel`
calls it (`HubApi(downloadBase:cache:useBackgroundSession:useOfflineMode:)` →
`snapshot(from:revision:matching:)`), glob restricted to `config.json` so the 473 MB
weight file was never fetched.

| Run | `useBackgroundSession` | Result |
|---|---|---|
| control | `false` | **OK** — `config.json bytes=2939`, exit 0 |
| the question | `true` | **`NSGenericException` → SIGABRT (exit 134)**, zero bytes on disk |

The abort stack is the complete predicted chain, frame for frame:

```
22  Hub.HubApi.snapshot(from:revision:matching:progressHandler:)
21  Hub.HubApi.HubFileDownloader.download(progressHandler:)
16  HuggingFace.HubClient.downloadFile(at:from:to:kind:revision:endpoint:…)
15  Foundation  NSURLSession.download(for:delegate:)
 8  CFNetwork   -[__NSURLBackgroundSession _downloadTaskWithTaskForClass:]
 2  CFNetwork   -[__NSURLBackgroundSession _onqueue_dummyTaskForClass:withRequest:error:]
 1  libobjc     objc_exception_throw
```

Facts established by the run:

1. **`HubApi(useBackgroundSession: true)` is not usable as shipped.** It does not degrade,
   fall back, or throw a Swift error — it terminates the process. `NSException` is not
   catchable from Swift, so no `do/catch` at any call site can contain it.
2. **The foreground path works end-to-end**, including auth-free public-repo access, the
   HEAD preflight, the CDN redirect, and the `.cache/huggingface/download/*.metadata`
   sidecar. Both artifacts were confirmed on disk.
3. **The materialized layout is confirmed empirically**, not just from source:
   `downloadBase/models/prism-ml/Ternary-Bonsai-1.7B-mlx-2bit/config.json` — i.e.
   `models/<org>/<name>/`, **two levels below** `downloadBase` and therefore invisible to
   `ModelManager.scan()` (§1.5). This makes decision 4 concrete rather than predicted.

**Harness note, recorded so the result is reproducible and not over-read.** The first
version of probe 2 ran its work as async top-level code and died in
`_dispatch_assert_queue_fail` *before reaching any download* — the networking stack
requires a live main queue and async top-level code leaves none. That crash was an
artifact of the probe, not a property of `HubApi`, and the probe was restructured
(`Task.detached` + `dispatchMain()`) until the control passed. Only then was the
background run trusted. The `useBackgroundSession: true` abort reproduces with the
control passing in the same binary.

**Additional finding from building the probe (not sought, worth recording).**
`HubApi.snapshot`'s `progressHandler` is typed `@escaping (Progress) -> Void` —
**not `@Sendable`** (`STF/…/HubApi.swift:892`), and `Progress` is not `Sendable`.
Under `SWIFT_STRICT_CONCURRENCY: complete` (`project.yml:29`), passing a progress
closure to `snapshot` from `@MainActor` code is a **compile error**:

```
error: sending value of non-Sendable type '(Progress) -> ()' risks causing data races
```

Every ViewModel and Service in this codebase is `@MainActor` (ARCHITECTURE, Concurrency).
So download progress cannot be wired straight from a `@MainActor` type to `HubApi.snapshot`
without an isolation hop. Recorded as a constraint; the resolution is a design decision.

### 3.2 Querying free disk space — iOS vs macOS

Verified against the iPhoneOS 26.5 SDK,
`Foundation.framework/Headers/NSURL.h`:

| Key | Availability (from the header) | Line |
|---|---|---|
| `NSURLVolumeAvailableCapacityKey` | `macos(10.6), ios(4.0), watchos(2.0), tvos(9.0)` | :316 |
| `NSURLVolumeAvailableCapacityForImportantUsageKey` | `macos(10.13), ios(11.0)`, `API_UNAVAILABLE(watchos, tvos)` | :361 |
| `NSURLVolumeAvailableCapacityForOpportunisticUsageKey` | present, same region of the header | :363–… |

**The API is the same on both platforms.** `…ForImportantUsage` is *not* iOS-only — it is
`macos(10.13)+` and both deployment targets (iOS 26 / macOS 26, DECISIONS #1) clear it easily.

The distinction the header draws is semantic, not platform:
- `VolumeAvailableCapacity` — raw free bytes.
- `…ForImportantUsage` — free bytes **including space the system expects to reclaim** by
  purging caches. Larger than raw free space. Typed `NSNumber`; surfaces in Swift as
  `URLResourceValues.volumeAvailableCapacityForImportantUsage: Int64?`.

The queried URL determines the volume, so it must be a URL on the target volume (i.e. inside
the container), not an arbitrary path. No such query exists anywhere in `Sources/` today —
`Sources/Utilities/ByteFormat.swift` is a 7-line `ByteCountFormatter` wrapper and is the only
byte-related utility in the codebase.

### 3.3 Where downloads land in the app container

Three distinct locations are in play, and none of them is the model store:

| Producer | iOS path | Source |
|---|---|---|
| `ModelManager` (discovery target) | `<container>/Library/Application Support/GZ-BT/Models` | `ModelManager.swift:23–27` |
| `HubApi.downloadBase` (default) | `<container>/Documents/huggingface` | `HubApi.swift:160–165` |
| `HubCache` (default, non-macOS branch) | `<container>/Library/Caches/huggingface/hub` | `SHF/…/Shared/CacheLocationProvider.swift:196–219` |

`CacheLocationProvider.defaultCacheDirectory` (:196–219) branches on `#if os(macOS)`: on macOS
it uses `~/.cache/huggingface/hub` unless `APP_SANDBOX_CONTAINER_ID` is set; **the `#else`
branch — which iOS takes — always returns `URL.cachesDirectory/huggingface/hub`.**

Consequences, recorded as constraints:

- **`Library/Caches` is purgeable.** iOS may evict it under disk pressure, including between
  launches. A model living only there can vanish.
- **`Documents/` and `Library/Application Support/` are backed up** to iCloud/iTunes by
  default. A 473 MB model in either is a 473 MB backup unless the directory carries
  `URLResourceValues.isExcludedFromBackup`. Nothing in `Sources/` sets that flag today
  (no matches for `isExcludedFromBackup` in the repo).
- **`Documents/` is user-visible** if `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`
  are ever set. Neither is set today.
- **Cache-then-copy doubles peak disk.** `HubClient` stores into the cache blob and then
  copies to the destination (`copyFileToDestinationIfNeeded`, `HubClient+Files.swift:1606–1633`,
  `copyItem` at :1631; snapshot equivalent at :1636–1674 which resolves symlinks and copies,
  :1670–1671). For a 473 MB model that is ~946 MB transient, plus the `.incomplete` blob
  during transfer.

---

## 4. Remote provider seam — adversarial reading of `InferenceEngine`

The claim under test: Seam-1 and `InferenceEngine` are engine-neutral, so an HTTP-based
provider is a binding, not an amendment. Below is what the contract as written
(`Sources/Inference/InferenceEngine.swift`, 97 lines) actually demands.

### 4.1 The contract

```swift
protocol InferenceEngine: Actor {                                              // :8
    nonisolated var telemetry: AsyncStream<TelemetryEvent> { get }             // :10
    func load(_ model: ResolvedModel, progress: (@Sendable (Double) -> Void)?) async throws  // :13
    func unload() async                                                        // :16
    func generate(_ request: GenerationRequest) -> AsyncStream<GenerationEvent> // :20
    func cancel() async                                                        // :23
}
```

### 4.2 What a remote HTTP engine satisfies cleanly

- `: Actor` (:8) — an HTTP client actor is natural; no conflict.
- `GenerationRequest` (:42–50) / `ChatTurn` (:53–62) — `role` + `text` maps directly onto
  OpenAI/Anthropic message arrays. No engine type present. **Clean.**
- `GenerationEvent` (:66–70) — `.token(String)` / `.completed` / `.failed(String)` maps onto
  SSE deltas. **Clean.**
- `cancel()` (:23) — maps to task cancellation / connection teardown. **Clean.**
- `.lifecycle`, `.firstToken(ttft:)`, `.throughput(tokensPerSecond:)` — all measurable
  client-side by a remote engine without any server cooperation. **Clean.**

### 4.3 MLX-shaped elements a remote provider could not produce honestly

**(a) `load(_ model: ResolvedModel, …)` presumes a local directory.**
`ResolvedModel.url: URL` is non-optional (`ResolvedModel.swift:10`) and is populated only from
`DiscoveredModel.url`, which is only ever a scanned local directory
(`ModelManager.swift:98–104`). `MLXInferenceEngine` consumes it as
`ModelConfiguration(directory: model.url)` (`MLXInferenceEngine.swift:36`). A remote provider
has a model *name* and an *endpoint*; it must be handed a `URL` it does not want and has no
field for the endpoint, the provider, or the API key. **The load path is the seam's
MLX-shaped element.**

**(b) `progress: (@Sendable (Double) -> Void)?` (:13) is a weight-loading concept.**
Nothing remote has a 0…1 load fraction. Passing `nil` is legal (`ChatViewModel.swift:274`
already does), so this is vestigial rather than blocking.

**(c) `unload()` (:16) — "release the model and free memory" has no remote analogue.**
Satisfiable as a no-op; the contract does not require observable behaviour.

**(d) `TelemetryEvent.context(used:capacity:)` (:95) requires a capacity a remote may not report.**
`capacity` is `Int`, **not** `Int?`. Today it comes from `config.json`'s
`max_position_embeddings`, read by `ModelManager` (`ModelManager.swift:93–94`), carried on
`ResolvedModel.contextLength`, and gated on non-nil before emission
(`MLXInferenceEngine.swift:108–110`). A remote provider that does not publish a context window
must either hardcode a number or **never emit `.context` at all** — at which point
`SpectreViewModel.context` renders `"—"` (`SpectreViewModel.swift:46–49`) and
`contextFraction` returns `nil` (:52–57). Not a crash; a permanently blank readout.

**(e) `GenerationSummary` (:72–80) has seven non-optional fields.** This is the sharpest edge.

| Field | Remote provider reality |
|---|---|
| `promptTokens: Int` | Usually available (usage block) — but **only in the final SSE chunk, or not at all** on some providers |
| `generatedTokens: Int` | Same |
| `tokensPerSecond: Double` | **Not reported by any provider.** Must be derived client-side; conflates network latency with generation speed |
| `promptTokensPerSecond: Double` | **Not reported and not meaningfully derivable** — the client cannot see prompt-processing time separately from queueing and network |
| `timeToFirstToken: Duration` | Measurable client-side, but includes network RTT and server queueing — not comparable to the local metric of the same name |
| `totalTime: Duration` | Measurable client-side |
| `stopReason: String` | Available (`finish_reason` / `stop_reason`) |

None are `Optional`. A remote binding must supply a value for every one, so
`promptTokensPerSecond` and `tokensPerSecond` would be **fabricated or zero** — and
`0.0` is indistinguishable at every consumer from a real measurement, because
`TelemetryHub.appendSample` only rejects non-finite and non-positive values
(`TelemetryHub.swift:149`) while `TelemetryHub.tokensPerSecond` is assigned unconditionally
from the summary (:135). CLAUDE.md Gotcha #5 (no fake green) applies directly: the contract
as written has no way to say "this engine does not measure this."

**(f) `MessageTelemetry` already anticipates remote, and its fields *are* optional.**
`Sources/Models/MessageTelemetry.swift` documents `engine` as
`` `mlx` | `llamacpp` | `remote:<provider>` `` (:22–24), and `ttftMs`, `tokensPerSecond`,
`promptTokens`, `tokensOut`, `finishReason` are **all `Optional`** (:29–38), with a
`schemaVersion` + `extra` JSON envelope (:40–42). `engineID` is already injected from the
composition root as a `String` (`AppEnvironment.swift:23`, `ChatViewModel.swift:31, 46`)
rather than being a protocol property — deliberately, per §7 of BUILD_SESSION_2.

**The persistence layer is more remote-ready than the seam is.** The storage envelope
tolerates absent metrics; `GenerationSummary` does not. The nullability mismatch is between
`Inference/` and `Models/MessageTelemetry`, and it is the concrete thing S3.5 will collide with.

**(g) Nothing in the contract carries a secret, an endpoint, or a provider identity.**
There is no field on `InferenceEngine`, `ResolvedModel`, `GenerationRequest`, or
`GenerationConfig` for a base URL, an API key, an organisation, or a model slug.
`GenerationConfig` (`Sources/Models/GenerationConfig.swift`) is three fields — `maxTokens`,
`temperature`, `topP` — with no `stop`, no `seed`, no penalties, no streaming flag.
FEATURE_SCOPE's Remote API fold-down names four protocols and multiple named endpoints per
key; none of that has a seat in the current types.

### 4.4 Verdict on the neutrality claim, stated factually

Seam-1 (`telemetry: AsyncStream<TelemetryEvent>`) is genuinely engine-neutral: all five cases
are producible by a remote engine, three of them exactly, one (`.context`) omittable, and one
(`.completed`) only by fabricating two fields.

`InferenceEngine` as a whole is **not** engine-neutral in its `load` path: it requires a local
directory `URL` and offers no seat for an endpoint or credential. That is a property of
`load(_:progress:)` and `ResolvedModel`, not of Seam-1 — which is consistent with DECISIONS #28's
claim (Seam-1 survived falsification) being about the *telemetry* contract specifically, and not
a claim about `load`.

---

## 5. Keychain

**No Keychain code exists in GZ-BT.** Verified:
`grep -rn "Keychain\|kSecClass\|SecItem\|import Security" Sources/ Tests/` → no matches.

No token storage of any kind exists. `AppSettings` (§1.4) holds one `Bool` in `UserDefaults`.

**A Keychain implementation does exist in the dependency graph**, in swift-huggingface:
`SHF/Sources/HuggingFace/OAuth/HuggingFaceAuthenticationManager.swift` uses
`kSecClassGenericPassword` at :375, `SecItemAdd` at :385, with further queries at :392 and :417.
It is reachable via `TokenProvider.oauth(manager:)`
(`SHF/…/Shared/TokenProvider.swift:235–241`, gated `@available(macOS 14.0, iOS 17.0, …)` and
`#if canImport(AuthenticationServices)`), and is parameterised by `keychainService` and
`keychainAccount` (documented at `TokenProvider.swift:40–46`). It requires a registered OAuth
**client ID** and a **redirect URL** — it is an OAuth flow, not a place to put a
user-pasted `hf_...` token.

**Do an HF token and S3.5's API keys have the same shape?** As a storage problem, the facts:

- Both are bearer secrets, per-provider, user-supplied, needing store/retrieve/delete.
- `TokenProvider.custom(@Sendable () async throws -> String?)`
  (`TokenProvider.swift:156`) accepts an arbitrary async closure, so **any** storage the app
  owns can feed swift-huggingface without the app adopting `FileTokenStorage` or the OAuth
  manager. This is the existing injection point, stated as a fact about the API surface.
- The differences are in the surrounding metadata, not the secret: HF needs one token plus a
  hub endpoint (`HF_ENDPOINT`, `HubClient.swift:189–196`); FEATURE_SCOPE's Remote API section
  ratifies *"Multiple Named Endpoints per API key"* and ~30 providers across 4 protocols, i.e.
  a keyed collection with per-entry endpoint, protocol, and display name.

Whether one implementation covers both is a scope question, not a fact, and is listed as
decision 8 below.

---

## 6. The performance-number discrepancy

**No document is being corrected here.** What follows is only what each number measures.

### 6.1 What ARCHITECTURE.md records

`ARCHITECTURE.md:136–145`:

| Platform | Device | TTFT | tok/s | Model |
|---|---|---|---|---|
| macOS | M1 Air | ~0.23 s | ~68 | Ternary-Bonsai-1.7B-mlx-2bit |
| iOS | iPhone 15 Pro Max (A17 Pro), iOS 26.5 | 225 ms | 76.3 | same |

The macOS row traces to DECISIONS #4 (`DECISIONS.md:13–16`, Session 1, 2026-07-24):
*"Verified: loads and streams at ~68 tok/s, TTFT ~0.23 s."* Session 1 predates persistence
(added in Session 2), so that figure **cannot have come from `message_telemetry`** — the table
did not exist. It came from the Chat metrics bar or a log line, and no prompt length,
generated-token count, or warm/cold state was recorded with it.

The iOS row is different in kind and is documented as such (`ARCHITECTURE.md:142–144`,
DECISIONS.md:65–67): read out of `message_telemetry` in a store pulled off the device with
`devicectl device copy from`. It has provenance; the macOS row does not.

### 6.2 What the Spectre readouts mean

Both Spectre tiles are **last-value-wins, single-turn, whole-process-lifetime** state — not
averages, not benchmark runs, not persisted.

- `SpectreViewModel.ttft` (`SpectreViewModel.swift:39`) formats `TelemetryHub.ttft`, which is
  overwritten on **every** `.firstToken` (`TelemetryHub.swift:120–122`) and again on every
  `.completed` from `summary.timeToFirstToken` (`TelemetryHub.swift:136`).
- `SpectreViewModel.tokensPerSecond` (:40) formats `TelemetryHub.tokensPerSecond`, overwritten
  on every `.throughput` (`TelemetryHub.swift:124–127`) and every `.completed` (:135).
- `SpectreViewModel.peakThroughput` (:60–62) is `throughputSamples.max()` over a rolling
  60-sample window (`TelemetryHub.swift:41–42, 148–154`) — **`max` over the process lifetime**,
  reset only by relaunch.

**What TTFT actually measures.** In `MLXInferenceEngine.generate`, the clock starts at
`MLXInferenceEngine.swift:94`:

```swift
let input = try await context.processor.prepare(input: UserInput(chat: chat))   // :90
let gen: AsyncStream<Generation> = try MLXLMCommon.generate(...)                 // :91-92
let start = ContinuousClock.now                                                  // :94  ← clock starts HERE
```

So TTFT **excludes** model load, chat-template rendering, and tokenization; it measures
stream-creation → first chunk. It is not wall-clock time from tapping send.

**What tok/s actually measures.** `info.tokensPerSecond` from MLX
(`MLXInferenceEngine.swift:114, 120`) — generation only. It is strongly sensitive to
generated-token count, because fixed per-turn costs amortise over however many tokens were
produced.

### 6.3 Hard evidence from the store on this machine

This Mac, verified in-session: **MacBook Air, `MacBookAir10,1`, Apple M1, 8 GB** — the same
class of machine as ARCHITECTURE's "M1 Air" row. The Spectre reading and the Session-1 reading
are therefore **not separated by hardware.**

Every persisted telemetry row (queried from a copy of
`~/Library/Application Support/GZ-BT/gzbt.sqlite`; the live store was not opened):

```
model_id                      engine  ttft_ms  tps   pt  out  finish_reason  context_used  capacity
Ternary-Bonsai-1.7B-mlx-2bit  mlx     96.6     49.7  34    7  stop           41            32768
Ternary-Bonsai-1.7B-mlx-2bit  mlx     102.3    56.1  58  284  stop           342           32768
```

Facts, without inference beyond what the rows support:

1. **The reported 96 ms matches `ttft_ms = 96.6` exactly.** It is a real measurement on this
   M1 Air, from a turn with a **34-token prompt and 7 generated tokens**.
2. **82.2 tok/s appears in no persisted row.** The two persisted rows are 49.7 and 56.1.
   If the Spectre tile read was the *peak* tile, it is `max()` over samples from the whole
   process lifetime, which includes turns not persisted here — for example any run launched
   with `GZBT_STORE_PATH` pointed at a throwaway store (§1.3). The store's `-wal` is dated
   Jul 27; the `-shm` Jul 30, the S2.5 session date. This is not established, only bounded:
   **the number is not in this database.**
3. **Both persisted rows are below ARCHITECTURE's ~68 tok/s**, and both TTFTs are ~2.3×
   *faster* than its ~0.23 s — on the same machine and the same model.
4. **Turn-to-turn variance is large within the store itself:** 96.6 → 102.3 ms TTFT (+6%) and
   49.7 → 56.1 tok/s (+13%), between two turns whose generated-token counts differ 40× (7 vs 284).

The two figures are **the same measurement taken under different, unrecorded conditions** —
different turn shapes, different warm/cold state, one read pre-persistence from a transient
UI readout and one read from a live single-turn dashboard tile. Neither is a benchmark, and
nothing in the codebase currently produces a repeatable one: there is no fixed prompt, no
warmup, no repetition, and no aggregation anywhere in `Sources/`.

---

## Decisions required before S3 can be specced

Questions only. Each is a fork the recon surfaced and cannot settle by evidence.

1. **Which HF layer does GZ-BT call — `HubApi` (swift-transformers) or `HubClient`
   (swift-huggingface)?** `HubApi` is what the ratified MLX substrate already uses, and it is
   the layer with live SHA256 verification and a background-session flag; `HubClient` is the
   lower, more direct surface with no integrity check. (§2.0, §2.1, §2.3)

2. **Does taking a direct dependency on either module require a `project.yml` entry, or is
   transitive visibility acceptable?** Both modules build and import today without being
   declared (§2.0) — but DECISIONS #8 says "no third-party packages beyond the MLX substrate
   + its transitive deps," which reads either way. Is relying on an undeclared transitive
   module a substrate decision?

3. **Is background downloading in scope for S3 at all?** ~~The SDK conflict at §3.1 is
   documented but unexecuted.~~ **The factual half is now settled (§3.1a): `useBackgroundSession:
   true` aborts the process; foreground works.** What remains is direction only — does S3 ship
   foreground-only (a 473 MB download that dies when the app is backgrounded on iOS), or does
   background transfer become its own scoped piece of work? Note this is not a
   "wait for an upstream fix" option: the conflict is between two pinned versions we control.

4. **Where do downloaded models land, and who moves them?** `HubApi` materialises to
   `downloadBase/<type>/<org>/<name>/` — **confirmed on disk in §3.1a**, two levels deeper than
   `ModelManager` can see, under `Documents/` by default. Discovery requires a flat immediate
   child of `Library/Application Support/GZ-BT/Models` (§1.5). This is a fork: point
   `downloadBase` at the store, move after download, or change discovery.

5. **What is a downloaded model's directory name?** It becomes `DiscoveredModel.id`, the
   persisted `activeModelID`, and `message_telemetry.model_id` — and a repo id contains a `/`.
   Is the identity the last path component, a flattened slug, or something new? (§1.1, §1.5)

6. **Does S3 accept the cache-then-copy disk cost (~946 MB peak for a 473 MB model), or is
   `cache: nil` required?** Note the §2.2(7) behaviour and that `cache: nil` disables resume
   entirely (§2.2(6)).

7. **Does discovery need a completeness or integrity signal?** Today a partially-downloaded
   directory is indistinguishable from a complete one and is offered as loadable (§1.5).
   Is that acceptable for S3, or does the model store gain state?

8. **One credential store or two?** An HF token and S3.5's per-provider API keys are both
   bearer secrets, but the remote matrix in FEATURE_SCOPE needs per-entry endpoint, protocol
   and name. Is S3's token storage built as the general credential store, or as a single-value
   store that S3.5 replaces? (§5)

9. **Where do credentials live — Keychain, or `AppSettings`/`UserDefaults`?** No Keychain code
   exists (§5). `AppSettings` is a one-`Bool` `UserDefaults` wrapper with no abstraction to
   extend. This is an architectural decision about the Services layer, not an implementation
   detail.

10. **Does `GenerationSummary` become partially optional before S3.5, or does a remote binding
    fabricate `tokensPerSecond` / `promptTokensPerSecond`?** All seven fields are non-optional
    (§4.3e); `MessageTelemetry`'s equivalents are all `Optional`. Changing `GenerationSummary`
    is a Seam-1 amendment and is TyPod's call; not changing it puts a remote binding in direct
    conflict with Gotcha #5.

11. **Does `load(_ model: ResolvedModel, …)` stay local-URL-shaped?** It is the one genuinely
    MLX-shaped element in the contract (§4.3a). A remote provider needs an endpoint and a
    credential seat that neither `ResolvedModel` nor `GenerationRequest` has. Deciding this in
    S3 (while the store model is already being touched) versus S3.5 is a sequencing call.

12. **Does S3 own a repeatable benchmark, or does Spectre stay a live single-turn dashboard?**
    Nothing in `Sources/` currently produces a comparable number — no fixed prompt, no warmup,
    no repetition, no aggregation (§6.3). "Spectre internals (benchmarks, history)" is listed
    as unscoped in CLAUDE.md's open threads, and §6's discrepancy is a direct consequence.

13. **Do the two macOS figures get reconciled, and by whom?** ARCHITECTURE.md:139 records
    ~0.23 s / ~68 tok/s; the store on the same machine holds 96.6/102.3 ms and 49.7/56.1 tok/s.
    Recon deliberately did not touch the docs. Amending them is a canon change (Gotcha #9).

14. **How does download progress cross the main-actor boundary?** `HubApi.snapshot`'s
    `progressHandler` is not `@Sendable` and `Progress` is not `Sendable`, so wiring it
    directly into a `@MainActor` ViewModel/Service does not compile under
    `SWIFT_STRICT_CONCURRENCY: complete` (§3.1a). Whatever S3 builds needs an isolation
    decision here, and it touches the Services layer.

---

## Session report

**What changed (file list)**
- `S3_RECON.md` — added (this file). Nothing else. `git status` was clean at start; no source,
  config, or doc file was modified.

**What was verified (commands actually run, real output)**
- `git -C … log -1 --oneline` → `d5be989`; `git tag --list` → the three phoenix tags.
- `cd SHF && git log -1 --format='%H %d'` → `b721959445b617d0bf03910b2b4aced345fd93bf (HEAD, tag: 0.9.0)`
  — matches `Package.resolved`. Package source read, not recalled (Gotcha #3).
- `grep -rn "computeFileHash" SHF/Sources/` → **one** hit, the definition at
  `HubClient+Files.swift:2009`. No callers. (Basis for §2.2(1).)
- `grep -rni "background" SHF/Sources/` → **zero** matches. (Basis for §2.2(2).)
- `grep -rn "Keychain\|kSecClass\|SecItem\|import Security" Sources/ Tests/` → **no matches**.
  (Basis for §5.)
- `sed -n '240,260p' "$(xcrun --sdk iphoneos --show-sdk-path)/…/NSURLSession.h"` → the
  `NSURLSessionAsynchronousConvenience` comment quoted verbatim in §3.1.
- **`./bgprobe`** → control `OK status=200 bytes=2939`; background → `NSGenericException`,
  exit 134. **`./hubprobe foreground`** → `config.json bytes=2939`, exit 0;
  **`./hubprobe background`** → `NSGenericException`, exit 134, nothing on disk.
  Full output and abort stack in §3.1a.
- `grep -n … NSURL.h` → availability lines 316 and 361 quoted verbatim in §3.2.
- `find …/Build/Products -iname "*HuggingFace*"` → `HuggingFace.swiftmodule` + `.o` present in
  `Debug`, `Debug-iphoneos`, `Debug-iphonesimulator`; `Hub`, `Tokenizers`, `MLXLMCommon`
  likewise. (Basis for §2.0.)
- `system_profiler SPHardwareDataType` → `MacBookAir10,1`, Apple M1, 8 GB. (Basis for §6.3.)
- `du -sh` on the model dir → `473M`; `ls -la` output reproduced in §1.5; `config.json` parsed
  for `model_type` / `quantization` / `max_position_embeddings`.
- `sqlite3` against a **copy** of `gzbt.sqlite` in the scratchpad (the live store was never
  opened) → the two `message_telemetry` rows reproduced verbatim in §6.3.

**What's red**
- **`HubApi(useBackgroundSession: true)` is red — hard red.** It aborts the process with an
  uncatchable `NSGenericException` (SIGABRT, exit 134) before any byte is written.
  Reproduced twice, at the raw-`URLSession` level and through the full
  `HubApi → HubClient → URLSession` stack, with a passing foreground control in the same
  binary (§3.1a). This is an honest red result, not a blocker discovered late: nothing in
  the repo calls it today.
- The GZ-BT app itself was **not** built or tested in this session — no green is claimed for it.
  The last recorded state stands: S2.5 merged and tagged.

**Open questions**
- The 14 decisions above. **#3's factual half is now closed** by the run in §3.1a; what is
  left of it is direction, which is TyPod's. **#14 is new**, surfaced by compiling against
  the real modules rather than by reading them.
- `QUESTIONS.md` was **not** modified; these are decisions for a spec, not ambiguities
  blocking work in progress.

**Probe provenance (reproducibility)**
- `bgprobe.swift` (mechanism) and `hubprobe.swift` (full stack) live in the session
  scratchpad, **not** in the repo — no new source, no new target, no `project.yml` change,
  consistent with Gotcha #2 (nothing gained a CLI entrypoint) and #7.
- Both were linked against `Build/Products/Debug/*.o`, i.e. the **same** compiled
  swift-transformers 1.2.1 / swift-huggingface 0.9.0 the app links — not a fresh
  resolution, so the result applies to the pinned graph.
- Network access was limited to `config.json` (2,939 bytes) from
  `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit`. The 473 MB weight file was never fetched.
  Downloads went to `NSTemporaryDirectory()`, never to the real model store.

**Adjacent problems noticed, not fixed** (per Gotcha #7)
- `ModelManager.isScanning` (`ModelManager.swift:15, 44–45`) can never be observed as `true`
  from the UI — `scan()` is synchronous on the main actor.
- `HubApi` prepares `incompleteDestination` and never uses it (`STF/…/HubApi.swift:823–827`
  vs `:849–856`) — upstream, not ours.
- `HubClient.downloadSnapshot(to:)` with `cache: nil` downloads everything then throws
  (`SHF/…/HubClient+Files.swift:1227` vs `:1379`) — upstream, read from control flow, not
  reproduced at runtime.
