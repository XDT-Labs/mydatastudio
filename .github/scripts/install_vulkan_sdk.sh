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
# Pinned SHA-256s, matching LunarG's published ones
# (https://sdk.lunarg.com/sdk/sha/<version>/<os>/<file>.txt). Update them with
# the version.
linux_sha256=b7867d8ca658563813af666f34b93db87f1b1c7d9d69d97e924c210c7ba33eb8
windows_sha256=c02932bd9a968b22d404536108adaacac908c081cd6b0113f5bfefc523dd0a6a

# Downloads $1 to $2 and fails unless it has SHA-256 $3.
fetch() {
  curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c -
}

case "$(uname -s)" in
  Linux)
    archive="$RUNNER_TEMP/vulkansdk.tar.xz"
    fetch "https://sdk.lunarg.com/sdk/download/$version/linux/vulkansdk-linux-x86_64-$version.tar.xz" \
      "$archive" "$linux_sha256"
    dest="$RUNNER_TEMP/vulkan-sdk"
    mkdir -p "$dest"
    tar -xJf "$archive" -C "$dest"
    rm "$archive"
    sdk="$dest/$version/x86_64"
    glslc="$sdk/bin/glslc"
    # The Linux SDK keeps the loader in lib/VulkanLoader/lib, not lib/, so
    # CMake's FindVulkan needs that prefix too (as the SDK's setup-env.sh sets).
    prefix_path="$sdk:$sdk/lib/VulkanLoader"
    ;;
  MINGW* | MSYS*)
    installer="$RUNNER_TEMP/vulkansdk.exe"
    fetch "https://sdk.lunarg.com/sdk/download/$version/windows/vulkansdk-windows-X64-$version.exe" \
      "$installer" "$windows_sha256"
    sdk="C:\\VulkanSDK\\$version"
    "$installer" --root "$sdk" --accept-licenses --default-answer --confirm-command install
    glslc="$(cygpath -u "$sdk")/Bin/glslc.exe"
    prefix_path="$sdk"
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
  # So CMake finds the SDK's loader and its SPIRV-Headers config.
  echo "CMAKE_PREFIX_PATH=$prefix_path"
} >> "$GITHUB_ENV"
dirname "$glslc" >> "$GITHUB_PATH"
