---
description: Merge the active feature branch into develop and delete the feature branch
---

Automatically finishes a feature by merging it into the integration branch (develop) using a non-fast-forward merge, and then safely deleting the local and remote feature branches.

// turbo
1. Save the current branch name: `CURRENT_BRANCH=$(git branch --show-current)`
// turbo
2. Switch to the develop branch: `git checkout develop`
// turbo
3. Pull the latest develop changes: `git pull origin develop`
// turbo
4. Merge the feature branch: `git merge --no-ff $CURRENT_BRANCH`
5. Push the merged changes to develop: `git push origin develop`
6. Safely delete the local feature branch: `git branch -d $CURRENT_BRANCH`
7. Delete the remote feature branch: `git push origin --delete $CURRENT_BRANCH`

**Critical Rules**
- ALWAYS ensure the user is currently on the feature branch they wish to complete.
- DO NOT run this if the user is currently on `main` or `develop`.
- Use the `--no-ff` flag to explicitly create a merge commit, preserving the feature's history per the git SKILL.
