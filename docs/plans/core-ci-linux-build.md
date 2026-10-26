---
status: proposed
adr: none
remaining: [linux-runner-scaffold, plugin-audit, html-widget-email-view, html-widget-spike, pdfrx-migration, system-trash, aiserver-linux, ci-job, packaging, arm64]
---

# Plan: Build the Linux desktop app in GitHub Actions

**Today:** no `client/linux/` folder, and Linux is commented out in `build_python.yml`.
`python_manager.dart` already expects `aiserver-linux.zip`. This plan is also the
**prerequisite for [core-nas-docker.md](core-nas-docker.md)**: the NAS container runs this
bundle.

## Work

1. **Scaffold the runner:** `flutter create --platforms=linux .`; commit `client/linux/`. Set
   the binary name, `.desktop` entry and icon from the realm.
2. **Plugin audit** (Linux support):
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
     - **Spike:** render a sample of real messages (plain personal mail, receipts, two or three
       newsletters) and record what breaks. Remote images keep the existing CSP rules.
   - **PDF (decided 2026-10-26):** `pdfx` has **no Linux implementation**. Replace it with
     **`pdfrx`** (pdfium; Linux x64/ARM64/ARM/x86, bundled through Dart native assets) **on
     every platform**, as the Windows plan does. Upgrade Flutter if pdfrx needs it.
   - `media_kit`: ✓ (needs `libmpv` on the system, or bundled via `media_kit_libs_linux`).
     `file_picker`: ✓, using **zenity**/kdialog or the XDG portal at runtime.
     `flutter_secure_storage`: ✓, but needs **libsecret and a running Secret Service keyring**.
     Check whether the app actually uses it at runtime (the vault is file-based,
     `secure_vault.dart`). If not, drop it, because a keyring doesn't exist in a container.
   - `resqlite` / `resqlite_vector`: Linux ✓ (native-assets hook). Confirm on the runner.
   - Remove the unused mobile-only `native_exif` and `flutter_file_dialog`.
3. **macOS-only code:**
   - **System trash:** implement the freedesktop.org Trash spec (`gio trash`, or
     `~/.local/share/Trash/{files,info}`). On the NAS, the "trash" of a mounted share is a
     different story; see the NAS plan.
   - Paths via `path_provider` (`~/.local/share/<app>`); honour `XDG_DATA_HOME`.
   - The sync-folder connector is macOS-centric. On Linux, offer only plain folders
     (Dropbox/Nextcloud clients sync real files there; no placeholders).
   - `DesktopOAuthManager` opens the system browser with `launchUrlString` → `xdg-open`. That
     works on a desktop, but **not in a headless container** (see the NAS plan).
4. **aiserver for Linux** (`build_python.yml`): re-enable `ubuntu-latest`. llama-cpp-python as
   a CPU build (`GGML_NATIVE=off` for portable SIMD), with optional Vulkan/CUDA variants;
   `pypff` builds on Linux; PyInstaller → `aiserver-linux.zip`.
5. **CI job:**
   - **Build on an old-enough base** so the binary runs on most distros: glibc is
     forward-compatible but not backward. Build on `ubuntu-22.04`, or inside a Debian 12
     container. Match the NAS image's base.
   - Flutter at the **latest stable** version (the project tracks the latest; upgrade for
     library compatibility when needed).
   - Install the build dependencies (`clang cmake ninja-build pkg-config libgtk-3-dev
     liblzma-dev libmpv-dev`, …), then
     `flutter build linux --release --dart-define=REALM_NAME=…`, and bundle `aiserver-linux.zip`.
6. **Packaging:** a **tar.gz** of the bundle first. Then **AppImage** (one file, any distro) or
   **Flatpak** (sandboxing complicates spawning the aiserver and reading arbitrary folders, so
   prefer AppImage) **(decide)**. The `.deb` is optional.
7. **arm64:** a second job on GitHub's **`ubuntu-24.04-arm`** runners for arm64 Linux, which
   also covers ARM-based Synology models and a Raspberry Pi.

## Done when

- A tagged release produces Linux x86_64 (and arm64) bundles built in GitHub Actions.
- On Ubuntu 22.04/24.04 desktop, the app starts, spawns its aiserver, syncs local folders and an
  IMAP account, renders email HTML, opens PDFs, and moves deleted photos to the Trash.
- The same bundle starts under Xvfb (a smoke test in CI: `xvfb-run` launches the app and checks
  the aiserver URL appears). That's the NAS prerequisite.
