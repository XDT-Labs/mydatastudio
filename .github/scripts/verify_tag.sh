#!/usr/bin/env bash
# Decides what a version tag releases, before any platform spends time building.
#
#   vX.Y.Z         a production release, which must be on main
#   vX.Y.Z-suffix  a pre-release, which must be on develop
#
# Needs TAG and full git history with origin/* fetched. Writes `tag`, `version`
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
  branch=develop
else
  prerelease=false
  branch=main
fi

commit=$(git rev-parse "refs/tags/$TAG^{commit}")
if ! git merge-base --is-ancestor "$commit" "origin/$branch"; then
  echo "Error: $TAG ($commit) is not on $branch."
  echo "Production tags (vX.Y.Z) come from main; pre-release tags (vX.Y.Z-suffix) come from develop."
  exit 1
fi

{
  echo "tag=$TAG"
  echo "version=$version"
  echo "prerelease=$prerelease"
} >> "$GITHUB_OUTPUT"
echo "$TAG: version $version, prerelease=$prerelease, on $branch"
