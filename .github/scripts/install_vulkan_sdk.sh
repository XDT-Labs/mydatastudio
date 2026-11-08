#!/usr/bin/env bash
# Installs LunarG's Vulkan SDK (headers, loader, glslc, SPIRV-Headers), which
# llama.cpp's Vulkan backend needs to build, and exports VULKAN_SDK,
# CMAKE_PREFIX_PATH and PATH to the job's later steps. main.spec reads
# VULKAN_SDK to bundle the Vulkan loader.
#
# Linux x86_64 and Windows x64 only: LunarG publishes no Linux arm64 SDK.
#
# Usage (GitHub Actions, bash): install_vulkan_sdk.sh
set -euo pipefail

version=1.4.363.1

case "$(uname -s)" in
  Linux)
    dest="$RUNNER_TEMP/vulkan-sdk"
    mkdir -p "$dest"
    curl -fsSL --retry 3 \
      "https://sdk.lunarg.com/sdk/download/$version/linux/vulkansdk-linux-x86_64-$version.tar.xz" |
      tar -xJ -C "$dest"
    sdk="$dest/$version/x86_64"
    glslc="$sdk/bin/glslc"
    ;;
  MINGW* | MSYS*)
    installer="$RUNNER_TEMP/vulkansdk.exe"
    curl -fsSL --retry 3 -o "$installer" \
      "https://sdk.lunarg.com/sdk/download/$version/windows/vulkansdk-windows-X64-$version.exe"
    sdk="C:\\VulkanSDK\\$version"
    "$installer" --root "$sdk" --accept-licenses --default-answer --confirm-command install
    glslc="$(cygpath -u "$sdk")/Bin/glslc.exe"
    ;;
  *)
    echo "Error: no Vulkan SDK for $(uname -s)"
    exit 1
    ;;
esac

[ -x "$glslc" ] || { echo "Error: glslc is not at $glslc"; exit 1; }
"$glslc" --version | head -1

{
  echo "VULKAN_SDK=$sdk"
  # So CMake's find_package(SPIRV-Headers CONFIG) finds the SDK's copy.
  echo "CMAKE_PREFIX_PATH=$sdk"
} >> "$GITHUB_ENV"
dirname "$glslc" >> "$GITHUB_PATH"
