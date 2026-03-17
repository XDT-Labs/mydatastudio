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
HF_EMBEDDING_MODEL = Qwen/Qwen3-VL-Embedding-2B
HF_EMBEDDING_DIR = $(PYTHON_DIR)/models/$(HF_EMBEDDING_MODEL)

# Flutter Config
FLUTTER_DIR = client

# --- Targets ---

.PHONY: all
all: models build-python local-install-python build-client

# Project Initialization
.PHONY: init
init:
	@echo "--- 🛠️ Setting gcloud project ID to $(PROJECT_ID) ---"
	gcloud auth application-default set-quota-project $(PROJECT_ID)
	gcloud config set project $(PROJECT_ID)
	@echo "Project configuration complete."

# 1. Download GGUF Models
.PHONY: models
models:
	@echo "--- 📥 Checking/Downloading GGUF models ---"
	@mkdir -p $(PYTHON_DIR)/models
	@if [ ! -f $(PYTHON_DIR)/models/$(HF_FILE) ]; then \
		echo "Downloading $(HF_FILE)..."; \
		hf download $(HF_MODEL) $(HF_FILE) --local-dir $(PYTHON_DIR)/models; \
	else \
		echo "$(HF_FILE) already exists, skipping download."; \
	fi
	@if [ ! -d $(HF_EMBEDDING_DIR) ]; then \
		echo "Downloading Qwen-VL embedding model (Transformers)..."; \
		hf download $(HF_EMBEDDING_MODEL) --local-dir $(HF_EMBEDDING_DIR); \
	else \
		echo "Qwen-VL embedding model already exists, skipping download."; \
	fi


# 2. Build Python Service
.PHONY: build-python
build-python:
	@echo "--- 🐍 Building Python aichat service ---"
	@cd $(PYTHON_DIR) && \
		pdm install && \
		FORCE_CMAKE=1 CMAKE_ARGS="-DGGML_METAL=on -DGGML_NATIVE=off" pdm run pyinstaller -y main.spec && \
		mkdir -p ../../../app && \
		cd dist/aichat && \
		zip -r ../../../../../app/$(APP_ZIP_NAME) .
	@echo "--- ✅ Python build complete: $(APP_ZIP_PATH) ---"

# 3. Build Flutter Desktop Client
.PHONY: build-client
build-client:
	@echo "--- 🚀 Building Flutter Desktop client (macOS) ---"
	@cd $(FLUTTER_DIR) && \
		flutter pub get && \
		flutter build macos --release --no-tree-shake-icons
	@echo "--- ✅ Flutter build complete ---"

# Local Install (Testing)
.PHONY: local-install-python
local-install-python: build-python
	@echo "--- 💾 Installing service for local testing ---"
	@mkdir -p ~/Library/Application\ Support/mydata.tools/
	cp $(APP_ZIP_PATH) ~/Library/Application\ Support/mydata.tools/
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
