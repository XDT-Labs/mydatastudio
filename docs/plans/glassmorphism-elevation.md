---
status: ready
adr: none
remaining: [glass-widget, nav-rail, sidebar, dialogs]
---

# Build out the glassmorphism elevation model

_Moved from `TODO.md` (OSS documentation pass, 2026-08-01)._

`DESIGN.md`'s "Elevation & Depth" section specs a 4-level glass system for the whole
app — panels at 60% opacity / 20px blur, action bars/search at 5% white tint / 12px
blur, `8%` white borders on layered surfaces. In the actual client this is implemented
in exactly one place: the `BackdropFilter`/`ImageFilter.blur` in the Files page's
path/actions bar (`client/lib/modules/files/pages/rx_files_page.dart:1238`). Everywhere
else (nav rail, sidebar, dialogs, other module pages) uses flat Material 3
`surfaceContainer*` fills from `color_schemes.g.dart` with no blur or translucency.

Decision (2026-08-01): build it out to match the spec rather than scale back the doc.
Suggested approach: extract the Files-page glass treatment into a reusable themed
widget (e.g. `GlassPanel`/`GlassSurface`) driven by the `glass`/`glass-elevated`
tokens already defined in `DESIGN.md`'s frontmatter, then apply it to the nav rail,
context sidebar, and dialogs so the elevation model in the doc matches what ships.
