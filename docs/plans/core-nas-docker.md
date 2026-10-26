---
status: proposed
adr: none
remaining: [base-image-choice, image-build, nas-file-mounts, auth-and-tls, in-container-browser, file-picker, ai-workload, synology-excludes, compose-and-docs, ci-publish, arm64]
---

# Plan: Run the Linux desktop app on a Synology NAS in Docker

**Wave 6** ([release plan](../RELEASE-PLAN.md)), near the end of feature development. Depends on
[core-ci-linux-build.md](core-ci-linux-build.md).

The goal: My Data Studio runs **24/7 on the NAS**, indexing the NAS's own folders directly, and
the user opens it from any browser on the network. No code fork: it's the same Linux desktop
bundle, displayed through a virtual screen streamed to the browser.

## Will it work? Yes

This is an established pattern. Desktop Linux apps are routinely shipped as "GUI in a browser"
containers on Synology and Unraid. The mechanics are as Gemini described:
1. a virtual X display (**Xvfb**);
2. a minimal window manager;
3. a VNC server;
4. **noVNC** in the browser, over WebSocket.

Our app runs as a normal x86_64 Linux process. SQLite sits on a local Docker volume, and NAS
folders are **bind-mounted**, so the scanner reads them at local-disk speed, not over SMB.

**Don't hand-roll the Xvfb/x11vnc/noVNC/supervisord stack.** Build on a maintained base image
that already handles auth, TLS, resizing, clipboard, permissions and process supervision
**(decide after a spike)**:
- **`jlesage/baseimage-gui`**: purpose-built for a single app in a browser. noVNC, optional web
  login and HTTPS, `USER_ID`/`GROUP_ID`, `/config` volume, app auto-restart, dark mode. Widely
  used on Synology.
- **LinuxServer.io GUI base** (KasmVNC, or the newer **Selkies** WebRTC stream): smoother video
  and dynamic resizing, `PUID`/`PGID` conventions **(verify which base LinuxServer recommends
  now)**.

## What the Gemini conversation missed

| Gap | Why it matters | Plan |
|---|---|---|
| **No authentication** (`x11vnc -nopw -listen 0.0.0.0`) | Anyone on the network would get full control of an app holding the user's email, photos and messages | The base image's web login + HTTPS; bind to the LAN only; remote access only via **Tailscale/VPN** or DSM's reverse proxy with auth. Never port-forward. |
| **The AI workload, not X11, is the real cost** | The app spawns the **aiserver** with local GGUF models (chat + Qwen3-VL 2B embeddings): multi-GB downloads, several GB of RAM, and CPU-only inference on a NAS (no usable GPU on most models). Gemini's 400–600 MB estimate ignores this. Indexing a photo library on a NAS CPU could take days. | Three modes: **(a)** local CPU, with throttled background indexing and smaller models, needing 8 GB+ RAM (document the minimum); **(b)** **remote aiserver**: point at an aiserver on a Mac or PC with a GPU (the `PYTHON_SERVER_URL` dart-define already exists; make it a runtime setting); **(c)** cloud model passthrough for chat. The default is decided by the spike's measurements. |
| **OAuth sign-ins open a browser *inside* the container** | `DesktopOAuthManager` → `launchUrlString` → `xdg-open`, but there's no browser in the container. Loopback redirects (`127.0.0.1:<port>`) must also land *inside* the container, so the user's own browser can't complete them. | Ship a small browser (**Firefox ESR**) in the image as the `xdg-open` handler. The sign-in window opens inside the streamed desktop and the redirect stays local. The image grows by about 250 MB; accept it. Alternative later: device-code flows where providers support them. |
| **File picker** | `file_picker` on Linux needs **zenity**/kdialog or the XDG portal. It also browses the *container's* paths, not DSM's. | Install zenity. Mount NAS folders under one clear root (`/nas/…`), and default the picker there. Setup copy says "your NAS folders are under /nas". |
| **Synology metadata folders** | DSM litters shares with `@eaDir` (thumbnails), `#recycle`, `#snapshot` and `.SynologyWorkingDirectory`. Indexing them duplicates every photo and indexes the recycle bin. | Default scanner excludes for those names (useful on any OS that reads a Synology share). |
| **Permissions** | Bind mounts are read as the container user. DSM shares belong to DSM users and groups. | `USER_ID`/`GROUP_ID` set to a DSM user with **read-only** access to the shares to index. Mount them **`:ro`**, so the app can't change the NAS, and hide Delete/"move to Trash" actions on read-only collections. |
| **Plugins without Linux support** | `webview_flutter` (email HTML) and `pdfx` (PDFs) don't run on Linux. | Fixed in the Linux build plan. A WebKitGTK webview would also struggle under software rendering, which is one more reason for the Flutter HTML renderer. |
| **Rendering details** | Under Xvfb, Flutter needs Mesa (`libgl1-mesa-dri`, `libegl1`) for software OpenGL (llvmpipe). Also fonts (Noto + emoji + CJK, or names and emoji render as boxes), locale and `TZ`. | Install these in the image. Optionally pass `/dev/dri` through on NAS models with an Intel iGPU (e.g. the J4125-based DS920+) for hardware GL. |
| **The app must run 24/7 and fill the screen** | It's a desktop app with a close button. If closed, indexing stops. | Start maximised and borderless at the virtual screen size. The base image restarts the app if it exits. Hide "Quit" in a `NAS_MODE`. Resize with the browser window (base-image dependent). |
| **The database must stay on a local volume** | Gemini is right that SQLite WAL must never sit on SMB. | `/config` (DB, models, aiserver install, logs) is a **local** bind mount (`/volume1/docker/mydatastudio/config`), covered by Btrfs snapshots. Never a network share. |
| **Updates and distribution** | — | CI builds and pushes `ghcr.io/<org>/mydatastudio-nas:<version>` (+ `latest`). The user updates through Container Manager (or Watchtower). DB migrations already run on open. |
| **ARM models** | Gemini covered x86_64. Some Synology models (value and "j" series) are ARM64, and not every model gets Container Manager **(verify the model list)**. | Multi-arch image (amd64 + arm64) from the Linux build's arm64 job. Document the supported models. |

