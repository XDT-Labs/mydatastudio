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
for pkg in ['llama_cpp', 'uvicorn', 'fastapi', 'langchain', 'langchain_community', 'langchain_core', 'langchain_google_genai']:
    try:
        print(f"Collecting {pkg}...")
        tmp_ret = collect_all(pkg)
        print(f"  - Found {len(tmp_ret[0])} data files, {len(tmp_ret[1])} binaries, {len(tmp_ret[2])} hidden imports")
        datas += tmp_ret[0]
        binaries += tmp_ret[1]
        hiddenimports += tmp_ret[2]
    except Exception as e:
        print(f"Warning: Failed to collect all from {pkg}: {e}")

try:
    datas += copy_metadata('langchain_google_genai')
except Exception as e:
    print(f"Warning: Failed to copy metadata for langchain_google_genai: {e}")

# Include the pre-downloaded GGUF models directory mapping to the bundle root
datas.append(('models/*', 'models'))


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
    name='aichat',
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
    name='aichat',
)
