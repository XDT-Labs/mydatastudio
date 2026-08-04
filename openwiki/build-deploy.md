# Build & Deployment

All orchestration is through the root `Makefile`. The app consists of two independently-built components:

1. **Python aiserver** — Compiled to binary via PyInstaller, bundled in app
2. **Flutter client** — Built for macOS (Windows/Linux support planned)

---

## Build Overview

```
make all
  ├─ make models         # Download GGUF models (one-time)
  ├─ make build-python   # Compile aiserver binary (PyInstaller)
  ├─ make local-install-python  # Install to Application Support (dev only)
  └─ make build-client   # Build Flutter macOS release bundle

→ Outputs: My Data Studio.app (signed, ready for distribution)
```

---

## Quick Start Commands

### Development (Hot Reload)

```bash
# One-time setup
make models              # Download GGUF models (~5-10 GB)
make dev                 # Build Python binary + install locally

# Then run Flutter with hot reload
cd client
flutter pub get
flutter run -d macos    # Hot reload on file changes
```

### Release Build

```bash
make all                 # Full build (models + python + client)
make notarize            # Notarize for macOS Gatekeeper (optional)
```

---

## Detailed Makefile Targets

### `make models`

Download default GGUF models from HuggingFace Hub (one-time, ~5-10 GB):

```makefile
.PHONY: models
models:
	@echo "--- 📥 Checking/Downloading models ---"
	@mkdir -p $(PYTHON_DIR)/models
	@if [ ! -f $(PYTHON_DIR)/models/$(HF_FILE) ]; then \
		echo "Downloading $(HF_FILE)..."; \
		hf_hub_download --repo-id $(HF_MODEL) --filename $(HF_FILE) \
		  --local-dir $(PYTHON_DIR)/models; \
	fi
	@if [ ! -d $(HF_QWEN3_VL_DIR) ]; then \
		echo "Downloading Qwen3-VL embedding model..."; \
		huggingface-cli download $(HF_QWEN3_VL_MODEL) \
		  --local-dir $(HF_QWEN3_VL_DIR); \
	fi
```

**Models Downloaded:**

| Model | Purpose | Size |
|-------|---------|------|
| `gemma-4-12B-it-Q4_0.gguf` | Local chat inference | ~7 GB |
| `Qwen/Qwen3-VL-Embedding-2B` | Embeddings (multimodal) | ~5 GB |

### `make build-python`

Compile Python service to standalone binary using PyInstaller:

```makefile
.PHONY: build-python
build-python:
	@echo "--- 🔨 Building Python aiserver binary ---"
	cd $(PYTHON_DIR) && pdm install
	cd $(PYTHON_DIR) && pdm run pyinstaller -y main.spec
	@echo "✓ Binary: $(PYTHON_DIR)/dist/main"
	@echo "--- 📦 Zipping aiserver binary ---"
	cd $(PYTHON_DIR)/dist && zip -r ../../$(APP_ZIP_PATH) main
	@echo "✓ Zip: $(APP_ZIP_PATH)"
```

**PyInstaller Spec** (`aiserver/main.spec`):

- **Entry point:** `main.py` (FastAPI app)
- **Binaries:** Metal GPU libraries (macOS Metal acceleration)
- **Hooks:** Custom hooks for LangChain, PyTorch dependencies
- **Datas:** Models directory, hook scripts
- **Output:** `dist/main` executable

**Key Options:**

```python
a = Analysis(
    ['main.py'],
    hiddenimports=[
        'llama_cpp',           # Local inference
        'langchain_google_genai',  # Gemini
        'langchain_anthropic',     # Claude
        'langchain_openai',        # OpenAI
        'torch',               # PyTorch
        'torchvision',         # Image processing
    ],
    binaries=[],  # Metal libraries auto-discovered on macOS
)

exe = EXE(
    ...,
    name='main',
    debug=False,
    strip=False,  # Keep debug symbols for profiling
)
```

### `make local-install-python`

Install compiled Python binary to macOS Application Support (development):

```makefile
.PHONY: local-install-python
local-install-python: build-python
	@echo "--- 📂 Installing aiserver binary locally ---"
	mkdir -p "$(HOME)/Library/Application Support/com.xdtlabs.mydatastudio/aiserver"
	unzip -o $(APP_ZIP_PATH) \
	  -d "$(HOME)/Library/Application Support/com.xdtlabs.mydatastudio/aiserver"
	chmod +x "$(HOME)/Library/Application Support/com.xdtlabs.mydatastudio/aiserver/main"
	@echo "✓ Installed to Application Support"
```

Used during development so Flutter client can find the aiserver binary.

### `make build-client`

Build Flutter macOS release bundle:

