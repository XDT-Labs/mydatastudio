#!/usr/bin/env bash
# Decides what a version tag releases, before any platform spends time building.
#
#   vX.Y.Z         a production release
#   vX.Y.Z-suffix  a pre-release
#
# Any branch can be tagged, so a branch's builds can be tested before it merges.
# Needs TAG. Writes `tag`, `version`
# (plain X.Y.Z, which CFBundleShortVersionString requires) and `prerelease` to
# $GITHUB_OUTPUT.
set -euo pipefail

if [[ ! "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: tag '$TAG' is not a version tag (expected vX.Y.Z or vX.Y.Z-suffix)"
  exit 1
fi
version="${BASH_REMATCH[1]}"

if [ -n "${BASH_REMATCH[2]}" ]; then
  prerelease=true
else
  prerelease=false
fi

{
  echo "tag=$TAG"
  echo "version=$version"
  echo "prerelease=$prerelease"
} >> "$GITHUB_OUTPUT"
echo "$TAG: version $version, prerelease=$prerelease"
