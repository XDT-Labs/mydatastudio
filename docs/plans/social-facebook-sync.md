---
status: proposed
adr: none
remaining: [business-verification, meta-app-setup, legal-pages, token-service, app-review, schema-adr, graph-client, backfill, incremental-sync, media, places, embeddings, search, feed-ui]
---

# Plan: Sync Facebook through the Graph API

`client/lib/modules/social/pages/facebook_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Facebook" button. There's nothing behind
either.

This plan makes that button real. The user logs in with Facebook. We backfill their whole post
history through the Graph API, then keep it in sync on a schedule. Posts are stored locally with
text embeddings. Photos and videos land in the Photos module. Check-ins become geo points that
`near:` can find.

**Scope: an archive of what the user posted, not a Facebook client.** We keep the user's own
posts, the photos and videos in them, their albums and their check-ins. Out of scope:
Messenger, other people's posts and comments, comments the user left on other people's posts,
and engagement (reactions, comment and share counts). If it isn't something the user posted,
we don't fetch it.

It assumes Meta approves the app. See [Prerequisites](#prerequisites-meta-app-setup-and-verification)
for what has to happen, and in what order.

> Facts below were checked against Meta's developer docs on 2026-10-25. Items marked
> **(verify)** couldn't be confirmed from the docs and need a test against a real account.

## Prerequisites: Meta app setup and verification

**Order matters:** Meta reviews a *finished* app. App Review needs a working build, a screen
recording of each permission in use, and at least one successful API call per permission in
the 30 days before you submit. So you can't get approval before building. What you can, and
must, do first is everything that unblocks development and has a lead time. In development
mode, the app works fully for accounts that hold a role on it (admin, developer, tester). That's
enough to build and test this whole plan before Meta sees it.

### Phase A — before development starts (owner: Mike)

1. **Business Manager and business verification** (lead time: days to weeks, so start now).
   - Create or confirm a Meta Business portfolio for xdtlabs at business.facebook.com.
   - Verification needs the **legal business name, address, phone** and (recommended) the
     **website domain**. Names and addresses must match the documents *exactly*.
   - Documents: one proof of legal identity (articles of incorporation, business licence or tax
     registration) and one proof of address or phone (utility bill, bank statement under three
     months old, lease). Use clear, uncropped scans. Mismatches and blurry scans are the usual
     reasons for rejection.
   - Verify the domain (xdtlabs.com) in Business Settings › Brand safety › Domains. A DNS TXT
     record is simplest.
   - Expect anywhere from a few days to about 2 weeks; some reports say up to 30 days. Advanced
     Access to `user_*` permissions **requires** a verified business. Until then, people outside
     the business can't grant them.
2. **Create the Meta app** at developers.facebook.com.
   - Type: consumer app with the **Facebook Login** product. App purpose: **"Clients"** (anyone
     can use it), not "Yourself or your own business".
   - Connect it to the verified business: Settings › Basic › Verification.
   - Facebook Login settings: turn on **Embedded browser OAuth login**, and add
     `https://www.facebook.com/connect/login_success.html` to *Valid OAuth redirect URIs*
     **(verify the exact toggles for a desktop app)**.
   - Add the testers (your own and a second account) under App Roles, so dev mode works for
     both of you.
3. **Basic settings that App Review checks:**
   - **App name and 1024×1024 icon**, free of Meta trademarks (no "Facebook" in the name, no
     "f" logo);
   - **category** and a **primary contact email** someone actually reads (review results go
     there);
   - **privacy policy URL**: shown on the Facebook consent screen. It must say the data is
     stored only on the user's computer, what's collected, how to delete it, and that the token
     service sees tokens but no content;
   - **terms of service URL** (recommended);
   - **data deletion**: a callback URL, or a page with instructions;
   - **app domains**: the domain hosting the above.
