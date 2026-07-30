
### From upgrade handling (2026-07-29)

## Tier 2 auto-update: in-place updates via Sparkle

We now ship a *check-and-notify* updater: on launch `UpdateChecker` asks the GitHub
releases API whether a newer tag exists, and `showUpdateAvailableDialog` sends the user to
the release page to download the DMG by hand. That leaves the actual upgrade — mount,
drag, replace, relaunch — as manual work, and users who dismiss the prompt stay on an old
build indefinitely.

Tier 2 is a real auto-updater: download in the background, verify, swap the `.app`,
relaunch. On macOS that means [Sparkle](https://sparkle-project.org/), via the
[`auto_updater`](https://pub.dev/packages/auto_updater) Flutter plugin (Sparkle on macOS,
WinSparkle on Windows — worth having if the Windows build ever ships).

**Already in place** — the parts most projects get stuck on:
- Developer ID Application signing of the client and every nested binary (`make notarize`).
- Notarization + stapling through `xcrun notarytool` / `stapler`.
- A tagged GitHub release per version with `generate_release_notes: true`
  (`.github/workflows/build_and_release.yml`).
- `make notarize` already produces a `ditto`-zipped `MyDataStudio.zip` for submission —
  today it is deleted after notarization. Sparkle wants exactly that artifact.

**What has to be built:**

1. **Appcast feed.** Sparkle polls an RSS `appcast.xml` rather than the GitHub API. Needs
   one `<item>` per release with version, release-notes URL or embedded CDATA, the zip's
   URL and length, and the EdDSA signature. Publish it from GitHub Pages or a raw file in
   the repo — it has to be a stable URL baked into the app at build time (`SUFeedURL` in
   `Info.plist`).
2. **EdDSA signing keys.** Sparkle 2 verifies updates with its own Ed25519 key, separate
   from Apple codesigning. Run `generate_keys` once, put the public key in `Info.plist` as
   `SUPublicEDKey`, and the private key in GitHub Actions secrets. Each release runs
   `sign_update MyDataStudio.zip` and the resulting signature goes into the appcast item.
   **Losing the private key means no existing install can ever auto-update again** — back it
   up outside CI.
3. **Ship the zip as a release asset.** Stop deleting `MyDataStudio.zip` in the `notarize`
   target and upload it alongside the DMG. Keep the DMG: it stays the first-install path,
   and the Tier 1 notify flow links to it.
4. **CI step to update the appcast.** After the release is published, append the new item
   (version, URL, length, signature, notes) and push the feed. This is the fiddly part —
   the signature must be computed over the exact bytes that get uploaded.
5. **Wire up `auto_updater`** in the client: `setFeedURL`, `setScheduledCheckInterval`,
   and drop the Tier 1 startup check so the two don't both prompt.

**Watch out for:**
- Sparkle needs write access to `/Applications/MyDataStudio.app`. It prompts for
  authorization when the app isn't user-writable; that flow needs testing on a real
  non-admin account, not just the dev machine.
- The aiserver version stamp interacts with this. Sparkle swaps the `.app` and relaunches,
  and the new build re-extracts `aiserver/` on first launch — so an auto-update is followed
  by a ~250 MB extraction with the splash sitting on "Updating AI service...". Acceptable,
  but it means an auto-update is not instant and the UI should say so.
- Prereleases must not reach the stable feed. Either publish two appcasts (stable/beta) or
  filter on the `prerelease` flag when generating.

