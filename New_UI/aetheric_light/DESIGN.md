---
name: Aetheric Light
colors:
  surface: '#f9f9f9'
  surface-dim: '#dadada'
  surface-bright: '#f9f9f9'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f3f3f4'
  surface-container: '#eeeeee'
  surface-container-high: '#e8e8e8'
  surface-container-highest: '#e2e2e2'
  on-surface: '#1a1c1c'
  on-surface-variant: '#3e4850'
  inverse-surface: '#2f3131'
  inverse-on-surface: '#f0f1f1'
  outline: '#6e7881'
  outline-variant: '#bec8d2'
  surface-tint: '#006591'
  primary: '#006591'
  on-primary: '#ffffff'
  primary-container: '#0ea5e9'
  on-primary-container: '#003751'
  inverse-primary: '#89ceff'
  secondary: '#5c5f60'
  on-secondary: '#ffffff'
  secondary-container: '#e1e3e4'
  on-secondary-container: '#626566'
  tertiary: '#8a5100'
  on-tertiary: '#ffffff'
  tertiary-container: '#de8712'
  on-tertiary-container: '#4d2b00'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#c9e6ff'
  primary-fixed-dim: '#89ceff'
  on-primary-fixed: '#001e2f'
  on-primary-fixed-variant: '#004c6e'
  secondary-fixed: '#e1e3e4'
  secondary-fixed-dim: '#c5c7c8'
  on-secondary-fixed: '#191c1d'
  on-secondary-fixed-variant: '#454748'
  tertiary-fixed: '#ffdcbd'
  tertiary-fixed-dim: '#ffb86e'
  on-tertiary-fixed: '#2c1600'
  on-tertiary-fixed-variant: '#693c00'
  background: '#f9f9f9'
  on-background: '#1a1c1c'
  surface-variant: '#e2e2e2'
typography:
  display:
    fontFamily: Inter
    fontSize: 48px
    fontWeight: '700'
    lineHeight: '1.1'
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: '1.2'
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: '1.2'
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: '1.3'
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: '1.6'
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: '1.5'
  label-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: '1.4'
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: '1.2'
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 8px
  container-padding: 32px
  gutter: 24px
  margin-mobile: 16px
  section-gap: 80px
---

## Brand & Style
This design system embodies a "Light Mode 2.0" philosophy, focusing on hyper-minimalism and neo-glassmorphism. The brand personality is ethereal, precise, and unobtrusive, designed to evoke a sense of clarity and weightlessness. 

The aesthetic prioritizes "airiness" through the strategic use of white space and translucent layering rather than structural lines. It is tailored for high-end SaaS, creative tools, or premium productivity platforms where focus and visual calm are paramount. The interface should feel like a series of light-refracting lenses stacked over a pure, infinite canvas.

## Colors
The palette is intentionally restricted to maximize the impact of the primary sky blue accent. 
- **Primary (#0EA5E9):** Used exclusively for high-intent actions, progress indicators, and active states.
- **Neutral/Surface (#FFFFFF):** The base layer for all views.
- **Off-White (#F9FAFB):** Used for subtle background differentiation in large layout areas.
- **Glass Overlays:** Transparency is a core functional color. Surfaces utilize high-alpha white with background blurs to maintain legibility while preserving the sense of depth.

## Typography
The system utilizes Inter for its systematic, neutral, and utilitarian qualities. Typography is treated as a structural element; hierarchy is established through size and weight rather than color shifts. 

Large display type should use tight letter spacing to maintain a modern, "tucked" appearance. Body text is optimized for long-form legibility with generous line heights to contribute to the overall feeling of "airiness."

## Layout & Spacing
The layout follows a fluid grid with expansive margins to reinforce the minimalist narrative. 
- **Desktop:** 12-column grid with 24px gutters. Use wide 32px-48px padding for containers to allow content to breathe.
- **Mobile:** 4-column grid with 16px margins. 
- **Rhythm:** All spacing must be a multiple of 8px. Use exaggerated vertical spacing between sections (e.g., 80px or 120px) to prevent the UI from feeling cluttered.

## Elevation & Depth
Depth is created through neo-glassmorphism and soft shadows. 
- **Surface Layering:** Use `backdrop-filter: blur(20px)` on all floating panels or navigation bars.
- **Shadows:** Avoid dark or harsh shadows. Use multi-layered, ultra-soft "ambient" shadows with a low opacity (2-5%) and a large blur radius (30px+). 
- **Separation:** Use 1px semi-transparent white borders (rgba(255,255,255,0.4)) on glass elements to simulate light catching the edge of the glass, providing definition without using heavy lines.

## Shapes
The design system uses a consistent 0.5rem (8px) base radius. This provides a balance between professional precision and approachable softness. Interactive components like buttons and tags should occasionally use "rounded-xl" (1.5rem) to signify their distinct tactile nature compared to structural layout cards.

## Components
- **Buttons:** Primary buttons use a solid sky blue fill with white text. Secondary buttons are "ghost" glass elements with a 20px blur and a subtle 1px white border.
- **Input Fields:** Backgrounds are `#FFFFFF` with a very thin `#F1F5F9` border. On focus, the border disappears and is replaced by a soft blue outer glow (box-shadow) and a translucent blue tint.
- **Cards:** Use a "Glass-on-White" approach. Cards should have a `rgba(255, 255, 255, 0.6)` background with a high blur, sitting on top of the `#F9FAFB` base.
- **Lists:** Items are separated by white space rather than lines. Use a subtle hover state that applies a very light sky blue tint (2% opacity) to the entire row.
- **Navigation:** Top bars and sidebars must be translucent glass with `backdrop-filter: blur(24px)`. Text and icons should be pure black or dark grey for maximum contrast against the blurred background.