---
name: Ethereal Data Studio
colors:
  surface: '#141317'
  surface-dim: '#141317'
  surface-bright: '#3b383e'
  surface-container-lowest: '#0f0d12'
  surface-container-low: '#1d1b20'
  surface-container: '#211f24'
  surface-container-high: '#2b292e'
  surface-container-highest: '#363439'
  on-surface: '#e6e1e8'
  on-surface-variant: '#cac4d0'
  inverse-surface: '#e6e1e8'
  inverse-on-surface: '#322f35'
  outline: '#948f9a'
  outline-variant: '#49454f'
  surface-tint: '#cfbcff'
  primary: '#e8ddff'
  on-primary: '#36265e'
  primary-container: '#cfbcff'
  on-primary-container: '#594983'
  inverse-primary: '#655590'
  secondary: '#ccc2dc'
  on-secondary: '#332d41'
  secondary-container: '#4a4359'
  on-secondary-container: '#bab1ca'
  tertiary: '#ffdf97'
  on-tertiary: '#3f2e00'
  tertiary-container: '#efc048'
  on-tertiary-container: '#684e00'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e9ddff'
  primary-fixed-dim: '#cfbcff'
  on-primary-fixed: '#210f48'
  on-primary-fixed-variant: '#4d3d76'
  secondary-fixed: '#e9def9'
  secondary-fixed-dim: '#ccc2dc'
  on-secondary-fixed: '#1e182b'
  on-secondary-fixed-variant: '#4a4359'
  tertiary-fixed: '#ffdf99'
  tertiary-fixed-dim: '#efc048'
  on-tertiary-fixed: '#251a00'
  on-tertiary-fixed-variant: '#5a4300'
  background: '#141317'
  on-background: '#e6e1e8'
  surface-variant: '#363439'
  surface-glass: rgba(30, 27, 32, 0.6)
  surface-glass-elevated: rgba(255, 255, 255, 0.05)
  mesh-purple-1: rgba(103, 80, 164, 0.15)
  mesh-purple-2: rgba(207, 188, 255, 0.1)
  mesh-indigo: rgba(79, 55, 138, 0.12)
  border-subtle: rgba(255, 255, 255, 0.08)
typography:
  # Source of truth: _buildTheme() in client/lib/family_dam_app.dart.
  # Font: the macOS system font (.AppleSystemUIFont = SF Pro), fallbacks Inter, Segoe UI, sans-serif.
  display-brand:
    fontFamily: Montserrat
    fontSize: 22px
    fontWeight: '200'
    letterSpacing: -0.5px
  display-lg:
    fontFamily: System
    fontSize: 56px
    fontWeight: '400'
    letterSpacing: -0.5px
  display-md:
    fontFamily: System
    fontSize: 44px
    fontWeight: '400'
    letterSpacing: -0.5px
  display-sm:
    fontFamily: System
    fontSize: 36px
    fontWeight: '400'
    letterSpacing: -0.25px
  headline-lg:
    fontFamily: System
    fontSize: 32px
    fontWeight: '500'
    letterSpacing: -0.2px
  headline-md:
    fontFamily: System
    fontSize: 28px
    fontWeight: '500'
    letterSpacing: -0.2px
  headline-sm:
    fontFamily: System
    fontSize: 24px
    fontWeight: '500'
    letterSpacing: -0.15px
  title-lg:
    fontFamily: System
    fontSize: 20px
    fontWeight: '500'
    letterSpacing: -0.15px
  title-md:
    fontFamily: System
    fontSize: 15px
    fontWeight: '500'
    letterSpacing: -0.1px
  title-sm:
    fontFamily: System
    fontSize: 13.5px
    fontWeight: '500'
    letterSpacing: -0.1px
  body-lg:
    fontFamily: System
    fontSize: 15px
    fontWeight: '400'
    lineHeight: 1.4
    letterSpacing: -0.1px
  body-md:
    fontFamily: System
    fontSize: 13.5px
    fontWeight: '400'
    lineHeight: 1.4
    letterSpacing: -0.1px
  body-sm:
    fontFamily: System
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 1.35
  label-lg:
    fontFamily: System
    fontSize: 13.5px
    fontWeight: '500'
    letterSpacing: -0.1px
  label-md:
    fontFamily: System
    fontSize: 12px
    fontWeight: '500'
  label-sm:
    fontFamily: System
    fontSize: 11px
    fontWeight: '500'
    letterSpacing: 0.2px
  table-header:
    fontFamily: System
    fontSize: 14px
    fontWeight: '500'
  mono:
    fontFamily: SF Mono
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  container-margin: 1.5rem
  gutter: 1rem
  sidebar-width: 16rem
  nav-rail-width: 4rem
  row-height-md: 3.5rem
  row-padding-x: 1.5rem
---

## Brand & Style

The brand identity for **Ethereal Data Studio** is rooted in a "High-Tech Zen" aesthetic. It targets developers and data scientists who require a focused, high-performance environment that feels sophisticated rather than cluttered. 

The design style is a refined hybrid of **Glassmorphism** and **Corporate Modernism**. It leverages atmospheric background mesh gradients and translucent surfaces to create a sense of depth and infinite space, while maintaining a strict, systematic layout. The emotional response should be one of "calm productivity"—where complex data feels light, accessible, and elegantly organized within a futuristic, dark-mode ecosystem.

## Colors

