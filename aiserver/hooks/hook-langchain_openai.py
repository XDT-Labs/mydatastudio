"""
PyInstaller hook for langchain_openai package.

This hook ensures that all necessary modules and data files from
langchain_openai are included in the PyInstaller bundle.
"""
from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata

# Collect all submodules
hiddenimports = collect_submodules('langchain_openai')

# Collect all data files and binaries
datas, binaries, more_hiddenimports = collect_all('langchain_openai')

# Merge hidden imports
hiddenimports += more_hiddenimports

# Also ensure the openai SDK is included
hiddenimports += collect_submodules('openai')

# Copy metadata (important for version checks and entry points)
datas += copy_metadata('langchain_openai')
