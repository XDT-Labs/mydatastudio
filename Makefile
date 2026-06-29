# ==============================================================================
# Makefile for mydatastudio-desktop
#
# Usage:
#   make all            - Build everything (models, python, client)
#   make models         - Download GGUF models from Hugging Face
#   make build-python   - Build and zip the Python aichat service
#   make build-client   - Build the Flutter Desktop client (macOS release)
#   make clean          - Remove all build artifacts
# ==============================================================================

# --- Variables ---
PROJECT_ID = mydata-studio
REGION = us-central1
SERVICE_NAME = gcs-file-downloader
IMAGE_REPO = cloud-run-source-deploy

# Python/AI Chat Config
PYTHON_DIR = aiserver
APP_DIR = client/app
APP_ZIP_NAME = aiserver-macos.zip
APP_ZIP_PATH = $(APP_DIR)/$(APP_ZIP_NAME)
HF_MODEL = ggml-org/gemma-4-12B-it-GGUF
HF_FILE = gemma-4-12B-it-Q4_K_M.gguf
HF_MMPROJ_FILE = mmproj-gemma-4-12B-it-Q8_0.gguf
HF_SIGLIP_MODEL = google/siglip2-so400m-patch16-naflex
HF_SIGLIP_DIR = $(PYTHON_DIR)/models/siglip2



# Flutter Config
FLUTTER_DIR = client


# --- Targets ---

.PHONY: all
all: models build-python local-install-python build-client

.PHONY: dev
dev: models build-python local-install-python

# Project Initialization
.PHONY: init
init:
	@echo "--- 🛠️ Setting gcloud project ID to $(PROJECT_ID) ---"
	gcloud auth application-default set-quota-project $(PROJECT_ID)
	gcloud config set project $(PROJECT_ID)
	@echo "Project configuration complete."

# 1. Download Models
.PHONY: models
models:
	@echo "--- 📥 Checking/Downloading models ---"
	@mkdir -p $(PYTHON_DIR)/models
	@if [ ! -f $(PYTHON_DIR)/models/$(HF_FILE) ]; then \
		echo "Downloading $(HF_FILE)..."; \
		hf download $(HF_MODEL) $(HF_FILE) --local-dir $(PYTHON_DIR)/models; \
	else \
		echo "$(HF_FILE) already exists, skipping download."; \
	fi
	@if [ ! -f $(PYTHON_DIR)/models/$(HF_MMPROJ_FILE) ]; then \
		echo "Downloading $(HF_MMPROJ_FILE) (vision projector)..."; \
		hf download $(HF_MODEL) $(HF_MMPROJ_FILE) --local-dir $(PYTHON_DIR)/models; \
	else \
		echo "$(HF_MMPROJ_FILE) already exists, skipping download."; \
	fi
	@if [ ! -d $(HF_SIGLIP_DIR) ]; then \
		echo "Downloading SigLip 2 embedding model (Transformers)..."; \
		hf download $(HF_SIGLIP_MODEL) --local-dir $(HF_SIGLIP_DIR); \
	else \
		echo "SigLip 2 embedding model already exists, skipping download."; \
	fi

	


# 2. Build Python Service
.PHONY: build-python
build-python:
	@echo "--- 🐍 Building Python aichat service ---"
	@cd $(PYTHON_DIR) && \
		pdm install && \
		FORCE_CMAKE=1 CMAKE_ARGS="-DGGML_METAL=on -DGGML_NATIVE=off" pdm run pyinstaller -y main.spec && \
		mkdir -p ../client/app && \
		rm -f ../client/app/$(APP_ZIP_NAME) && \
		cd dist/aichat && \
		zip -r ../../../client/app/$(APP_ZIP_NAME) .
	@echo "--- ✅ Python build complete: $(APP_ZIP_PATH) ---"

# 3. Build Flutter Desktop Client
.PHONY: build-client
build-client:
	@echo "--- 🚀 Building Flutter Desktop client (macOS) ---"
	@REALM=$$(cat .realm_name 2>/dev/null | cut -d= -f2 || echo "com.xdtlabs.mydatastudio"); \
	cd $(FLUTTER_DIR) && \
		cp pubspec.prod.yaml pubspec.yaml && \
		flutter pub get && \
		flutter build macos --release --no-tree-shake-icons --dart-define=REALM_NAME=$$REALM
	@echo "--- ✅ Flutter build complete ---"
	@BRANCH=$$(git branch --show-current); \
	if [ "$$BRANCH" = "main" ] && [ -z "$$CI" ]; then \
		echo "--- 🚀 Copy release build to Applications folder ---"; \
		cp -r $(FLUTTER_DIR)/build/macos/Build/Products/Release/MyDataStudio.app /Applications/MyDataStudio.app; \
	fi

# Local Install (Testing)
.PHONY: local-install-python
local-install-python: build-python
	@echo "--- 💾 Installing service for local testing ---"
	@for REALM in com.xdtlabs.mydatastudio.dev com.xdtlabs.mydatastudio; do \
		echo "Installing to realm: $$REALM"; \
		mkdir -p ~/Library/Application\ Support/$$REALM/ && \
		cp $(APP_ZIP_PATH) ~/Library/Application\ Support/$$REALM/ && \
		rm -fr ~/Library/Application\ Support/$$REALM/aichat; \
	done
	@echo "--- ✅ Copy complete ---"



# Cleanup
.PHONY: clean
clean:
	@echo "--- 🧹 Cleaning up build artifacts ---"
	rm -rf $(PYTHON_DIR)/build $(PYTHON_DIR)/dist $(PYTHON_DIR)/models
	rm -f $(APP_ZIP_PATH)
	cd $(FLUTTER_DIR) && flutter clean
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -exec rm -rf {} +
	@echo "--- ✅ Clean complete ---"