The palette is a deep-space dark theme dominated by the "Neutral" obsidian base and accented by "Primary" lavender tones. The app ships **dark mode only** (`ThemeMode.dark` is hardcoded in `family_dam_app.dart`) — a light `ColorScheme` exists in `color_schemes.g.dart` for potential future use but is not currently reachable from the UI.

- **Primary (#e8ddff):** Used for active states, key actions, and brand highlights. `primary-container` (#cfbcff, the deeper lavender) is used for secondary emphasis surfaces and as `surfaceTint`.
- **Secondary (#ccc2dc):** Provides muted structural contrast for secondary navigation and icons.
- **Tertiary (#efc048):** Reserved specifically for file/folder metaphors to provide instant visual scanning.
- **Atmospheric Layering:** The background is not a flat color but a dynamic mesh gradient. Surfaces utilize a custom "Glass" treatment with a `20px` backdrop blur and `8%` white borders to simulate layered acrylic panels. **Implementation note:** in the current codebase this glass/blur treatment is only applied in one place (`BackdropFilter` in the Files page path bar) — it is the target aesthetic for surfaces generally, not yet a reusable themed widget applied app-wide.

## Typography

Text uses the **platform system font**: `.AppleSystemUIFont` (SF Pro) on macOS, with the
fallbacks `Inter`, `Segoe UI` and `sans-serif` for the Windows and Linux builds. No font files are
bundled. The source of truth is `_buildTheme()` in `client/lib/family_dam_app.dart`; the
`typography` tokens above mirror it.

- **The Material 3 text roles** (`display*`, `headline*`, `title*`, `body*`, `label*`) all use the
  system font, at the sizes above (from 56 px `displayLarge` down to 11 px `labelSmall`). Widgets
  take text styles from `Theme.of(context).textTheme` rather than setting a `fontFamily`.
  Weights stay at 400–500, and letter-spacing tightens slightly as size grows.
- **Montserrat** (via `google_fonts`) is used in one place: the **brand wordmark** "MyData
  Studio" in `adaptive_app_bar.dart`, at weight 200 in `primary`. It isn't a theme role; keep it
  to brand marks.
- **SF Mono** is the monospace face for code, model ids, file text previews and keyboard
  shortcuts. (`keyboard_shortcuts_modal.dart` still uses `GoogleFonts.robotoMono`; switch it to
  SF Mono.)
- **Nav-rail labels and data-table headers** use the system font too (`navigationRailTheme`,
  `dataTableTheme`), with table headers at 14 px / 500 in `onSurfaceVariant`.

Hierarchy is established through weight and letter-spacing rather than dramatic size changes. Data labels and category headers use a "Micro-Caps" style—extra bold, small size, and wide tracking—to differentiate them from interactive content.

## Layout & Spacing

The layout follows a **Hybrid Fixed-Fluid Model**:
1. **Nav Rail:** A 64px (4rem) fixed left rail for primary global app switching.
2. **Context Sidebar:** A 256px (16rem) collapsible sidebar for folder/source navigation.
3. **Main Content:** A fluid area that stretches to fill remaining viewport space.

The internal rhythm is based on a **4px baseline grid**. Horizontal padding is generous (24px/1.5rem) to ensure the interface feels expansive. Components within the main content are housed in large, rounded containers that use dynamic internal padding to group related actions (e.g., the Path & Actions bar).

## Elevation & Depth

Elevation is achieved through **Material Translucency** rather than traditional dropshadows.

- **Level 1 (Base):** The Background Mesh.
- **Level 2 (Panels):** Main navigation and containers using `glass` (60% opacity with 20px blur). This creates a sense of the background "shining through."
- **Level 3 (Interactive):** Action bars and search inputs using `glass-elevated` (5% white tint with 12px blur), creating a "closer" tactile feel.
- **Level 4 (Floating):** Only the Floating Action Button (FAB) uses a true shadow—a `shadow-2xl` tinted with the primary color (#cfbcff) at 40% opacity to denote it is the most critical interactive element.

Most surfaces today rely on the Material 3 `surfaceContainer*` scale (flat fills, no blur) rather than the full glass treatment above — treat the glass/blur elevation model as the design target for panels and action bars as they're built out, not as something already applied consistently.

## Shapes

The shape language is primarily **Rounded**, moving toward **Pill-shaped** for interactive inputs.

- **Panels & Containers:** Use `2xl` (1rem) or `3xl` (1.5rem) corners to soften the technical nature of the app.
- **Active States:** Selection indicators and sidebar highlights use a "One-Side Rounded" approach (rounded-r-lg) to anchor the element to its parent container.
- **Interactive Elements:** Search bars and primary buttons use `full` (pill) rounding to distinguish them from structural layout panels.

## Components

### Buttons & FAB
The Primary FAB is a 64x64px square with `2xl` rounding, featuring a subtle interior gradient. Standard buttons in toolbars are icon-only with a circular hover state (`hover:bg-white/10`).

### Data Tables
Tables should have a transparent background to allow the glass panel's blur to work. Rows use `divide-white/5` borders. Hover states use `hover:bg-white/5`, while active/selected rows use a `bg-primary/5` tint with a 2px left border in the Primary color.

### Checkboxes
Custom checkboxes use a transparent background with a `border-outline/50`. When checked, they transition to `bg-primary` with a white checkmark.

### Search & Inputs
The search bar is a pill-shaped `surface-container-high` element with no border. On focus, it utilizes a 2px `ring-primary` for high visibility.

### Navigation Items
Sidebar items use a specific `group` state where icons and text transition from `on-surface-variant` to `primary` color on hover. Active navigation links use a combination of background tinting and bold font weight.