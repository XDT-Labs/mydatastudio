"""
PyInstaller hook for langchain_anthropic package.

This hook ensures that all necessary modules and data files from
langchain_anthropic are included in the PyInstaller bundle.
"""
from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata

# Collect all submodules
hiddenimports = collect_submodules('langchain_anthropic')

# Collect all data files and binaries
datas, binaries, more_hiddenimports = collect_all('langchain_anthropic')

# Merge hidden imports
hiddenimports += more_hiddenimports

# Also ensure the anthropic SDK is included
hiddenimports += collect_submodules('anthropic')

# Copy metadata (important for version checks and entry points)
datas += copy_metadata('langchain_anthropic')
