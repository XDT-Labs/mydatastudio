---
description: Merge the active feature branch into develop and keep the feature open
---

Automatically syncs a feature branch's completed sub-tasks into develop without closing out the active feature branch so you can continue development.

// turbo
1. Save the current branch name: `CURRENT_BRANCH=$(git branch --show-current)`
// turbo
2. Switch to the develop branch: `git checkout develop`
// turbo
3. Pull the latest develop changes: `git pull origin develop`
// turbo
4. Merge the feature branch: `git merge --no-ff $CURRENT_BRANCH`
5. Push the merged changes to develop: `git push origin develop`
// turbo
6. Switch back to the feature branch to continue working: `git checkout $CURRENT_BRANCH`

**Critical Rules**
- ALWAYS ensure the user is currently on the feature branch they wish to merge.
- DO NOT run this if the user is currently on `main` or `develop`.
- Use the `--no-ff` flag to explicitly create a merge commit.
