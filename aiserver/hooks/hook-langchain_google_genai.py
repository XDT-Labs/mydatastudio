"""
PyInstaller hook for langchain_google_genai package.

This hook ensures that all necessary modules and data files from
langchain_google_genai are included in the PyInstaller bundle.
"""
from PyInstaller.utils.hooks import collect_all, collect_submodules

# Collect all submodules
hiddenimports = collect_submodules('langchain_google_genai')

# Collect all data files and binaries
datas, binaries, more_hiddenimports = collect_all('langchain_google_genai')

# Merge hidden imports
hiddenimports += more_hiddenimports

# Also ensure google dependencies are included
hiddenimports += collect_submodules('google.ai.generativelanguage')
hiddenimports += collect_submodules('google.generativeai')

# Copy metadata (important for version checks and entry points)
from PyInstaller.utils.hooks import copy_metadata
datas += copy_metadata('langchain_google_genai')
