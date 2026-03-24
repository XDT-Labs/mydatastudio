---
description: Safely prune old remote branches and delete merged local branches
---

Cleans up the local repository by removing stale branches that have already been integrated.

// turbo-all
1. Prune missing tracking branches from the remote: `git fetch -p`
2. List all local branches that have been safely merged: `git branch --merged`
3. Delete those merged branches (excluding the currently active branch, `main`, and `develop`): 
`git branch --merged | egrep -v "(^\*|main|develop)" | xargs git branch -d`

**Critical Rules**
- NEVER use `-D` (force delete) when automating branch cleanup. Only use the safe `-d` flag.
