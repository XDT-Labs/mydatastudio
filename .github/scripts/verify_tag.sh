#!/usr/bin/env bash
# Decides what a version tag releases, before any platform spends time building.
#
#   vX.Y.Z         a production release, which must be on main
#   vX.Y.Z-suffix  a pre-release, from any branch
#
# Pre-releases can come from any branch so a branch's builds can be tested
# before it merges. Production releases are offered to every user by the in-app
# update checker, so they only come from main.
# Needs TAG and full git history with origin/main fetched. Writes `tag`, `version`
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
  commit=$(git rev-parse "refs/tags/$TAG^{commit}")
  if ! git merge-base --is-ancestor "$commit" origin/main; then
    echo "Error: $TAG ($commit) is not on main."
    echo "Production tags (vX.Y.Z) come from main. To test a branch, add a suffix (vX.Y.Z-beta.1)."
    exit 1
  fi
fi

{
  echo "tag=$TAG"
  echo "version=$version"
  echo "prerelease=$prerelease"
} >> "$GITHUB_OUTPUT"
echo "$TAG: version $version, prerelease=$prerelease"
