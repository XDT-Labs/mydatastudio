---
status: in-progress
adr: none
remaining: [entra-scope, business-and-sharepoint, provider-ui-actions]
---

# Plan: OneDrive (personal, work/school) and SharePoint

The `file.onedrive` constant exists with no implementation. Built on the
[shared foundation](files-sources-foundation.md).

## API connector (Microsoft Graph)

- **Reuse the Entra app** from [email-outlook.md](email-outlook.md): a public client, PKCE, the
  `/common` authority (personal and work accounts). Add the delegated **`Files.Read`** scope
  (least privilege for `delta` on both account types). Add `Files.Read.All` only if SharePoint
  sites are wanted (it may need admin consent in work tenants **(verify)**). One consent covers
  mail and files if the user connects both.
- **`OneDriveApi` adapter:**
  - **Full listing and changes:** `GET /me/drive/root/delta`, following `@odata.nextLink`
    until an **`@odata.deltaLink`** is returned. Store that link as the cursor; the next sync
    calls it. Delta returns **the latest state of each item, not every change**, so track by
    item `id`. Deletions come as `deleted` facets. A `410 Gone` / `resyncRequired` means a full
    re-list;
  - **Content:** `GET /me/drive/items/{id}/content` (redirects to a pre-authenticated URL;
    supports ranges). **Thumbnails:** `/items/{id}/thumbnails`;
  - **Hash:** `file.hashes.quickXorHash` (business and personal) or `sha1Hash` (personal) →
    dedupe;
  - **Throttling:** `429` / `503` with `Retry-After`.
- **Work/school:** the same endpoints. Tenants can block user consent ("Need admin approval"):
  reuse the plain-language explanation from the Outlook plan.
- **SharePoint (later):** `GET /sites?search=` → `/sites/{id}/drives` → a delta per drive.
- **Personal Vault** isn't readable by apps; say so on the card.

## Sync-folder connector

The OneDrive app mounts `~/Library/CloudStorage/OneDrive-Personal/` and
`OneDrive-<OrgName>/`. Files On-Demand placeholders follow the dataless rules.

## Done when

Personal and work users sign in with the same Microsoft app as Outlook mail, the whole drive is
indexed with thumbnails, and delta sync picks up changes, moves and deletes. A blocked tenant
gets a clear explanation.
