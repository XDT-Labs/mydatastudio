# Building & Operations

This guide covers building MyDataStudio for development and release, running tests, and deployment procedures.

## Build Orchestration with Makefile

All build tasks are orchestrated through the **root Makefile**. Use `make <target>` to run any of the following:

### Main Targets

#### Development Workflow

```bash
make models
# Download GGUF models from Hugging Face (one-time, several GB)
# Installs:
#   - gemma-4-12B-it-Q4_0.gguf (7.2 GB)
#   - mmproj-gemma-4-12B-it-Q8_0.gguf (vision projector, ~1 GB)
#   - Qwen3-VL-Embedding-2B (transformers snapshot, ~2 GB)

make dev
# 1. Build Python binary via PyInstaller (Metal GPU enabled)
# 2. Codesign the binary
# 3. Install to ~/Library/Application Support/<bundle-id>/aiserver/

cd client && flutter pub get && flutter run -d macos
# Run Flutter client with hot reload
# Client will find the locally-installed aiserver binary
```

#### Release Build

```bash
make all
# 1. Build Python binary (PyInstaller, Metal-enabled)
# 2. Codesign the binary
# 3. Build Flutter macOS release bundle
# 4. Bundle Python binary inside the Flutter app
# Result: client/build/macos/Build/Products/Release/mydatastudio.app
```

#### Individual Builds

```bash
make build-python
# Only build the Python binary (PyInstaller)
# Result: aiserver/dist/aiserver

make build-client
# Only build Flutter macOS release
# NOTE: Requires `make build-python local-install-python` first
# Result: client/build/macos/Build/Products/Release/mydatastudio.app

make clean
# Remove all build artifacts (aiserver/dist/, client/build/, etc.)

make notarize
# Notarize the release app for macOS distribution
# Requires: APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID env vars
```

### Makefile Variables & Configuration

Key configuration in the Makefile:

```makefile
HF_MODEL = ggml-org/gemma-4-12B-it-GGUF
HF_FILE = gemma-4-12B-it-Q4_0.gguf
HF_QWEN3_VL_MODEL = Qwen/Qwen3-VL-Embedding-2B

APPLE_ID = mike@xdtlabs.com
APPLE_TEAM_ID = TTM6V47DL9
```

For a custom build, override these variables:

```bash
make models HF_MODEL=my/custom/model
```

## Python Service Build

### Development

```bash
cd aiserver
pdm install                    # Install dependencies
python main.py                 # Run dev server (Uvicorn on random port)
```

The dev server outputs something like:
```
Uvicorn running on http://127.0.0.1:8000
```

Set `PYTHON_SERVER_URL=http://127.0.0.1:8000` in Flutter env to point at this server instead of spawning one.

### PyInstaller Build

```bash
cd aiserver
pdm install
FORCE_CMAKE=1 CMAKE_ARGS="-DGGML_METAL=on -DGGML_NATIVE=off" pdm run pyinstaller -y main.spec
```

Key points:

- **Metal GPU**: `-DGGML_METAL=on` enables Metal acceleration for GGUF inference
- **`main.spec`**: PyInstaller config file (defines entrypoint, hooks, hidden imports)
- **Result**: `aiserver/dist/aiserver` (standalone binary)

### Build Output

After PyInstaller:

```
aiserver/
  dist/
    aiserver           # Standalone executable
    aiserver.spec      # PyInstaller spec (metadata)
```

### Code Signing (macOS)

The Makefile automatically signs the binary:

```bash
# Find developer identity
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

# Sign the binary
codesign --force --verify --verbose --sign "$IDENTITY" aiserver/dist/aiserver
```

If the identity is not found, set `CODESIGN_IDENTITY` env var:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)"
make build-python
```

## Flutter Client Build

### Development with Hot Reload

```bash
cd client
flutter pub get                      # Install dependencies
flutter run -d macos                 # Hot reload dev build
```

Hot reload allows you to edit Dart code and see changes instantly without rebuilding.

### Flutter Tests

```bash
cd client
flutter test                         # Run all tests
flutter test test/path/to/file_test.dart  # Run specific test file
```

Test files are in `/client/test/` organized by module:

```
test/
  modules/email/
  modules/files/
  modules/photos/
  repositories/
  scanners/
  services/
  oauth/
  // ... 100+ test files
