---
description: Keep feature branches up-to-date by rebasing on develop
---

Automatically syncs the current local feature branch with the latest changes from the remote integration branch.

// turbo-all
1. Fetch the latest changes from the remote: `git fetch origin`
2. Rebase your current branch on top of the remote develop branch: `git rebase origin/develop`

**Critical Rules**
- ALWAYS ensure the user has committed or stashed their current working directory before running this workflow.
- DO NOT run this on `main` or `develop`.
- If there are rebase conflicts, stop the workflow and instruct the user on how to resolve them manually.
