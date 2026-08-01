# My Data Studio

### Your personal data manager, organizer, and backup tool

My Data Studio started with one idea — we need a way to keep a local copy of our online digital life. This includes cloud drives, emails, social media posts, and more, all searchable with a local, on-device AI — no cloud API calls required.

## Features

- **Local-first**: All data is stored locally on your device.
- **Privacy-focused**: No data is stored on My Data Studio's own servers — there are none. AI search and chat run against a locally-bundled LLM by default, not a cloud API.
- **AI-powered search**: Semantic search and chat across your files, email, and photos using local GGUF models (Gemma + Qwen3-VL embeddings). Optional cloud models (Gemini/Claude/OpenAI/Grok) can be enabled with your own API key — doing so sends that request (system prompt, chat history, your message, and any attached image bytes) off-device to the chosen provider, whose own retention and training terms apply and vary by provider and account tier. Review the provider's policy before enabling it.
- **Multiple sources**: Local filesystem, Google Drive, Gmail, Yahoo Mail, Outlook (live IMAP or `.pst` file import).
- **Open-source**: Free and open-source software (Apache 2.0).

The current release targets **macOS**. See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and [DESIGN.md](DESIGN.md) for the UI/theme spec.

## How It's Built

The app has two parts, built and shipped together:

1. A **Flutter macOS client** (`client/`) — the UI, local SQLite database, and background scanners.
2. A **Python FastAPI service** (`aiserver/`) — bundled and spawned as a subprocess by the client at launch; it does all LLM inference, embeddings, and PST parsing over a local HTTP port. In the packaged app, you never run it separately; for `aiserver`-only development you can run it standalone (see below) and point the client at it.

## Getting Started

### Prerequisites

- macOS with Xcode (for the `flutter build macos` toolchain)
- [Flutter](https://flutter.dev) 3.44.8 (bundles Dart 3.12)
- Python 3.11–3.14 with [pdm](https://pdm-project.org/) installed, for building `aiserver`
- The [`hf`](https://huggingface.co/docs/huggingface_hub/guides/cli) CLI, for downloading GGUF models (`pip install -U "huggingface_hub[cli]"`)

### Clone the repository

```bash
git clone https://github.com/XDT-Labs/mydatastudio.git
cd mydatastudio
```

### Build & run (recommended: `make`)

All orchestration goes through the root `Makefile`. For local development, this downloads the models, builds the Python service, and installs it where the Flutter client expects to find it — then you run the client from Flutter directly so you get hot reload:

```bash
make models            # Download GGUF models from Hugging Face (one-time, several GB)
make dev                # Build the Python aiserver binary and install it locally
cd client && flutter pub get && flutter run -d macos
```

To build a full release `.app` (Python service + Flutter client bundled together):

```bash
make all
```

Other useful targets — see the `Makefile` header or [CLAUDE.md](CLAUDE.md) for the full list:

```bash
make build-python       # Compile only the Python service (PyInstaller, Metal-enabled)
make build-client       # Build only the Flutter macOS release bundle
make clean               # Remove all build artifacts
```

### Flutter client only

```bash
cd client
flutter pub get                      # Install dependencies
flutter test                         # Run Flutter tests
flutter build macos --release --no-tree-shake-icons
```

Note: without `make dev`/`make build-python` having installed an `aiserver` binary first, the client will still run, but AI chat/search features that depend on the local LLM service won't have a backend to talk to.

### Python service only

```bash
cd aiserver
pdm install
python main.py                       # Run a dev server (Uvicorn on a random port)
PYTHONPATH=src pdm run pytest        # Run the test suite
```

## License

This project is licensed under the Apache 2.0 License — see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please open an issue or pull request.

## Contact
[XDT Labs](mailto:mike@xdtlabs.com)