```makefile
.PHONY: build-client
build-client:
	@echo "--- 🔨 Building Flutter client ---"
	cd $(FLUTTER_DIR) && \
	  flutter build macos \
	    --release \
	    --no-tree-shake-icons \
	    --dart-define=REALM_NAME=prod
	@echo "✓ App: $(FLUTTER_DIR)/build/macos/Build/Products/Release/MyDataStudio.app"
```

**Key Options:**

| Option | Purpose |
|--------|---------|
| `--release` | Optimized build (vs. debug) |
| `--no-tree-shake-icons` | Keep unused icon names (dynamic lookup) |
| `--dart-define=REALM_NAME=prod` | Production configuration (vs. dev) |

### `make all`

Full build pipeline (models + Python + Flutter):

```makefile
.PHONY: all
all: models build-python build-client
	@echo "✅ Build complete!"
	@echo "App: client/build/macos/Build/Products/Release/My Data Studio.app"
```

### `make clean`

Remove all build artifacts:

```makefile
.PHONY: clean
clean:
	@echo "--- 🗑️  Cleaning build artifacts ---"
	rm -rf $(PYTHON_DIR)/build $(PYTHON_DIR)/dist $(APP_ZIP_PATH)
	rm -rf $(FLUTTER_DIR)/build
	@echo "✓ Cleaned"
```

### `make notarize`

Notarize the macOS app for distribution (requires Apple Developer credentials):

```makefile
.PHONY: notarize
notarize:
	@echo "--- 🔐 Notarizing app for macOS Gatekeeper ---"
	xcrun notarytool submit \
	  "My Data Studio.app" \
	  --apple-id "$(APPLE_ID)" \
	  --team-id "$(APPLE_TEAM_ID)" \
	  --password "$(APPLE_PASSWORD)" \
	  --wait
	@echo "✓ Notarization complete"
```

**Prerequisites:**

```bash
export APPLE_ID="your-email@example.com"
export APPLE_PASSWORD="app-specific-password"  # NOT your account password
export APPLE_TEAM_ID="XXXXXXXXXX"              # From developer.apple.com
```

---

## Build Configuration

### Python (PyInstaller)

**Entry Point:** `aiserver/main.py`

Uvicorn starts on a random high port (e.g., 8001, 8002). The client scans stdout for the URL pattern and publishes it via `MainApp.llmServiceUrl`.

**Environment Variables (set by Flutter client):**

```bash
APP_SUPPORT_DIR=/Users/<user>/Library/Application Support/com.xdtlabs.mydatastudio
AICHAT_MODELS_DIR=$APP_SUPPORT_DIR/models
AISERVER_TOKEN=<per-launch bearer token>
```

**Dependencies:**

All dependencies listed in `aiserver/pyproject.toml`:

```toml
fastapi = "0.120.4"
uvicorn = "0.38.0"
llama-cpp-python = ">=0.3.31"
torch = "*"
transformers = ">=4.57.0"
langchain = "0.3.27"
pillow-heif = "0.22.0"
libpff-python = "*"
rawpy = "0.26.1"
# ... (30+ dependencies)
```

### Flutter (Build)

**Entry Point:** `client/lib/main.dart`

**Configuration:**

- **SDK:** Dart 3.12 (bundled with Flutter 3.44.8)
- **Target:** macOS 12.0 or later
- **Realm:** "dev" (development) or "prod" (production)

**Key Dependencies:**

```yaml
flutter:
  sdk: flutter
go_router: ^17.3.0          # Routing
rxdart: ^0.28.0             # State management
resqlite: ^0.7.0            # Database
resqlite_vector: ^0.1.0     # Vector storage
native_exif: ^0.8.0         # EXIF extraction
media_kit: ^1.2.6           # Video playback
flutter_map: ^8.3.1         # Maps
# ... (50+ dependencies)
```

---

## Platform-Specific Considerations

### macOS

**Signing & Notarization:**

```bash
# Manual signing (if needed)
codesign --force --deep --sign - "My Data Studio.app"

# Verify signature
codesign -v "My Data Studio.app"

# Check notarization status
spctl -a -v "My Data Studio.app"
```

**Entitlements:**

```xml
<!-- client/macos/Runner/Release.entitlements -->
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

Allows sandbox, file access, and local networking.

**Metal GPU Acceleration:**

PyInstaller automatically bundles Metal libraries on macOS. The `llama-cpp-python` library uses Metal for GPU acceleration via `n_gpu_layers=-1`.

### Windows (Planned)

```bash
# Install MSVC build tools
# Set Python environment
flutter build windows --release
```

### Linux (Planned)

```bash
flutter build linux --release
```

---

## Development Workflow

### Setup (First Time)

```bash
# 1. Clone repository
git clone https://github.com/XDT-Labs/mydatatools-desktop.git
cd mydatatools-desktop