4. **Host the web pieces** (they block App Review and they block the build, because the app
   can't get a long-lived token without them):
   - the **token service** on **GCP Cloud Run**, holding the app secret, with the `exchange`,
     `deauthorize` and `data-deletion` endpoints from the *Token service* section. Setup is in
     that section;
   - the privacy policy, terms and data-deletion status pages, on xdtlabs.com.
   - Keep the app secret in **Secret Manager**, never in the repo, the container image or the
     app binary.
5. **Read** the Platform Terms, the Developer Policies and the *Allowed Usage* of each
   permission we'll request, and write the one-paragraph use case for each: "private digital
   album and searchable archive of your own timeline, stored only on your computer". These
   paragraphs go into the submission, and Meta says each must be unique, not copy-pasted.

### Phase B — during development

6. **Prepare a reviewer test path.** Meta rejects the *entire* submission if reviewers can't
   get into the app. For a macOS desktop app, that means:
   - a **notarized, downloadable build** (DMG link, `make notarize`) with install steps;
   - a reviewer test Facebook account with sample posts, photos, an album and a check-in
     (never your personal credentials);
   - step-by-step instructions from install to the Facebook feed. Assume the reviewer may not
     want to install a desktop app, so the screen recordings have to stand on their own
     **(verify whether reviewers install desktop apps or rely on recordings)**.
7. **Exercise every permission** from the app (or Graph API Explorer) within the 30 days before
   submitting. Meta checks for those calls, and its logging lags by up to 2 days.

### Phase C — submission (after the feature works end to end)

8. **Screen recordings**, one per permission (`user_posts`, `user_photos`, `user_videos`):
   - 1080p, English UI, enlarged cursor, no audio, captions on non-obvious steps;
   - window width at or under 1440px;
   - each one shows the Facebook consent screen granting that permission, then where the data
     appears (the feed for posts; Photos and albums for photos; playback for videos).
9. **Submit:** permission requests with their unique usage descriptions, Data Handling
   Questions (they appear only after business verification), reviewer access instructions, and
   acceptance of the Platform Onboarding Terms. Meta's target is a decision **within about a
   week**. Plan for at least one rejection-and-resubmit cycle.
10. **After approval:** switch the app to **Live** mode. In Live mode only approved permissions
    work, even for role-holders, so don't flip it early. Then put the yearly **Data Use
    Checkup** in the calendar: missing it can revoke access **(verify the current cadence)**.

### Checklist

- [ ] Business portfolio created and **verified**; xdtlabs.com domain verified
- [ ] Meta app created (Facebook Login, purpose "Clients") and linked to the business
- [ ] Testers added; dev-mode login works
- [ ] Privacy policy, terms, data-deletion page live
- [ ] Token service deployed with the app secret; `exchange` works from the app
- [ ] Usage paragraph written for each permission
- [ ] Notarized build + reviewer test account + instructions
- [ ] Each permission called within 30 days of submitting
- [ ] Screen recordings recorded
- [ ] Submitted → approved → Live → Data Use Checkup on the calendar

## Permissions to request

| Permission | Gives us | Meta's allowed usage, quoted where it applies to us |
|---|---|---|
| `user_posts` | The user's own timeline posts, including tagged posts | "physical or digital books or albums of their timelines" |
| `user_photos` | Full-resolution photos the user uploaded, plus their albums | "Create physical or digital books or albums of a person's photos… export photos for printing" |
| `user_videos` | Videos the user uploaded, with source URLs | "edit or create new video content…", "display their video within an app" |
| `public_profile` | Name, profile picture | default |

The App Review pitch is "a private digital album and searchable archive of your own timeline,
stored only on your computer". Frame every screencast around that. **Don't request
`user_friends`, `user_events` or `user_likes` in the first submission.** Each extra permission
needs its own justification and slows review down. Add them later if they earn it.

Everything else App Review needs is in [Prerequisites](#prerequisites-meta-app-setup-and-verification).

## Auth: why we need a token service

Meta's desktop login flow uses a webview pointed at
`https://www.facebook.com/connect/login_success.html` with `response_type=token`. The token
comes back in the URL fragment. That token is **short-lived (hours)**. Exchanging it for a
**long-lived (~60-day)** token calls `GET /oauth/access_token` with the **app secret**, and Meta
says the secret must never ship in client code. The docs don't mention PKCE for Facebook Login,
so we can't avoid the secret that way **(verify)**.

So we run a minimal **token service on GCP Cloud Run**, holding the app secret. It has three
endpoints:
1. `POST /facebook/exchange`: takes a short-lived token and returns a long-lived one. It also
   runs `debug_token` server-side, to check that the token was issued to *our* app before
   exchanging it.
2. `POST /facebook/deauthorize` and `POST /facebook/data-deletion`: the callbacks App Review
   requires. Because we hold no user data, deletion returns a confirmation code and a status
   page that explains the data lives only on the user's machine, and how to delete it in the
   app.
3. Nothing else. **User data never passes through it**; only tokens do, and it stores nothing.
   That keeps the app local-first in practice, and the plan should say so in the privacy
   policy.

Cloud Run setup:
- **Code:** a small stateless **Python FastAPI** service in a new top-level `tokenservice/`
  directory, matching `aiserver/` (PDM, pytest, the same Python version range). It ships as one
  container image, with no database and no shared code with `aiserver/`. It's a separate
  deployable, not a module of the desktop app's server.
- **Pages:** the service serves **only** the JSON endpoints. The privacy policy, terms and
  data-deletion status pages are static pages on **xdtlabs.com**, so the `data-deletion`
  callback returns a status URL there (e.g. `https://xdtlabs.com/facebook/deletion?code=<code>`).
- **Deploy:** one Cloud Run service in a dedicated GCP project (e.g. `mydatastudio-auth`), in a
  US region. `--allow-unauthenticated` is required: the desktop app and Meta's callbacks have no
  GCP identity. Map a custom domain (`auth.xdtlabs.com`) so the URLs in Meta's settings don't
  depend on the generated `run.app` hostname.
- **Secret:** `FACEBOOK_APP_SECRET` in Secret Manager, mounted as an env var. The service account
  gets only `roles/secretmanager.secretAccessor` on that one secret.
- **Cost and scaling:** `min-instances=0` (scale to zero; a cold start of a second or so on a
  login is fine), a low `max-instances` (e.g. 5) to cap cost and abuse, request timeout 10s.
  At this traffic it stays within the free tier.
- **Abuse controls:** `exchange` refuses any token `debug_token` says wasn't issued to our app
  id, so the endpoint is useless to anyone else. Verify the `signed_request` HMAC on
  `deauthorize` / `data-deletion`. Log request outcomes only; never log tokens.
- **Release:** Cloud Build or a `make deploy-tokenservice` target. Bake the service URL into
  the app as a `--dart-define`, as `REALM_NAME` is today.

Client side:
- New `LoginProviders` entry for Facebook. The existing `DesktopOAuthManager` binds a localhost
  redirect server, which Facebook doesn't support for desktop **(verify)**, so Facebook gets its
  own small login controller using `webview_flutter` (already a dependency). It watches for
  navigation to `login_success.html` and reads the fragment.
- Store the long-lived token in `collections.access_token` / `expiration` the same way the
  other providers do. Set `needs_re_auth` when it expires or the API returns error code 190.
- **There's no refresh endpoint.** A long-lived token can't be renewed without the user, and an
  expired one can't be exchanged. Show "Reconnect Facebook" about 7 days before `expiration`,
  so a lapse never surprises the user. Meta also has a separate "data access expiration" that
  can require re-consent after about 90 days of inactivity **(verify)**. Handle it the same way:
  error → `needs_re_auth` → banner.

## Storage

This plan builds the **shared social foundation** described in
[social-twitter-archive.md](social-twitter-archive.md), if Facebook goes first. Record the
schema in **ADR 0002** before writing it. Facebook adds these specifics:

**`social_posts`** (shared table; Facebook values shown)
- `id` (our UUID), `collection_id`, `platform = 'facebook'`, `external_id` = Graph post id
  (`<user>_<post>`). Unique on `(platform, external_id)`, so every write is an upsert.
- `kind`: `post`, `photo`, `video`, `link`, `checkin`, `shared`, `life_event`. Derived from
  `status_type` and the attachment type.
- `text` = `message`. `story` goes in a separate column: it's the auto-generated line ("Mike was
  at Banff"), useful to show but noisy to embed.
- `created_at` and `updated_at`, from `created_time` and `updated_time`.
- `url` = `permalink_url`. `parent_external_id` = `parent_id`, for shares.
- `privacy` (a short label: Public / Friends / Only me), so the UI can show the same icon.
- `place_name`, `place_external_id`, `latitude`, `longitude`, plus `city` and `country` when
  present. Taken from `place{id,name,location}`.
- `link_url`, `link_title`, `link_description`, from a share attachment.
- `deleted_on_source_at`: set when a reconcile pass can no longer find the post on Facebook. We
  **never** delete local copies. Keeping them is the point of an archive.
- `raw_json`: the full Graph response, so later parser versions can re-derive columns without
  re-fetching.

**`social_post_mentions`** `(post_id, offset, length, name, external_id)`, from `message_tags`,
so the feed can render @mentions. Names only: no profile fetches for other people.

**Media goes into `files`**, the same way email attachments do:
- Add a `social_post_id` column to `files`, mirroring `email_id`. Add a `position` column for
  order within a post.
- `collection_id` is the Facebook collection. `local_path` is the downloaded copy.
  `date_created` is the photo's `created_time`, so it sorts into the right month in Photos.
- **Location:** Facebook strips EXIF from uploads, so copy the post's
  `latitude`/`longitude` into `files.latitude`/`longitude` for every photo on a check-in post.
  Photos on the map then come for free.
- `description` is the photo's caption (`name` on the Photo node).
- Facebook albums (`/me/albums`) map onto the existing `albums` / `album_files` tables. The
  user's "Banff 2019" album appears as an album in Photos.
- `PhotoSource` gets a `socialPostId`, as it has `emailId`, so the info sidebar can link back to
  the post.

**Embeddings:** `social_posts_embeddings`, the same shape as `emails_embeddings` (Qwen3-VL,
2048 dimensions). Images don't need anything new: they're rows in `files`, so the existing
`EmbeddingIsolate` already embeds and describes them.

## The Graph client

Pure Dart, in `modules/social/services/facebook/`. It stays thin, so tests can feed it recorded
JSON.

- **Pin a Graph API version** (e.g. `v25.0`) in one constant. Versions expire about two years
  after release, so add a roadmap reminder to bump it.
- The posts query asks for exactly the fields we store:
  ```text
  GET /me/posts?fields=id,message,story,created_time,updated_time,permalink_url,status_type,
      privacy,parent_id,place{id,name,location{latitude,longitude,city,country}},
      message_tags,
      attachments{type,media_type,url,title,description,target{id},
                  media{image{src,width,height},source},
                  subattachments.limit(100){type,media_type,target{id},media{image{src}}}}
    &limit=100
  ```
  Follow `paging.next` until it's gone. Use `since`/`until` (Unix seconds) for windows.
- **Full-resolution media:** `media.image.src` in attachments (and `full_picture`) is capped at
  720px. For each photo `target.id`, call `/{photo-id}?fields=images,name,created_time,album` and
  take the largest entry in `images`. For videos, use `/{video-id}?fields=source,length,picture`.
  Batch these with the Graph **batch API** (up to 50 requests per call) to save on rate limit.
- **CDN URLs expire** (they're signed). Download the media in the same sync pass as the post,
  never later from a stored URL. Store only the local copy and the Graph id.
- **Rate limits:** read the `X-App-Usage` / `X-Business-Use-Case-Usage` headers. Back off when
  any value passes 75%. Treat error codes 4, 17 and 32 as "slow down", with exponential backoff
  that persists across runs, not just retries.
- **Errors:** code 190 = token invalid → `needs_re_auth`. Code 10 / 200 = permission missing →
  show which permission and offer to re-login. Everything else → existing scanner error state.

## Backfill and sync

Implemented as a registered `CollectionScanner` (`FacebookScanner`), running in an isolate like
the Gmail scanner. Writes go through `writeViaMain()`, following the single-writer rule. It
needs a `SequentialWriteQueue` on the main isolate if it uses `receivePort.listen`.

1. **Backfill (first run):** page `/me/posts` from newest to oldest. Save the paging cursor and
   the oldest `created_time` reached in a `social_sync_state` row
   `(collection_id, phase, cursor, oldest_seen, newest_seen, last_reconcile_at)` **after every
   page**. A large account can take hours under the rate limit, and the app will be quit midway;
   restarting must resume from the cursor, not start over. Progress UI: "Imported 4,120 posts,
   back to March 2014."
2. **Incremental (every run after):** `GET /me/posts?since=<newest_seen − 1 day>`. The overlap
   window catches clock skew and late-indexed posts, and the upsert makes duplicates harmless.
3. **Edits:** posts can be edited without a new `created_time`. Once a day, re-fetch the last
   30 days of posts and upsert any whose `updated_time` changed.
4. **Deletes:** weekly, list ids only (`fields=id`) back through the last 12 months. Anything
   local that's missing gets `deleted_on_source_at`, and the feed shows "Deleted on Facebook"
   instead of hiding it.
5. **Schedule:** daily, plus a run on app start. Hourly buys nothing for a personal timeline and
   burns rate limit. Scanners today run only at start-up and when collections change — there's
   no periodic trigger — so add one to `ScannerManager` (a `Timer.periodic` per collection,
   configurable, default 24h). Gmail and Drive will want it too.
6. **Pause rules:** same as the other scanners. Embeddings pause while the Facebook scanner is
   syncing.

## Places and `near:`

- A check-in gives coordinates directly (`place.location`). Store them on the post and on its
  photos. No geocoding needed.
- A place with a name and no coordinates (some pages lack them): resolve `city`/`country`
  through the existing gazetteer (`gazetteer_repository.dart`) to a centre point, and flag it
  `geo_precision = 'city'`, so the map can show it as an approximate area.
- Extend `NearResolver`'s candidate query (today it searches `files` lat/lng) to include
  `social_posts`. `near:banff` then returns the check-in post and its photos.
- `place_name` is also indexed in FTS. Typing "Moraine Lake" finds the check-in even without
  `near:`.

## Embeddings

- **What to embed per post:** `text` + `place_name` + `link_title` + `link_description`, in one
  string, with a short prefix ("Facebook post, 2019-07-14, at Moraine Lake: …"). The date and
  place in the text help the model answer "what did I post from Banff?". Skip `story`.
- **Posts with no text** (photo-only posts) get no text embedding. They're found through their
  images, which `EmbeddingIsolate` embeds and describes. A search hit on a file with a
  `social_post_id` surfaces its post in social results, as an attachment hit surfaces its email.
- **Isolate:** generalize `EmailEmbeddingIsolate` into a text-row embedder that takes a table,
  rather than copying it. Decide this in ADR 0002.
- Chunking: posts are short. One chunk unless longer than the model's window (rare; reuse the
  email chunker).

## Search and LLM tools

From the shared foundation:
- `SearchResultType.social`, plus a `type:social` (and `type:facebook`) filter;
- an FTS5 index over `text`, `place_name` and `link_title`;
- a vector retriever over `social_posts_embeddings`;
- all merged by `HybridRanker`;
- `social` as a `sources` value on the LLM `search` tool (ADR 0001).

## The feed UI

**Build the feed natively. Don't embed Facebook's post widget.** The official embed plugin only
works for public posts, needs a network connection, loads Facebook's tracking scripts, and
breaks offline. That defeats the archive. Render every post from local data instead.

`facebook_page.dart` becomes a `FacebookFeedPage`:

- **List:** `ListView.builder` over a paged repository query (50 at a time, newest first), with
  sticky **month/year headers** and a year jump bar down the side. Same paging approach as the
  Photos grid.
- **`SocialPostCard`** (shared by Twitter and Instagram later):
  - **header:** cached profile picture, name, relative date (full date on hover), privacy icon,
    and "at Moraine Lake" when there's a place;
  - **body:** text with URLs linkified and @mentions styled from `social_post_mentions`. Long
    posts collapse at 8 lines with "See more". `story` is shown in muted type above the text;
  - **media:** Facebook-style grids — one full width; two side by side; three as one large plus
    two small; four or more as a 2×2 grid with "+N" on the last tile. Tapping opens the existing
    Photos viewer on those files, so zoom, info and favourite work already;
  - **link card:** thumbnail, title, domain, description. Click opens in the browser via
    `url_launcher`;
  - **check-in:** a small static `flutter_map` tile (already a dependency) with a pin. Click →
    Photos map view centred there;
  - **footer:** just "Open on Facebook" (permalink). No reaction, comment or share counts:
    this is an archive of what the user posted, not a copy of Facebook.
  - States: "Deleted on Facebook" banner; "media still downloading" placeholder.
- **Toolbar:** a search box that runs hybrid search scoped to `type:facebook`, plus filter chips
  (Has photos, Check-ins, Links, a year picker) and **On this day**, which is a cheap query and
  a natural use for an archive.
- **Empty and auth states:** "Connect Facebook" (replacing the disabled button), backfill
  progress, "Reconnect Facebook — access expires in 5 days", and "Sync paused: rate limited, next
  try 14:20".

## Out of scope, and other things to watch

**Deliberately not archived** (see *Scope* at the top): Messenger, posts others wrote on the
user's timeline (`/me/feed`), others' comments, photos others tagged the user in, comments the
user left elsewhere, reactions, stories, saved items, events. We only call `/me/posts`, the
user's own photos and videos, and `/me/albums`. That also keeps the App Review request to three
permissions.

Things to watch:

1. **Graph API version churn.** Pin, test against recorded fixtures, bump yearly.
2. **Meta Platform Terms obligations:** honour the deauthorize callback (mark the collection
   disconnected), don't sell or share data, keep the privacy policy accurate. On disconnect,
   **keep the archive** (it's the user's, on their disk) and say so, with a separate "Delete
   everything from Facebook" action.
3. **Token security.** The long-lived token sits in `collections.access_token`. Check whether
   that table is protected the way `services/secure_vault.dart` protects other secrets. If not,
   that's a gap for every provider, not just this one.
4. **Account size.** Heavy users have 10k+ posts and 50k+ photos. Media downloads dominate:
   respect the collection's `download_local_copy` setting, and show disk use before backfill.

## Tests

- Graph client against **recorded JSON fixtures** (scrub ids and names first): paging, a
  multi-photo post with subattachments, a check-in, a shared link, a text-only post, error
  190, and rate-limit headers.
- Mapper: kind derivation, place → lat/lng, mentions offsets (UTF-16 vs code points:
  `message_tags.offset` counting **(verify)** with an emoji-heavy fixture).
- Sync state: a backfill interrupted mid-page resumes from the cursor. An incremental run with
  overlap adds no duplicates. An edited post updates in place. A missing post gets
  `deleted_on_source_at` and is not deleted.
- Photos: a check-in photo gets the post's coordinates; an album maps to `albums`.
- Token service: rejects tokens from another app (`debug_token` app_id mismatch).

## Done when

- Logging in with a real account backfills every post. Quitting midway and restarting resumes
  rather than restarts.
- A new post on Facebook appears in the app within a day, unattended. An edited post updates.
  A deleted one is kept and marked.
- Photos from posts show in Photos at full resolution, in their Facebook albums. Check-in
  photos appear on the map.
- A known post is found by keyword, by a semantic query, by `type:facebook`, and by `near:` for
  a check-in.
- An expiring token produces a visible "Reconnect" prompt before it lapses, never silent
  failure.
- App Review approved for `user_posts`, `user_photos`, `user_videos`.

## Open questions

None blocking. Decided on 2026-10-25: the token service is Python FastAPI on Cloud Run, and the
privacy policy, terms and data-deletion pages are static pages on xdtlabs.com.
