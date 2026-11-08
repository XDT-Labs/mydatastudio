# -*- mode: python ; coding: utf-8 -*-
import os
from PyInstaller.utils.hooks import collect_all, copy_metadata

datas = []
binaries = []
hiddenimports = [
    'uvicorn.logging',
    'uvicorn.loops',
    'uvicorn.loops.auto',
    'uvicorn.protocols',
    'uvicorn.protocols.http',
    'uvicorn.protocols.http.auto',
    'uvicorn.protocols.websockets',
    'uvicorn.protocols.websockets.auto',
    'uvicorn.lifespan.on',
    'uvicorn.lifespan.off',
    'fastapi',
    'pydantic',
    'starlette',
    'aichat.model_manager',
    # langchain_community transitively imports transformers, which lazily
    # imports sklearn.metrics.roc_curve — must be bundled explicitly.
    'sklearn.metrics._ranking',
    'sklearn.metrics._classification',
    'sklearn.metrics._regression',
    'sklearn.utils._typedefs',
]

# Collect all for complex packages
# torchvision is here for its native ops (_C_stable): the contrib hook still asks
# for the pre-0.29 name `_C`, so without this they are silently left out and
# importing transformers fails in the frozen app.
for pkg in ['llama_cpp', 'uvicorn', 'fastapi', 'langchain', 'langchain_community', 'langchain_core', 'langchain_google_genai', 'langchain_openai', 'langchain_anthropic', 'rawpy', 'pillow_heif', 'sentence_transformers', 'torchvision']:
    try:
        print(f"Collecting {pkg}...")
        tmp_ret = collect_all(pkg)
        print(f"  - Found {len(tmp_ret[0])} data files, {len(tmp_ret[1])} binaries, {len(tmp_ret[2])} hidden imports")
        datas += tmp_ret[0]
        binaries += tmp_ret[1]
        hiddenimports += tmp_ret[2]
    except Exception as e:
        print(f"Warning: Failed to collect all from {pkg}: {e}")

for pkg in ['langchain_google_genai', 'langchain_openai', 'langchain_anthropic']:
    try:
        datas += copy_metadata(pkg)
    except Exception as e:
        print(f"Warning: Failed to copy metadata for {pkg}: {e}")

# When llama.cpp is built with Vulkan (Windows, Linux x64), bundle the Vulkan
# loader next to ggml-vulkan. Without it, a machine with no GPU driver can't
# load llama.cpp at all; with it, llama.cpp finds no device and uses the CPU.
# GPU drivers are found by the loader, so they are never bundled.
import sys
# macOS uses Metal; a Mac with LunarG's SDK installed sets VULKAN_SDK too.
vulkan_sdk = os.environ.get('VULKAN_SDK') if sys.platform != 'darwin' else None
if vulkan_sdk:
    if sys.platform == 'win32':
        candidates = [os.path.join(vulkan_sdk, 'Bin', 'vulkan-1.dll'),
                      os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'vulkan-1.dll')]
    else:
        # LunarG's Linux SDK keeps the loader under lib/VulkanLoader/lib.
        candidates = [os.path.join(vulkan_sdk, 'lib', 'VulkanLoader', 'lib', 'libvulkan.so.1'),
                      os.path.join(vulkan_sdk, 'lib', 'libvulkan.so.1')]
    loader = next((c for c in candidates if os.path.isfile(c)), None)
    if loader is None:
        raise SystemExit(f"VULKAN_SDK is set but no Vulkan loader was found in {candidates}")
    print(f"Bundling the Vulkan loader: {loader}")
    binaries.append((loader, os.path.join('llama_cpp', 'lib')))

# Models are deliberately NOT bundled. They live beside the extracted server
# (Application Support/models, via AICHAT_MODELS_DIR) so that re-extracting
# aiserver/ on an app upgrade leaves the multi-gigabyte downloads untouched.
# Bundling them here also meant a local `make models` before `make build-python`
# silently produced a multi-gigabyte zip.


a = Analysis(
    ['main.py'],
    pathex=['.', 'src'],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports + [
        'google.generativeai',
        'google.ai.generativelanguage',
        'google.ai.generativelanguage_v1beta',
    ],
    hookspath=['hooks'],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='aiserver',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='aiserver',
)
