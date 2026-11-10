---
status: done
adr: none
remaining: []
---

# Plan: Build the Linux desktop app in GitHub Actions

**Done 2026-11-09.** Tagged releases build and publish Linux x86_64 and arm64 AppImages (#44), and
the hand check on a real Ubuntu desktop (`desktop-check`) is done, confirmed by the project owner.
The "Not checked" notes below record what was open while the work was in progress.

**Today:** no `client/linux/` folder, and Linux is commented out in `build_python.yml`.
`python_manager.dart` already expects `aiserver-linux.zip`. This plan is also the
**prerequisite for [core-nas-docker.md](core-nas-docker.md)**: the NAS container runs this
bundle.

## Work

1. [x] **Scaffold the runner:** `flutter create --platforms=linux .`; commit `client/linux/`. Set
   the binary name, `.desktop` entry and icon from the realm.
   - **Done 2026-11-03.** Binary `mydatastudio`; GTK application id is the realm
     (`com.xdtlabs.mydatastudio`, or `REALM_NAME` from the environment at CMake time), so
     path_provider's support directory is `~/.local/share/<realm>`. Window title
     "MyData Studio". `linux/packaging/` holds the icon (installed to `data/app_icon.png`, loaded
     as the window icon) and a `.desktop` template installed as `data/<realm>.desktop`.
   - Verified in an Ubuntu 22.04 arm64 container with Flutter 3.47.0 (first with `three_js`
     stubbed out, then for real with the plugin-audit script): `flutter build linux --release` succeeds (41 MB bundle) and the
     app starts under `xvfb-run` to the onboarding screen. x86_64 not built yet.
   - Build dependencies found so far: `build-essential` (native-asset hooks and media_kit's
     mimalloc call `make`), `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
     libstdc++-12-dev libmpv-dev`.
2. [x] **Plugin audit** (Linux support):
   - **Email HTML (decided 2026-10-26).** `webview_flutter` has **no Linux support**. The
     Linux implementation of the shared **`EmailBodyView`** interface (defined in
     [core-ci-windows-build.md](core-ci-windows-build.md)) is **`flutter_widget_from_html`**:
     pure Dart, so it runs anywhere, including the NAS container under software rendering. It
     needs no browser engine and runs no scripts. It's fed the same sanitised, `cid:`-inlined
     HTML as the other platforms.
     - **Open in browser** button: writes the sanitised HTML to a temp file and opens it with
       `xdg-open` (on the NAS, that's the in-container Firefox). It's for the occasional
       newsletter the widget renders poorly (nested tables, floats, media queries).
     - **Rejected:** `webview_all_linux` (WebKitGTK; fragile and heavy under Xvfb), `webview_cef`
       (bundles Chromium, 100+ MB, software path on Linux), and `webview_win_floating` (the
       native view floats above Flutter, so menus can't draw over it).
     - [x] **Spike:** render a sample of real messages (plain personal mail, receipts, two or three
       newsletters) and record what breaks. Remote images keep the existing CSP rules.
       - **Done 2026-11-03** with `flutter_widget_from_html_core` 0.17.4 on Ubuntu 22.04 arm64
         under Xvfb, using **synthetic** fixtures (a personal reply with a quote, a table
         receipt, a nested-table newsletter, a float/flex newsletter, an escaped plain-text body),
         not real mail. Real messages get checked when the email view is wired in.
       - **Works:** inline styles, nested tables with `width`/`align`/`valign`/`colspan`,
         `bgcolor` and inline `background` on inner cells, `data:` and remote `https:` images,
         the hidden preheader (`display:none`), `<!--[if mso]>` comments, `<center>`,
         blockquote borders, links. The CSP `<meta>` is ignored harmlessly (no scripts run).
       - **Breaks:** rules in `<style>` blocks (classes, descendant selectors such as
         `.btn a`, media queries), so CTA buttons fall back to plain links and class-based
         colours and borders vanish; `float` and `display:flex` stack vertically; CSS
         `background-image`; `bgcolor` on the outermost wrapper table. Inherited
         `align="center"` centres list text away from its bullets.
       - **Plain text:** `white-space: pre-wrap` is ignored, so line breaks collapse. The Linux
         view must render plain bodies as text, not through the HTML widget.
       - Verdict: readable for personal mail and receipts; newsletters lose their styling,
         which is what **Open in browser** is for. Use the `_core` package: the full
         `flutter_widget_from_html` pulls in webview, video and audio plugins.
     - [x] **Email view done 2026-11-03.** `EmailBodyPreparer` (sanitising, CSP, `cid:` inlining)
       now sits in front of `EmailBodyView`, which picks `WebViewEmailBodyView` (macOS, same
       behaviour) or `HtmlEmailBodyView` (Linux, `_core` package). Added on Linux beyond the plan,
       because the widget ignores the CSP and `<head>`: images are limited to `data:`/`http(s):`,
       links open externally for `http(s):`/`mailto:` only, and `<title>` is hidden.
       - **Open in browser** writes one file per session into a `700` folder made with `mktemp`
         (Dart's `createTemp` gives `755` on Linux) with a UTF-8 BOM, because the sanitiser strips
         `<meta charset>`. That file stays in the temp folder after the app quits.
       - **Not checked:** real mail (only the synthetic fixtures so far), and an actual `xdg-open`
         launch. Snap Firefox, Ubuntu's default, has a private `/tmp`, so it may not be able to
         open this file; try it on a desktop Ubuntu before release.
   - **PDF (decided 2026-10-26):** `pdfx` has **no Linux implementation**. Replace it with
     **`pdfrx`** (pdfium; Linux x64/ARM64/ARM/x86, bundled through Dart native assets) **on
     every platform**, as the Windows plan does. Upgrade Flutter if pdfrx needs it.
     - [x] **Done 2026-11-03** with `pdfrx` 2.11.0 (Flutter 3.47.0 is enough). `PdfPreviewWidget`
       uses `PdfViewer.file` with pages laid out left to right. It now scrolls continuously and
       can show part of the next page; `pdfx` snapped to one page at a time.
       - **Checked:** in the Linux arm64 app, a real two-page PDF renders, Next moves to
         "Page 2 of 2", and a damaged file shows the error. In a macOS debug app, pdfium opens and
         renders a page and rejects a damaged file; the viewer widget itself wasn't run there.
       - **Tests:** `flutter test` has no pdfium, so the suite covers the layout and nav bar only.
         Opening files is a manual check (see above).
       - **Not checked:** Release signing and notarization with the new `pdfium.framework`, which
         needs a real tag run.
   - `media_kit`: ✓ (needs `libmpv` on the system, or bundled via `media_kit_libs_linux`).
     `file_picker`: ✓, using **zenity**/kdialog or the XDG portal at runtime.
     `flutter_secure_storage`: ✓, but needs **libsecret and a running Secret Service keyring**.
     Check whether the app actually uses it at runtime (the vault is file-based,
     `secure_vault.dart`). If not, drop it, because a keyring doesn't exist in a container.
   - `resqlite` / `resqlite_vector`: Linux ✓ (native-assets hook). Confirm on the runner.
   - Remove the unused mobile-only `native_exif` and `flutter_file_dialog`.
   - **Progress 2026-11-03:** removed `native_exif`, `flutter_file_dialog` and
     `flutter_secure_storage` (unused in `lib/`; only a leftover mock in `login_test.dart`), so no
     keyring is needed. **New blocker:** `flutter_angle` (via `three_js` →
     `three_js_angle_renderer`, used by the STL preview) has an unfinished Linux plugin that
     doesn't compile against Flutter 3.47's `FlTextureGL` API, in 0.4.1 or the latest 0.4.2.
     **Decided 2026-11-03: stub it on Linux.** `tool/linux_without_flutter_angle.py` (run before
     `flutter pub get` on Linux builds only) copies the locked flutter_angle from the pub cache
     into `build/linux_overrides/`, drops its `linux:` plugin entry and writes a gitignored
     `pubspec_overrides.yaml`. It's a build-time copy, not a committed one, because the package
     is ~50 MB of prebuilt Windows/Android binaries. `StlPreviewWidget` shows "3D preview isn't
     available on Linux." and never creates a renderer there (widget test). The NAS runs
     without a GPU, so a GL preview would be poor there anyway.
   - [x] **Plugin audit done 2026-11-03.** With the script, the full app builds on Ubuntu 22.04
     arm64 (`three_js` included) and the Linux plugin set is `desktop_window`, `file_picker`,
     `jni`, `media_kit_libs_linux`, `media_kit_video`, `package_info_plus`,
     `path_provider_linux`, `screen_retriever_linux`, `url_launcher_linux`, `wakelock_plus`,
     `window_manager`, `window_to_front`. `webview_flutter` and `pdfx` have no Linux
     implementation and are handled by the next tasks. Runtime needs: `libmpv` (media_kit),
     `zenity` or `kdialog` (file_picker).
3. [x] **macOS-only code:**
   - [x] **System trash, done 2026-11-03:** implemented in the runner
     (`linux/runner/system_trash_channel.cc`) with GIO's `g_file_trash`, on the same
     `mydatastudio/system_trash` channel as macOS, so the Dart side is unchanged. Chosen over
     the `gio` command, which isn't always installed (a container, for one).
     - **Checked in the real Linux app (arm64):** home trash with `.trashinfo`, an accented name
       with spaces, name collisions, `XDG_DATA_HOME`, and an already-missing file (counts as
       success). On an ext4 volume as a normal user, the file goes to `$topdir/.Trash-$uid`.
     - **No trash available:** on read-only mounts, tmpfs and a Docker bind mount it returns false
       and the file stays. The photos path still hides the row, as it does on macOS, so the file
       stays on disk with no message to the user. The NAS plan needs to deal with this for shares.
     - **Not automated:** `flutter test` has no runner, so the native side was checked by hand.
     - **Not checked:** an actual desktop's Trash view, and a real USB drive.
   - Paths via `path_provider` (`~/.local/share/<app>`); honour `XDG_DATA_HOME`.
   - The sync-folder connector is macOS-centric. On Linux, offer only plain folders
     (Dropbox/Nextcloud clients sync real files there; no placeholders).
   - `DesktopOAuthManager` opens the system browser with `launchUrlString` → `xdg-open`. That
     works on a desktop, but **not in a headless container** (see the NAS plan).
4. [x] **aiserver for Linux** (`build_python.yml`): re-enable Ubuntu. llama-cpp-python as
   a CPU build (`GGML_NATIVE=off` for portable SIMD), with optional Vulkan/CUDA variants;
   `pypff` builds on Linux; PyInstaller → `aiserver-linux.zip`.
   - **Done 2026-11-03.** `make build-python` has a Linux path that installs from an export of
     `pdm.lock`, with torch at its locked version from PyTorch's CPU index. That skips about 5 GB
     of CUDA libraries and leaves the lock and the macOS build alone. The zip is 465 MB (1.3 GB
     unpacked). Vulkan and CUDA variants aren't built. `pubspec.prod.yaml` now bundles `app/`,
     which holds only the current platform's zip.
   - **Vulkan (2026-11-08):** x64 builds llama.cpp with `-DGGML_VULKAN=on` against LunarG's SDK
     and bundles `libvulkan.so.1` in `llama_cpp/lib`, so it falls back to the CPU on machines
     with no Vulkan driver. **arm64 stays CPU:** LunarG ships no arm64 Linux SDK, and Ubuntu
     22.04 (the build base, for glibc reach) has no `glslc` package. Building glslc from source
     would lift this. Embeddings stay on CPU torch.
   - **Checked on arm64 (Ubuntu 22.04 build):** on clean 22.04 and 24.04 images the binary starts,
     enforces the token and stops on SIGTERM. On clean 22.04, thumbnails and a real GGUF chat
     completion (CPU) work. In the Linux app bundle, the production `PythonManager` finds, unzips
     and spawns it and reads the URL in 18 s, leaving no process behind after stopping. The Python
     suite passes on 24.04 (320 tests).
   - **Known limit, document extraction needs glibc 2.38+:** the docling-rs 1.104.3 wheels are
     tagged `manylinux_2_28` but need `__isoc23_strtol`, on x86_64 too (checked in the wheel). It
     comes from the prebuilt ONNX Runtime, so building from source doesn't fix it. On 22.04,
     `/util/extract-text` returns 503 and files stay retryable, and the rest works. 24.04 extracts
     text.
   - **PDFs:** after merging develop's `text_layer_only` fix, a real born-digital PDF returns its
     text from the frozen binary on 24.04. There's no vendored pdfium any more.
   - **Runtime need:** `PythonManager` calls the `unzip` command, which packaging has to provide
     or declare.
   - **Not checked:** x86_64, `build_python.yml` itself (needs a real run), the full app past
     onboarding, and real Gemma or EmbeddingGemma models.
5. [x] **CI job:**
   - **Build on an old-enough base** so the binary runs on most distros: glibc is
     forward-compatible but not backward. Build on `ubuntu-22.04`, or inside a Debian 12
     container. Match the NAS image's base.
   - Flutter at the **latest stable** version (the project tracks the latest; upgrade for
     library compatibility when needed).
   - Install the build dependencies (`clang cmake ninja-build pkg-config libgtk-3-dev
     liblzma-dev libmpv-dev`, …), then
     `flutter build linux --release --dart-define=REALM_NAME=…`, and bundle `aiserver-linux.zip`.
   - **Written 2026-11-03, not ticked until a real tag run passes.** A new `verify-tag` job runs
     first (`.github/scripts/verify_tag.sh`) and is where every platform gets its version:
     production tags must be on main, and pre-release tags (with a suffix) work on any branch
     (from 2026-11-07; pre-releases first had to be on develop). It outputs plain `X.Y.Z`
     because macOS requires that; the suffix stays on the tag and release name. The macOS job's
     steps are unchanged apart from reading that output. `build-linux` needs `verify-tag`, and
     `release` needs every platform, so one failed build publishes nothing. `make build-client`
     has a Linux path.
   - **Differs from the design above:** Flutter is 3.47.0, matching the macOS job, not the latest
     stable (3.47.9); bump both together. It comes from a git clone because Flutter publishes no
     arm64 Linux SDK.
   - **Smoke test** (`.github/scripts/linux_smoke_test.sh`): differs from "Done when" below. The app
     only spawns its aiserver after onboarding, so the test starts the bundled aiserver on its own
     (URL appears, 401 without the token, 200 with it, stops on SIGTERM), then checks the app stays
     up under Xvfb and creates its support directory. It uses Xvfb directly because `xvfb-run` hung
     here, and every wait is bounded.
   - **Checked:** YAML parses; actionlint and shellcheck report nothing new at warning level;
     11 `verify_tag.sh` cases in a scratch repo (right branch, wrong branch, feature branch,
     annotated tags, malformed tags). On a clean Ubuntu 22.04 arm64 container with only the job's
     apt list: `make build-client`, version 9.8.7+42 reaches the bundle, the smoke test passes
     and fails on a bundle missing its aiserver, and the archive has the right layout. That run
     reused an aiserver zip built earlier rather than running `make build-python`.
   - **Needs a real tag run:** the workflow itself, all of x86_64, GitHub's runners and their disk
     space, `build_python.yml`, artifact upload, the release job, and the macOS job after this
     change.
   - **First tag run (`v1.2.3-beta.2`, 2026-11-07):** macOS passed, including the DMG. arm64
     failed compiling the `jni` plugin, and x64 was cancelled before building. GitHub's image has
     CMake 3.31.6 and JDKs, so CMake finds JNI and builds the plugin. The local image's CMake 3.22
     doesn't. `jni` comes in through `path_provider_android` and is only used on Android, so
     `client/linux/CMakeLists.txt` now turns off the JDK search. Reproduced and fixed on arm64
     with CMake 3.31.6 and a Temurin JDK: build, AppImage and smoke test pass, and nothing links
     `libjvm`.
   - **Done 2026-11-07: second tag run (`v1.2.3-beta.3`, run 42403166226) passed.** Every job
     succeeded: verify-tag, macOS (36 min), x64 (18 min), arm64 (15 min), and the release job,
     which published a pre-release with the DMG, `aiserver-macos.zip`, and an AppImage and tar.gz
     per Linux architecture. The smoke test passed on both runners.
6. [x] **Packaging:** a **tar.gz** of the bundle first. Then **AppImage** (one file, any distro) or
   **Flatpak** (sandboxing complicates spawning the aiserver and reading arbitrary folders, so
   prefer AppImage) **(decide)**. The `.deb` is optional.
   - **AppImage chosen and written 2026-11-03, not ticked until a real tag run passes.**
     `.github/scripts/build_appimage.sh` builds a self-contained tree, and the job publishes
     `MyDataStudio-<tag>-linux-<arch>.AppImage` (554 MB on arm64) and a `.tar.gz` of the same tree.
     Since 2026-11-08 the `.tar.gz` is off by default: set `LINUX_TARBALL: "true"` in
     `build_and_release.yml` to publish it again (for example for the NAS image or machines
     without FUSE). `--appimage-extract` gives the same tree meanwhile.
   - **Why both come from that tree:** a bare bundle built on 22.04 links `libmpv.so.1`, which
     isn't on newer distros (24.04 ships `libmpv.so.2`). So libmpv and its dependencies (154
     libraries, 202 MB) and `unzip` are bundled and found through RUNPATH. `LD_LIBRARY_PATH` would
     leak into what the app launches, such as a browser through `xdg-open`.
   - **Users must have:** glibc 2.35+, GTK 3, and the GL stack (EGL, GLES, GBM), which has to match
     their drivers. The list is `SYSTEM_LIBS` in the script. It's a named list because treating
     "whatever GTK links to" as the system's share failed on Debian and Fedora.
   - **Checked on arm64:** the smoke test passes on clean Ubuntu 22.04 and 24.04, Debian 12 and 13,
     and Fedora 45, and on an Ubuntu 24.04 desktop package set, where bundled and system libraries
     could conflict. The app starts through a real FUSE mount on 24.04. After merging develop,
     it was rebuilt from the merged code and retested on 22.04 and clean 24.04.
   - **Not checked:** x86_64, a real desktop session with a GPU, video and audio playback through
     the bundled libmpv, and file dialogs (the system's zenity).
   - The `.deb` and Flatpak aren't built. Document extraction still needs Ubuntu 24.04+.
   - **Done 2026-11-07:** the `v1.2.3-beta.3` run built both on GitHub: x64 588 MB AppImage
     (156 bundled libraries), arm64 537 MB. Still not checked: the x64 AppImage on a real
     desktop.
7. [x] **arm64:** a second job on GitHub's **`ubuntu-24.04-arm`** runners for arm64 Linux, which
   also covers ARM-based Synology models and a Raspberry Pi.
   - **Written 2026-11-03** as a matrix entry on the same job, not ticked until a real tag run
     passes. It uses **`ubuntu-22.04-arm`**, not 24.04, so arm64 keeps the same glibc 2.35 floor as
     x86_64. Local builds and tests so far have all been arm64, but not on GitHub's runner.
   - **Done 2026-11-07:** built and smoke-tested on `ubuntu-22.04-arm` in the `v1.2.3-beta.3` run.

## Done when

- A tagged release produces Linux x86_64 (and arm64) bundles built in GitHub Actions.
- On Ubuntu 22.04/24.04 desktop, the app starts, spawns its aiserver, syncs local folders and an
  IMAP account, renders email HTML, opens PDFs, and moves deleted photos to the Trash.
- The same bundle starts under Xvfb (a smoke test in CI: `xvfb-run` launches the app and checks
  the aiserver URL appears). That's the NAS prerequisite.