```

### Flutter Release Build

```bash
cd client
flutter build macos --release --no-tree-shake-icons
```

Output: `client/build/macos/Build/Products/Release/mydatastudio.app`

**Important**: The release app needs the Python binary bundled inside it. See [App Bundling](#app-bundling) below.

#### Build Variants

The Makefile uses different pubspec files for dev vs. prod:

```
client/
  pubspec.yaml        # Development (local assets)
  pubspec.dev.yaml    # Development variant (same)
  pubspec.prod.yaml   # Release variant (bundled Python)
```

For release, the build script swaps in `pubspec.prod.yaml`:

```bash
cp client/pubspec.prod.yaml client/pubspec.yaml
flutter build macos --release --no-tree-shake-icons
# ... then restore
cp client/pubspec.dev.yaml client/pubspec.yaml
```

## App Bundling

### Structure

A release `.app` contains:

```
mydatastudio.app/
  Contents/
    MacOS/
      mydatastudio       # Flutter binary
    Frameworks/
      App.framework/     # Flutter engine
    Resources/
      AppDelegate        # macOS app delegate
    Helpers/
      aiserver           # Python binary (bundled here)
      models/
        gemma-4-12B-it-Q4_0.gguf
        mmproj-...gguf
        Qwen3-VL-Embedding-2B/
    Info.plist
```

### Bundle Python Binary

The Makefile copies the Python binary into the app:

```bash
make build-python                     # Build Python binary
cp aiserver/dist/aiserver client/app/aiserver  # Copy to Flutter bundle location
make build-client                     # Build Flutter with bundled Python
```

When the app launches, `PythonManager` finds the bundled `aiserver` binary and spawns it.

### Custom Model Bundling

To include custom GGUF models in the release:

1. Place `.gguf` files in `aiserver/models/`
2. Update Makefile `HF_FILE` variable
3. Build as normal (models are included in the bundle)

## Python Service Testing

```bash
cd aiserver
pdm install
PYTHONPATH=src pdm run pytest                    # Run all tests
PYTHONPATH=src pdm run pytest tests/test_routes.py -v  # Specific file
PYTHONPATH=src pdm run pytest -k "test_chat_completion"  # Specific test
```

Test structure:

```
aiserver/
  tests/
    test_auth.py               # Bearer token auth
    test_model_manager.py      # Model loading & inference
    test_routes.py             # HTTP endpoints
    test_pst_parser.py         # Outlook PST parsing
    test_thumbnail.py          # Image thumbnail generation
    test_utils.py              # Helper utilities
    conftest.py                # pytest fixtures
  src/aichat/
    tests/
      test_pst_parser.py       # Additional PST tests
```

### Running Specific Test Categories

```bash
# Auth tests
PYTHONPATH=src pdm run pytest tests/test_auth.py -v

# Model loading
PYTHONPATH=src pdm run pytest tests/test_model_manager.py -v

# HTTP routes
PYTHONPATH=src pdm run pytest tests/test_routes.py -v
```

## Code Signing & Notarization

### Prerequisites

You need:

- **Apple Developer Account**
- **Developer ID Application certificate** (installed in Keychain)
- **App-specific password** (if using 2FA)

Generate an app-specific password:

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Security → App-specific passwords → Generate
3. Set to env var: `export APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx`

### Signing During Build

The Makefile signs during `make build-python`:

```bash
codesign --force --verify --verbose --sign "$IDENTITY" aiserver/dist/aiserver
```

And during `make notarize`:

```bash
codesign --force --verify --verbose --options runtime \
  --sign "$IDENTITY" client/build/macos/Build/Products/Release/mydatastudio.app
