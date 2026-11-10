---
status: in-progress
adr: none
remaining: [system-trash, gpu-default, signing, desktop-check]
---

## Progress (2026-11-07)

First tag run (`v1.2.3-beta.4`, run 42409161560) passed every job and published the
pre-release with `MyDataStudio-v1.2.3-beta.4-windows-x64-setup.exe` (410 MB) and the portable
zip (416 MB) next to the macOS and Linux assets. Windows job: 24 min (aiserver ~16 min). The
smoke test passed on the silently installed copy. Left: a real Windows 11 desktop, signing,
and the GPU default.

- [x] **windows-runner-scaffold:** `client/windows/` generated with Flutter 3.47.0. Window
  title "My Data Studio", icon from `linux/packaging/app_icon.png`. `Runner.rc` has **no
  CompanyName** and **ProductName = realm** (`APP_REALM` from `REALM_NAME`, as on Linux), so
  `path_provider` puts the support directory at `%APPDATA%\<realm>`. The JNI find is
  disabled, as on Linux.
- [x] **plugin-audit:** `open_filex` 4.7 opens files on Windows in Dart (`cmd /c start`);
  `fluttertoast` has no desktop plugin (same as Linux); `flutter_angle` has a Windows plugin.
  The rest are as listed below. Every plugin built on the runner.
- [x] **webview-flutter-windows-spike:** `webview_flutter_windows` (1.3.1) is a standalone
  WebView2 package with **its own API**. It doesn't implement `webview_flutter`'s platform
  interface, so the plan's premise ("EmailDetails barely changes") doesn't hold. Took the
  fallback below.
- [x] **email-body-view:** Windows uses `HtmlEmailBodyView` like Linux;
  `EmailBodyView.forPlatform` now gives the WebView to macOS only. "Open in browser" writes
  to `%TEMP%` (already private to the user) and opens it with `url_launcher`. Tested.
- [x] **pdfrx-migration:** landed with Linux; the CI job enables Developer Mode.
- [ ] **system-trash:** `windows/runner/system_trash_channel.cpp` compiles in CI; not tried on real Windows
  ([windows-recycle-bin.md](windows-recycle-bin.md)).
- [x] **aiserver-windows:** CPU build; the GPU default (Vulkan or CUDA) is tracked as **gpu-default**. Makefile has
  `Windows_NT` branches; PyPI torch is CPU-only on Windows, so the lock installs as is, and
  only `llama-cpp-python` compiles (MSVC). `libpff-python` has a Windows wheel, so PST import
  stays on. `build_python.yml` re-enabled. **Shutdown:** new authenticated `POST /shutdown`
  (sets uvicorn's `should_exit`); on Windows `stopAiServerService` calls it before falling
  back to the kill. Tested locally (pytest and a live server).
- [x] **ci-job:** `build-windows` in `build_and_release.yml` bundles the VC++ runtime, builds
  the installer, installs it silently, and runs `windows_smoke_test.ps1` against the
  installed copy (aiserver auth, `/shutdown`, the app starts and creates `%APPDATA%\<realm>`).
- [x] **installer:** **Inno Setup** (decided 2026-11-07): an unsigned MSIX won't install at
  all, an unsigned `.exe` installs after a SmartScreen warning. Per-user install, no admin.
  The portable zip was dropped on 2026-11-08: the installer is the only download.
- [ ] **gpu-default:** **Vulkan** (decided 2026-11-08), one build for every GPU vendor and
  the CPU. CI installs LunarG's SDK 1.4.363.1 (`install_vulkan_sdk.sh`) and builds
  llama.cpp with `-DGGML_VULKAN=on`; `main.spec` bundles `vulkan-1.dll` next to ggml-vulkan so
  a PC with no GPU driver still loads it and falls back to the CPU. Chat loads with
  `n_gpu_layers=-1` and retries on the CPU if that fails. Embeddings stay on CPU torch
  (PyPI torch has no GPU build for Windows). The smoke test now loads a 1 MB GGUF on the
  GPU-less runner. Open until a tag run passes; not tried on a real GPU.
- [ ] **signing:** not started; needs a decision and secrets from the owner.
- [ ] **desktop-check:** the "Done when" checks on Windows 11.
- Sync folders: `SyncFolderDetector` falls back to `USERPROFILE` (Windows has no `HOME`), so
  `%USERPROFILE%\Dropbox` and friends are found. Cloud Files placeholder detection is still
  macOS-only (`OnlineOnlyChecker` is off elsewhere).
---

# Plan: Build the Windows desktop app in GitHub Actions

**Today:** CI builds **macOS only**. `build_and_release.yml` has one `macos-latest` job;
`build_python.yml` has the Windows and Linux matrix entries **commented out**. There's **no
`client/windows/` folder**, so the Flutter Windows runner has never been generated.
`python_manager.dart` already expects `aiserver-windows.zip`.

## Work

1. **Scaffold the runner:** `flutter create --platforms=windows .` in `client/`; commit
   `client/windows/`. Set the app name, icon and version resource (`Runner.rc`) from the realm,
   as `REALM_NAME` does on macOS.
2. **Plugin audit:** every dependency must have a Windows implementation, or be guarded.
   - **Email HTML (decided 2026-10-26).** `webview_flutter` (used in `email_details.dart`,
     `email_page.dart`, `search_email_sidebar.dart`) has **no Windows support**. Put an
     **`EmailBodyView`** interface in front of the body renderer, with one implementation per
     platform. The existing sanitising, CSP and `cid:` → data-URI inlining stay shared, in front
     of every implementation:

     | Platform | Renderer |
     |---|---|
     | macOS | `webview_flutter` (WKWebView), unchanged |
     | **Windows** | **`webview_flutter_windows`** (WebView2): a Windows implementation of the same `webview_flutter` API, so `EmailDetails` barely changes. WebView2 ships with Windows 10/11. |
     | Linux / NAS | `flutter_widget_from_html` + **Open in browser** (see [core-ci-linux-build.md](core-ci-linux-build.md)) |

     Also add the **Open in browser** button on Windows (sanitised HTML to a temp file, opened
     in the system browser) as an escape hatch. **Spike:** confirm `webview_flutter_windows` is
     maintained and passes our CSP and data-URI images. If it fails, fall back to
     `flutter_widget_from_html` on Windows too.
   - **PDF (decided 2026-10-26):** replace `pdfx` with **`pdfrx`** (pdfium) **on every
     platform**, macOS included, so there's one code path (`pdf_preview_widget.dart` and its
     test controller). **The Windows build needs Developer Mode enabled** on the CI runner
     (pdfrx requirement). Upgrade Flutter if pdfrx needs it.
     - **2026-11-03:** the shared migration landed with the Linux work (no test controller any
       more). Still to do here: Developer Mode on the runner and checking it on Windows.
   - `media_kit`: ✓ (bundles libmpv). `window_manager`,
     `screen_retriever`, `desktop_window`, `window_to_front`, `url_launcher`, `file_picker`,
     `flutter_secure_storage`, `package_info_plus`: ✓.
   - `native_exif` and `flutter_file_dialog` are **mobile-only** and unused in `lib/`. Remove
     them from `pubspec.yaml`.
   - `resqlite` / `resqlite_vector`: Windows ✓ (native-assets build hook with an MSVC path).
     Confirm it builds on the runner.