# 2. Download models (one-time, ~10 GB)
make models

# 3. Build Python binary and install locally
make dev

# 4. Get Flutter dependencies
cd client
flutter pub get

# 5. Run with hot reload
flutter run -d macos
```

### Hot Reload

Flutter hot reload picks up Dart changes without restarting the app:

```bash
cd client
flutter run -d macos

# In IDE (VS Code / Android Studio), press 'r' to hot reload
# Press 'R' to hot restart (clears state)
```

**Limitations:**

- Hot reload doesn't update native code (Rust, Python)
- Hot reload doesn't update `main()` initialization
- For Python changes, stop the app and rebuild with `make build-python`

### Testing During Development

```bash
# Run Flutter tests
cd client && flutter test -k "photos"

# Run Python tests
cd aiserver && PYTHONPATH=src pdm run pytest tests/ -v

# Run integration test
cd client && flutter test test/integration/file_browser_integration_test.dart
```

---

## CI/CD (GitHub Actions)

GitHub Actions runs tests and builds on each push:

```yaml
# .github/workflows/build_and_release.yml

name: Build and Release

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.44.8
      
      - name: Flutter Tests
        run: cd client && flutter test
      
      - name: Python Tests
        run: |
          cd aiserver
          pdm install
          PYTHONPATH=src pdm run pytest

  build:
    needs: test
    runs-on: macos-latest
    if: startsWith(github.ref, 'refs/tags/')
    steps:
      - uses: actions/checkout@v3
      
      - name: Download Models
        run: make models
      
      - name: Build Python
        run: make build-python
      
      - name: Build Flutter
        run: make build-client
      
      - name: Sign & Notarize (if secrets available)
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: make notarize
      
      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            client/build/macos/Build/Products/Release/My Data Studio.app
```

---

## Distribution

### App Store

```bash
# 1. Notarize the app
make notarize

# 2. Create .dmg installer
hdiutil create -volname "My Data Studio" \
  -srcfolder "My Data Studio.app" \
  -ov -format UDZO "My Data Studio.dmg"

# 3. Upload to App Store Connect
xcrun altool --upload-app --file "My Data Studio.dmg" \
  --type macos --username "$APPLE_ID" --password "$APPLE_PASSWORD"
```

### Direct Distribution

```bash
# 1. Notarize the app
make notarize

# 2. Create .zip
zip -r "My Data Studio.zip" "My Data Studio.app"

# 3. Upload to website/GitHub
gh release upload <version> "My Data Studio.zip"
```

---

## Troubleshooting

### Model Download Fails

```bash
# Check connectivity to HuggingFace
curl -I https://huggingface.co

# Manual download
hf_hub_download --repo-id ggml-org/gemma-4-12B-it-GGUF \
  --filename gemma-4-12B-it-Q4_0.gguf \
  --local-dir ./aiserver/models

# Verify models exist
ls -lh aiserver/models/
```

### PyInstaller Build Fails

```bash
# Check Python version
python --version  # Should be 3.11–3.14

# Reinstall dependencies
cd aiserver
rm -rf .venv
pdm install

# Try build again
make build-python
```

### Flutter Build Fails

```bash
# Update Flutter
flutter upgrade

# Clean build
cd client
flutter clean
flutter pub get
flutter build macos --release

# Check for Xcode issues
xcrun simctl erase all
xcode-select --reset
```

### Hot Reload Not Working

```bash
# Restart Flutter
flutter run -d macos

# Or force full restart
flutter run -d macos --restart
```

---

## Performance Profiling

### Flutter Performance

```bash
# Build with profiling enabled
cd client
flutter build macos --profile

# Profile with DevTools
flutter run -d macos --profile
# Then open DevTools at http://localhost:9100
```

### Python Performance

```bash
# Profile with cProfile
python -m cProfile -o aiserver.prof aiserver/main.py

# Analyze profile
python -c "import pstats; p = pstats.Stats('aiserver.prof'); p.sort_stats('cumulative').print_stats(20)"
```

---

## Version Management

### Versioning Scheme

```
version: MAJOR.MINOR.PATCH+BUILD
```

Example: `1.0.0+2` (1.0.0 release, build 2)

**In `client/pubspec.yaml`:**

```yaml
version: 1.0.1+2
```

**In `aiserver/pyproject.toml`:**

```toml
version = "0.1.0"
```

### Tagging Releases

```bash
git tag v1.0.0
git push origin v1.0.0
# GitHub Actions automatically builds and releases
```

---

## Next Steps

- See [Flutter Client](./flutter-client.md) for app structure
- See [Python Service](./python-service.md) for aiserver details
- See [Testing](./testing.md) for CI/CD integration
