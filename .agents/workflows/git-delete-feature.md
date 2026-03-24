---
description: Hard delete a feature branch without merging it into develop
---

Forcefully deletes a local (and optionally remote) feature branch without merging its work. Use this when a feature experiment has been abandoned.

// turbo-all
1. Switch to the develop branch (you cannot delete a branch you are actively on): `git checkout develop`
2. Validate the branch name is not main or develop before proceeding: `if [[ "[name]" == "main" || "[name]" == "develop" ]]; then echo "ERROR: Cannot delete main or develop"; exit 1; fi`
3. Force delete the local feature branch: `git branch -D [name]`
4. Delete the tracking branch on the remote: `git push origin --delete [name]`

**Critical Rules**
- If `[name]` is not provided in the original prompt, ask the user for the feature branch name before proceeding.
- WARNING: This is a destructive action (`-D`). Make extremely sure the user understands they will lose any unmerged commits on this branch.
- NEVER delete `main` or `develop`.