**Gemini's later suggestions don't fit this goal.** PowerSync/ElectricSQL "local-first sync" and
a remote SQLite VFS solve a different problem: several desktops sharing one database. Both
would mean a server database (PowerSync needs Postgres) and a rewrite of the data layer. We
don't need that. The NAS copy is its *own* instance, indexing the NAS. The Dart server + Flutter
web split (its "Option 2") is the right *long-term* shape for multi-user web access, but it's a
rewrite. Revisit only if streaming proves too limiting.

**Single session:** noVNC shares one screen, so two people opening it at once see (and fight
over) the same session. Fine for a personal archive; document it.

## The image

- `FROM` the chosen base. Install the runtime libraries (GTK3, Mesa, libmpv, fonts, zenity,
  Firefox ESR).
- `COPY` the Linux bundle + `aiserver-linux.zip` from the CI artifacts. Set the start command
  with `NAS_MODE=1`.
- `/config` holds `APP_SUPPORT_DIR` (DB, vault, models, aiserver install); `/nas` is the root
  for read-only share mounts.

```yaml
# docker-compose.yml (Container Manager › Project)
services:
  mydatastudio:
    image: ghcr.io/<org>/mydatastudio-nas:latest
    ports: ["5800:5800"]           # web UI (base-image port; verify)
    environment:
      USER_ID: "1026"              # DSM user with read access to the shares
      GROUP_ID: "100"
      TZ: "America/Chicago"
      WEB_AUTHENTICATION: "1"      # base-image login (verify variable names)
    volumes:
      - /volume1/docker/mydatastudio/config:/config
      - /volume1/photo:/nas/photo:ro
      - /volume1/homes/mike/Documents:/nas/documents:ro
    restart: unless-stopped
    shm_size: "1gb"                # browser and Flutter rendering
```

## Spike first

On a real Synology (an x86 Plus model), with the CI Linux bundle:
- startup under each base image, input latency, resize;
- **memory and CPU at idle, while scanning, and while embedding** (local CPU vs remote
  aiserver);
- the OAuth sign-in through the in-container Firefox;
- scanning a 100k-file share with the Synology excludes.

Record the numbers here, then set the default AI mode and the minimum RAM.

## Done when

- A user pastes the compose file into Container Manager, opens `https://nas:5800`, logs in, and
  uses the full app in the browser.
- NAS shares are indexed read-only at local speed; `@eaDir`/`#recycle` are skipped.
- OAuth sign-ins (Google, Microsoft, Dropbox) complete inside the session.
- With a remote aiserver configured, embeddings run on the other machine and the NAS stays
  responsive. With local CPU, indexing proceeds in the background without stalling the UI.
- The image is multi-arch, published by CI, and survives restarts and updates with data intact.
