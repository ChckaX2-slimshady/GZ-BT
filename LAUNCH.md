# LAUNCH.md — Running GZ-BT yourself

Plain steps to open and run GZ-BT Phoenix. Nothing here has to be memorized — follow top to bottom.

## What GZ-BT is right now
A native SwiftUI app for macOS + iOS with a 12-destination shell. **Chat, Models, and Settings are
real**; the rest are polished placeholders. Chat runs a local MLX model on-device and streams the reply.

## One-time prerequisites (macOS)
1. **Xcode 26.6** (already installed here).
2. **XcodeGen** — the Xcode project is generated, not checked in. If missing: `brew install xcodegen`.
3. **Metal Toolchain** — needed to compile MLX's GPU kernels. If a build complains about a missing
   `metal` tool: `xcodebuild -downloadComponent MetalToolchain` (~700 MB, one time; already done here).

## The model must be in place
Chat needs the Bonsai MLX model on disk at exactly:
```
~/Library/Application Support/GZ-BT/Models/Ternary-Bonsai-1.7B-mlx-2bit/
```
That folder must contain `config.json`, `model.safetensors`, and `tokenizer.json` (already seeded here).
Check with:
```
ls "~/Library/Application Support/GZ-BT/Models/Ternary-Bonsai-1.7B-mlx-2bit"
```
To use a different MLX model, drop its folder alongside that one and pick it in the **Models** tab.

## Run it on your Mac (Xcode)
1. In Terminal: `cd ~/GZ-BT && xcodegen generate`
2. Open the project: `open GZ-BT.xcodeproj`
3. Top toolbar: scheme **GZ-BT**, destination **My Mac**.
4. Press **Run** (▶ / Cmd-R).
5. You should see: a sidebar (Chat, Models, HATS … Settings), **Chat** selected. The top strip reads
   **"Ternary-Bonsai-1.7B-mlx-2bit"** with a green dot once the model loads (a second or two).
6. Type a message, press the turquoise ↑ button. The reply **streams in**, and TTFT / tok/s / tokens
   update live in the strip. (Verified: ~64 tok/s, ~90 ms to first token on this Mac.)

### Or run without Xcode (command line)
```
xcodegen generate
xcodebuild -scheme GZ-BT -destination 'platform=macOS' -skipPackagePluginValidation build
open ~/Library/Developer/Xcode/DerivedData/GZ-BT-*/Build/Products/Debug/GZ-BT.app
```

## Other tabs
- **Models** — shows discovered MLX models (arch, quant, size); tap to set the active one.
- **Settings** — one real switch: **Enable Spectre** (default OFF). Turn it on and a **Spectre**
  destination appears in the sidebar.

## iOS Simulator (expect this)
The app **builds and launches** in the iPhone simulator and the UI + model discovery work, but
**inference will not run there** — MLX needs a real GPU the simulator doesn't have. Chat shows a
clear "needs a real device" error instead of crashing. This is expected.

## Putting it on your actual iPhone (not done yet — what it takes)
Not attempted this session. To do it later:
1. **Signing:** open the project, select the **GZ-BT** target → **Signing & Capabilities** → check
   *Automatically manage signing* and pick your **Team** (a free personal Apple ID works for dev).
   (Equivalently, set `DEVELOPMENT_TEAM` in `project.yml` and regenerate.)
2. **Device platform:** Xcode → **Settings → Components** — install the iOS version your iPhone runs
   (your phone reported iOS 26.5, which isn't installed here yet).
3. **Device setup:** on the iPhone, enable **Developer Mode** (Settings → Privacy & Security), plug in,
   and **Trust** this Mac. After the first install, approve the developer profile under
   Settings → General → VPN & Device Management.
4. **Model on device:** the Bonsai folder must live in the app's sandbox. For now that's a manual dev
   step; an in-app model import/download is a later feature (out of Session-1 scope).
5. Select your iPhone as the destination and Run. On a real device, inference runs for real.
