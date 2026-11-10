#!/usr/bin/env bash
# Downloads a ~1 MB GGUF (stories260K) for the smoke tests, which load it as
# the default model so the aiserver's llama.cpp build (and its GPU backend,
# with no GPU on the runner) is exercised, not just imported.
#
# Usage: fetch_smoke_model.sh <dest-file>
set -euo pipefail

url=https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf
sha256=270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d

mkdir -p "$(dirname "$1")"
curl -fsSL --retry 3 -o "$1" "$url"
echo "$sha256  $1" | sha256sum -c -
