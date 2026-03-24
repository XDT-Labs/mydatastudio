# ==============================================================================
# Makefile for mydatatools-desktop
#
# Usage:
#   make all            - Build everything (models, python, client)
#   make models         - Download GGUF models from Hugging Face
#   make build-python   - Build and zip the Python aichat service
#   make build-client   - Build the Flutter Desktop client (macOS release)
#   make clean          - Remove all build artifacts
# ==============================================================================

# --- Variables ---
PROJECT_ID = mydata-tools
REGION = us-central1
SERVICE_NAME = gcs-file-downloader
IMAGE_REPO = cloud-run-source-deploy

# Python/AI Chat Config
PYTHON_DIR = client/assets/python/aichat
APP_DIR = client/app
APP_ZIP_NAME = aichat-macos.zip
APP_ZIP_PATH = $(APP_DIR)/$(APP_ZIP_NAME)
HF_MODEL = bartowski/google_gemma-3-4b-it-GGUF
HF_FILE = google_gemma-3-4b-it-Q4_K_M.gguf
HF_SIGLIP_MODEL = google/siglip2-so400m-patch16-naflex
HF_SIGLIP_DIR = $(PYTHON_DIR)/models/siglip2


# Flutter Config
FLUTTER_DIR = client
# Default realm name, overridden in set-bundle-id
REALM_NAME = mydata.tools

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
		mkdir -p ../../../app && \
		rm -f ../../../app/$(APP_ZIP_NAME) && \
		cd dist/aichat && \
		zip -r ../../../../../app/$(APP_ZIP_NAME) .
	@echo "--- ✅ Python build complete: $(APP_ZIP_PATH) ---"

.PHONY: set-bundle-id
set-bundle-id:
	@echo "--- 🆔 Setting Bundle ID for macOS ---"
	@BRANCH=$$(git branch --show-current); \
	if [ "$$BRANCH" = "develop" ]; then \
		echo "Detected branch: develop. Using Bundle ID: mydata.tools.dev"; \
		sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = mydata.tools.dev/' client/macos/Runner/Configs/AppInfo.xcconfig; \
		echo "REALM_NAME=mydata.tools.dev" > .realm_name; \
	else \
		echo "Detected branch: $$BRANCH. Using Bundle ID: mydata.tools"; \
		sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = mydata.tools/' client/macos/Runner/Configs/AppInfo.xcconfig; \
		echo "REALM_NAME=mydata.tools" > .realm_name; \
	fi

# 3. Build Flutter Desktop Client
.PHONY: build-client
build-client: set-bundle-id
	@echo "--- 🚀 Building Flutter Desktop client (macOS) ---"
	@REALM=$$(cat .realm_name | cut -d= -f2); \
	cd $(FLUTTER_DIR) && \
		flutter pub get && \
		flutter build macos --release --no-tree-shake-icons --dart-define=REALM_NAME=$$REALM
	@echo "--- ✅ Flutter build complete ---"

# Local Install (Testing)
.PHONY: local-install-python
local-install-python: build-python
	@echo "--- 💾 Installing service for local testing ---"
	@REALM=$$(cat .realm_name | cut -d= -f2 || echo "mydata.tools"); \
	mkdir -p ~/Library/Application\ Support/$$REALM/ && \
	cp $(APP_ZIP_PATH) ~/Library/Application\ Support/$$REALM/ && \
	rm -fr ~/Library/Application\ Support/$$REALM/aichat
	@echo "--- ✅ Copy complete ---"

# Cloud Run Deployment
.PHONY: deploy-download-service
deploy-download-service: init
	@echo "--- 🚀 Deploying $(SERVICE_NAME) to Cloud Run ---"
	cd services/download-models && gcloud builds submit . \
		--config cloudbuild.yaml \
		--region=$(REGION) \
		--substitutions _SERVICE_NAME=$(SERVICE_NAME),_REGION=$(REGION),_GCS_BUCKET=mydata-tools_downloads,_GCS_FOLDER_PREFIX=local-llm-models/,_REPO_NAME=$(IMAGE_REPO)


# Cleanup
.PHONY: clean
clean:
	@echo "--- 🧹 Cleaning up build artifacts ---"
	rm -rf $(PYTHON_DIR)/build $(PYTHON_DIR)/dist $(PYTHON_DIR)/models
	rm -f $(APP_ZIP_PATH)
	cd $(FLUTTER_DIR) && flutter clean
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -exec rm -rf {} +
	@echo "--- 🧼 Restoring default Bundle ID ---"
	@sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = mydata.tools.dev/PRODUCT_BUNDLE_IDENTIFIER = mydata.tools/' client/macos/Runner/Configs/AppInfo.xcconfig
	@rm -f .realm_name
	@echo "--- ✅ Clean complete ---"
