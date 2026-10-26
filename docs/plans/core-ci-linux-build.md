---
status: proposed
adr: none
remaining: [linux-runner-scaffold, plugin-audit, webview-replacement, pdf-viewer, system-trash, aiserver-linux, ci-job, packaging, arm64]
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
   - **`webview_flutter`**: **no Linux support**. Use the same replacement as Windows
     ([core-ci-windows-build.md](core-ci-windows-build.md)): a sanitised Flutter HTML renderer
     for email bodies (WebKitGTK webviews are fragile under software rendering, which matters for
     the NAS container).
   - **`pdfx`**: **no Linux implementation** (Android, iOS, macOS, Windows, web only). Options:
     `pdfrx` (pdfium, supports Linux), or render PDF pages in the aiserver (PyMuPDF) as images
     **(decide)**.
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
