---
name: Vibrant Messaging System
colors:
  surface: '#fbf8ff'
  surface-dim: '#dad9e4'
  surface-bright: '#fbf8ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f4f2fe'
  surface-container: '#eeecf8'
  surface-container-high: '#e9e7f3'
  surface-container-highest: '#e3e1ed'
  on-surface: '#1a1b23'
  on-surface-variant: '#494454'
  inverse-surface: '#2f3039'
  inverse-on-surface: '#f1effb'
  outline: '#7b7486'
  outline-variant: '#cbc3d7'
  surface-tint: '#6d3bd7'
  primary: '#6b38d4'
  on-primary: '#ffffff'
  primary-container: '#8455ef'
  on-primary-container: '#fffbff'
  inverse-primary: '#d0bcff'
  secondary: '#795900'
  on-secondary: '#ffffff'
  secondary-container: '#ffc329'
  on-secondary-container: '#6f5100'
  tertiary: '#5f5293'
  on-tertiary: '#ffffff'
  tertiary-container: '#786bad'
  on-tertiary-container: '#fffbff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#e9ddff'
  primary-fixed-dim: '#d0bcff'
  on-primary-fixed: '#23005c'
  on-primary-fixed-variant: '#5516be'
  secondary-fixed: '#ffdf9f'
  secondary-fixed-dim: '#f9bd22'
  on-secondary-fixed: '#261a00'
  on-secondary-fixed-variant: '#5c4300'
  tertiary-fixed: '#e7deff'
  tertiary-fixed-dim: '#ccbeff'
  on-tertiary-fixed: '#1e0e4e'
  on-tertiary-fixed-variant: '#4a3d7c'
  background: '#fbf8ff'
  on-background: '#1a1b23'
  surface-variant: '#e3e1ed'
typography:
  display-lg:
    fontFamily: Outfit
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Outfit
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Outfit
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 36px
  headline-md:
    fontFamily: Outfit
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Outfit
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Outfit
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-md:
    fontFamily: Outfit
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 20px
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Outfit
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
rounded:
  sm: 0.5rem
  DEFAULT: 1rem
  md: 1.5rem
  lg: 2rem
  xl: 3rem
  full: 9999px
spacing:
  base: 8px
  xs: 4px
  sm: 12px
  md: 20px
  lg: 32px
  xl: 48px
  gutter: 16px
  margin-mobile: 20px
  margin-desktop: 40px
---

## Brand & Style
The design system is engineered to evoke a sense of kinetic energy, friendliness, and effortless social connection. It targets a Gen-Z and Millennial audience that values self-expression and rapid, joyful communication.

The aesthetic direction is a blend of **Modern Playful** and **Soft-Glassmorphism**. It prioritizes high-saturation focal points against airy, tinted backgrounds. The visual language avoids sharp corners and clinical rigidity, instead opting for fluid shapes and bouncy interactions that make the digital experience feel responsive and alive.

## Colors
The palette is anchored by **Electric Violet**, a high-chroma primary that drives action and identifies the brand. **Sunshine Yellow** serves as a strategic accent color, used sparingly for "moment-of-delight" features, notifications, or high-priority calls to action.

The neutral foundation is not a flat gray but a **Soft Lavender-White**. This ensures that even "empty" spaces feel branded and warm. Secondary UI elements use a desaturated tertiary violet to maintain harmony without competing with the primary actions. Text is rendered in a deep, midnight-plum shade rather than pure black to maintain the energetic vibration of the palette.

## Typography
This design system utilizes **Outfit** across all levels to leverage its geometric yet friendly character. The typography relies on heavy weights (Bold/SemiBold) for headers to create a confident, impactful hierarchy. 

Line heights are intentionally generous to improve readability in fast-paced chat environments. Display and Headline styles use slight negative letter-spacing to appear more "locked-in" and modern, while labels and captions use slight positive tracking to ensure legibility at smaller scales.

## Layout & Spacing
The spacing logic follows a strict **8pt linear scale**. In a messaging context, vertical rhythm is paramount. Chat bubbles and list items use a "compact-yet-breathable" approach, with 12px or 16px internal padding.

The layout is **fluid** for mobile views, using a 4-column grid with 20px side margins. On desktop, the interface transitions to a multi-pane layout (sidebar, chat list, active conversation) using fixed-width side panels and a fluid center stage. Content containers should never feel cramped; negative space is used to separate conversation threads rather than heavy dividers.

## Elevation & Depth
Depth is communicated through **Ambient Shadows** rather than stark borders. Shadows are "Long & Soft," using a slight violet tint (`rgba(139, 92, 246, 0.12)`) instead of gray. This keeps the UI feeling light and airy.

We use **Tonal Layers** for structural organization:
- **Level 0 (Background):** Lavender-white (#FAF9FF).
- **Level 1 (Cards/Bubbles):** Pure White (#FFFFFF) with a soft 16px blur shadow.
- **Level 2 (Modals/Popovers):** Pure White with a 32px blur shadow and 4px vertical offset.

Glassmorphism is applied to top navigation bars and bottom tab bars using a `backdrop-filter: blur(12px)` and a semi-transparent white fill, allowing the energetic chat content to peek through as the user scrolls.

## Shapes
The shape language is defined by **Extreme Roundedness**. Every interactive element—from buttons to input fields—utilizes a pill-shaped or high-radius construction. 

Specific application:
- **Primary Action Buttons:** Full pill shape (999px radius).
- **Message Bubbles:** 20px radius on three corners, with the tail corner featuring a sharper 4px radius to indicate the sender.
- **Images/Avatars:** Circular or 24px rounded squares for a "squircle" look.
- **Cards:** 24px (rounded-lg) to 32px (rounded-xl) radii.

## Components
### Buttons
Buttons are high-impact. Primary buttons use the Electric Violet fill with white text and a subtle "lift" hover effect (scaling to 1.02x). Secondary buttons use a lavender-tinted ghost style with violet borders.

### Message Bubbles
Sender bubbles (user) are Electric Violet with white text. Receiver bubbles are White with a subtle Violet border or Soft Lavender fill. This color-coding ensures immediate context during rapid scrolling.

### Inputs
Search bars and chat inputs are pill-shaped. On focus, the border transitions from a soft lavender to the primary violet with a subtle outer glow (0px 0px 0px 4px rgba(139, 92, 246, 0.2)).

### Chips & Tags
Chips are used for emoji reactions and status indicators. They utilize the Sunshine Yellow for "new" or "active" states to draw the eye immediately.

### Lists
List items (like a friend list) omit horizontal dividers. Instead, they use generous vertical padding and a "Selected" state that uses a soft-violet background pill.

### Iconic Language
Icons should be "Duotone" or "Rounded Bold" styles, utilizing the primary violet for the main stroke and sunshine yellow for accent details within the icon (e.g., a violet bell with a yellow notification dot).