---
description: Create new features correctly from an up-to-date develop branch
---

Automatically initializes a new feature branch from the absolute latest version of the integration branch.

// turbo-all
1. Switch to the develop branch: `git checkout develop`
2. Pull the latest remote changes: `git pull origin develop`
3. Create and checkout the new feature branch: `git checkout -b feature/[name]`

**Critical Rules**
- If the `[name]` is not provided in the original prompt, ask the user for the feature name before proceeding.
- Ensure the branch name is properly formatted: lowercase, with hyphens instead of spaces (e.g., `feature/login-page`).