```

### Notarization

Notarize with Apple to avoid "unidentified developer" warnings:

```bash
export APPLE_ID=your-email@example.com
export APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx
export APPLE_TEAM_ID=XXXXXXXXXX
make notarize
```

This:

1. Signs the `.app` with `--options runtime` (hardened runtime required for notarization)
2. Uploads to Apple's notarization service
3. Waits for approval (usually 5–10 minutes)
4. Staples the notarization ticket to the `.app`

Result: The app can be distributed to end users without Gatekeeper warnings.

### Troubleshooting Notarization

**"Invalid signature"**

- Ensure all binaries inside the `.app` are signed with the same identity
- Check frameworks and helper binaries: `codesign -v --deep path/to/mydatastudio.app`

**"Notarization failed: timestamp server"**

- Ensure the signing timestamp server is reachable (requires internet)
- Retry after a few minutes

**"Stapling failed"**

- Ensure the app is notarized before stapling
- The notarization service may still be processing; wait a few minutes and retry

## Development Workflows

### Adding a Python Dependency

```bash
cd aiserver
pdm add <package-name>    # Adds to pyproject.toml + updates pdm.lock
pdm install               # Installs the new dependency
# Edit src/aichat/main.py or routes.py to use it
PYTHONPATH=src pdm run pytest tests/  # Test
make build-python         # Rebuild binary (includes new dependency)
```

### Adding a Flutter Dependency

```bash
cd client
flutter pub add <package-name>  # Adds to pubspec.yaml
flutter pub get                 # Resolves dependencies
# Edit lib/main.dart or other files to use it
flutter test                    # Test
make build-client               # Rebuild
```

### Debugging the Python Service

The Python service logs to stderr. When running dev server:

```bash
cd aiserver
python main.py 2>&1 | tee /tmp/aiserver.log
```

When running from the bundled app, logs go to:

```
~/Library/Logs/mydatastudio.log
```

### Environment Variables for Development

```bash
# Point Flutter at local dev server instead of spawning one
export PYTHON_SERVER_URL=http://127.0.0.1:8000

# Verbose logging
export RUST_LOG=debug
export AISERVER_VERBOSE=true

# Custom app support directory (for testing)
export APP_SUPPORT_DIR=/tmp/test-app-support

# Code signing identity
export CODESIGN_IDENTITY="Developer ID Application: Your Name (ID)"
```

## Performance Profiling

### Flutter Profiling

```bash
flutter run --profile -d macos
# Open DevTools in browser for performance analysis
```

### Python Service Profiling

```bash
cd aiserver
python -m cProfile -s cumtime main.py 2>&1 | head -50
```

### Memory Profiling

```bash
cd aiserver
pip install memory-profiler
python -m memory_profiler main.py
```

## Troubleshooting Build Issues

### "Python binary not found"

Ensure `make build-python` completed successfully:

```bash
ls -la aiserver/dist/aiserver
```

### "Flutter build failed: missing dependency"

```bash
cd client
flutter pub get
flutter clean
flutter pub get
flutter build macos --release
```

### "Code signing failed"

Check that your certificate is valid:

```bash
security find-identity -v -p codesigning
```

If not found, install a Developer ID Application certificate from Apple Developer.

### "Notarization timeout"

Apple's notarization service can be slow. Retry:

```bash
make notarize
```

If it still fails, check the notarization log:

```bash
xcrun altool --notarization-history <history-id>
```

## CI/CD (GitHub Actions)

The project includes GitHub Actions workflows (`.github/workflows/`):

- `build_and_release.yml` — Builds on every push, notarizes on release tags
- `build_python.yml` — Builds Python service (for testing)

These workflows run `make` targets in a CI environment.

### Running Locally

To test CI workflows locally, use [**act**](https://github.com/nektos/act):

```bash
brew install act
act -j build  # Simulate GitHub Actions
```

## Next Steps

- **[Testing Guide](./testing.md)** — Comprehensive test strategy
- **[Database Design](../architecture/database.md)** — Schema & migrations
- **[Isolates & Write Relay](../architecture/isolates.md)** — Consistency pattern

## Source References

- **Makefile**: `/Makefile`
- **PyInstaller Config**: `/aiserver/main.spec`
- **Flutter Build Config**: `/client/pubspec.yaml`, `/client/pubspec.prod.yaml`
- **GitHub Actions**: `/.github/workflows/`
- **Python Service**: `/aiserver/src/aichat/`
- **Flutter Client**: `/client/lib/`
