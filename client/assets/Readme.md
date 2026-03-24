## Build

PDM is simply a package manager (like Node's NPM) that installs Python dependencies. Zipping the PDM project folder only zips raw source code; it **does not** create an executable.

To create the standalone `aichat` executable that your Flutter app expects to run, you must compile the code using `PyInstaller`.
```bash
cd client/assets/python/aichat

# 1. Install dependencies
pdm install

# 2. Download the default GGUF model manually
# This is required so the model is bundled in the final zip via main.spec
hf download bartowski/google_gemma-3-4b-it-GGUF google_gemma-3-4b-it-Q4_K_M.gguf --local-dir models

# 3. Compile the executable
pdm run pyinstaller -y main.spec

# 3. Zip the compiled output for Flutter
cd dist/aichat
zip -r ../../../../../app/aichat-macos.zip .
cd ../../../../../app/

# 4. Copy to your application support directory to test locally
cp ./*.zip ~/Library/Application\ Support/mydata.tools/
```

## All in one
```
clear && cd client/assets/python/aichat && pdm install && pdm run pyinstaller -y main.spec && cd dist/aichat && zip -r ../../../../../app/aichat-macos.zip . && cd ../../../../../app/ && cp ./*.zip ~/Library/Application\ Support/mydata.tools/ && cd ../..
```


### Find open port
```bash
python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
```
    