3. **macOS-only code:**
   - `SystemTrashChannel.swift` backs `system_trash.dart`. Windows needs the Recycle Bin
     (`IFileOperation` / `SHFileOperation` with `FOF_ALLOWUNDO`). That's the parked
     [windows-recycle-bin.md](windows-recycle-bin.md), which this plan **unparks**.
   - Paths: `python_manager.dart`, `database_manager.dart` and `update_checker.dart` refer to
     `Application Support` / `Library/`. Use `path_provider`'s support directory (`%APPDATA%`)
     everywhere.
   - The sync-folder connector's `~/Library/CloudStorage` detection and the `SF_DATALESS` check
     are macOS-only. On Windows, the equivalents are the OneDrive/Dropbox folders and **Cloud
     Files placeholders** (`FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` /
     `FILE_ATTRIBUTE_OFFLINE`). Note this in [files-sources-foundation.md](files-sources-foundation.md).
   - Process shutdown: `Process.kill(sigterm)` maps to `TerminateProcess` on Windows (no graceful
     shutdown). Add an HTTP `/shutdown` call to the aiserver before killing it.
4. **aiserver for Windows** (`build_python.yml`): re-enable `windows-latest`.
   - **llama-cpp-python:** CPU build first, with **Vulkan or CUDA** builds as options for GPU
     users **(decide the default)**.
   - **`pypff`/libpff:** PST import must build on Windows (MSVC), or PST import is disabled there
     until it does.
   - PyInstaller output → `aiserver-windows.zip` artifact.
5. **CI job** (`build_and_release.yml`): a `windows-latest` job with Flutter at the **latest
   stable** version (the project tracks the latest; upgrading for library compatibility is
   expected), **Developer Mode** enabled for pdfrx, the Windows aiserver artifact,
   `flutter build windows --release --dart-define=REALM_NAME=…`, and the bundle zipped as an
   artifact.
6. **Installer:** **MSIX** (`msix` package; clean install/uninstall, Store-ready) or Inno Setup
   (`.exe`) **(decide)**. Auto-update is out of scope here (Sparkle is macOS-only). Use the
   update checker plus a download link at first.
7. **Signing:** unsigned builds trigger SmartScreen warnings. Options: an OV/EV certificate, or
   **Azure Trusted Signing** (cheaper, works in CI) **(decide; secrets go in GitHub Actions)**.

## Done when

- A tagged release produces a Windows installer artifact next to the macOS one, built entirely
  in GitHub Actions.
- The app starts on Windows 11, spawns its aiserver, and syncs a local folder and an IMAP
  account. Email HTML renders, and deleting a photo goes to the Recycle Bin.
- No macOS-only path or plugin is reachable on Windows without a guard.
