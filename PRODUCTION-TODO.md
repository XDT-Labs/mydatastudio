# Production TODO

What has to be done before tagging a production release (`vX.Y.Z` on `main`). Tick an item when
it's done, and remove the list once the release ships.

## Before tagging a production release

- [ ] **Register the Entra app** (public client, redirect `http://localhost`, delegated
      `IMAP.AccessAsUser.All`, `Files.Read`, `User.Read`, `offline_access`), set
      `OUTLOOK_CLIENT_ID` in CI, and complete publisher verification.
- [ ] **Dropbox:** create the scoped app and register production use before 50 linked users.
- [ ] **A beta tag run on `develop`** after merging. The release workflow only runs on tags, and
      x86_64 Linux and the Windows build haven't run end to end on GitHub's runners in a
      production release yet.
- [ ] **Windows code signing:** this needs a decision and secrets. Until then, SmartScreen warns
      on install.
- [ ] **Re-embedding:** budget for it on upgrade, since every file and email is embedded again
      with EmbeddingGemma 2.
- [ ] **OpenWiki:** decide whether removing the scheduled workflow was intended, and update
      `CLAUDE.md` to match either way.
