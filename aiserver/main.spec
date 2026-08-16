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
for pkg in ['llama_cpp', 'uvicorn', 'fastapi', 'langchain', 'langchain_community', 'langchain_core', 'langchain_google_genai', 'langchain_openai', 'langchain_anthropic', 'rawpy', 'pillow_heif']:
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

# pdfium IS bundled, unlike the models below, and the asymmetry is the point.
# It is 3.4 MB, and it cannot be a runtime download the way models are: the
# only downloader available is docling's, which serves a Linux x86-64 build on
# macOS and reports success (search plan §18d-1). `make pdfium` vendors it and
# verifies the Mach-O header; this copies it in. The Makefile's signing pass
# picks it up with every other Mach-O file in dist/.
_pdfium = os.path.join(os.path.dirname(os.path.abspath(SPEC)), 'vendor', 'pdfium', 'lib', 'libpdfium.dylib')
if os.path.exists(_pdfium):
    binaries += [(_pdfium, 'vendor/pdfium/lib')]
    print(f"  - Bundling pdfium from {_pdfium}")
else:
    print("Warning: vendor/pdfium/lib/libpdfium.dylib missing — PDF extraction "
          "will be disabled in this build. Run `make pdfium`.")

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
