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
  display-brand:
    fontFamily: Montserrat
    fontSize: 24px
    fontWeight: '800'
    lineHeight: 32px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Public Sans
    fontSize: 20px
    fontWeight: '700'
    lineHeight: 28px
  body-md:
    fontFamily: Public Sans
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-md-bold:
    fontFamily: Public Sans
    fontSize: 14px
    fontWeight: '700'
    lineHeight: 20px
  label-caps:
    fontFamily: Public Sans
    fontSize: 10px
    fontWeight: '900'
    lineHeight: 16px
    letterSpacing: 0.15em
  table-header:
    fontFamily: Public Sans
    fontSize: 11px
    fontWeight: '900'
    lineHeight: 16px
    letterSpacing: 0.1em
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

The palette is a deep-space dark theme dominated by the "Neutral" obsidian base and accented by "Primary" lavender tones. 

- **Primary (#cfbcff):** Used for active states, key actions, and brand highlights.
- **Secondary (#ccc2dc):** Provides muted structural contrast for secondary navigation and icons.
- **Tertiary (#efc048):** Reserved specifically for file/folder metaphors to provide instant visual scanning.
- **Atmospheric Layering:** The background is not a flat color but a dynamic mesh gradient. Surfaces utilize a custom "Glass" treatment with a `20px` backdrop blur and `8%` white borders to simulate layered acrylic panels.

## Typography

The typographic system utilizes a high-contrast pairing: 
- **Montserrat** is used exclusively for brand-level display and high-impact headers to convey a bold, urban energy.
- **Public Sans** handles the heavy lifting for data density. It is chosen for its exceptional legibility at small sizes (10px - 14px) and its institutional, trustworthy feel.

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