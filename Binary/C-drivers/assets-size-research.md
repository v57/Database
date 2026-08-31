# Reducing the Database.app Assets.car size — research findings

Date: 2026-08-30. All sizes measured empirically on this machine with `actool`
(Xcode 27) compiling real test catalogs. The app's `Assets.car` is 4,982,152
bytes (~4.75 MB) and is 100% app-icon content.

## What the 4.75 MB actually is

The entire Assets.car is the **layered app icon** (`AppIcon.icon`), a single
334-byte SVG + `icon.json`. It rasterizes into **three 1024x1024 PNG renders**
(one per appearance):

| Appearance | Extracted PNG size |
|---|---|
| `UIAppearanceAny` (light/color) | 972 KB |
| `UIAppearanceDark` | 1066 KB |
| `ISAppearanceTintable` (mono) | 602 KB |

Compiling that layered `.icon` with actool → **4865 KB Assets.car**
(matches the real 4.75 MB).

The icon is red-gradient background (from `icon.json` `automatic-gradient`) +
white foreground mark (from `f.svg`). The high entropy comes from the subtle
extended-sRGB red gradient across 3 appearances.

## Bottom line: the size is NOT waste, it's the icon

There are no stray images or junk. The 5 MB IS the icon. Reducing it means
reducing what the icon costs.

## The winning lever: simplify the SOURCE image (biggest effect)

Measured with a classic single-1024 PNG `.appiconset` (compile → Assets.car):

| Source image byte size | Assets.car size |
|---|---|
| Solid color only (451 B PNG) | 24 KB |
| Solid + white mark (42 KB PNG) | 95 KB |
| Full-quality extracted icon (994 KB PNG) | 1738 KB |
| Simplified + quantized (8 KB PNG) | 45.8 KB |

The CAR's icon slot size is **directly proportional to the source pixel
entropy** — flat/simple/quantized icons compress to a tiny fraction. A flat,
2-color or few-color icon that stays in `sRGB` can be ~45-95 KB instead of the
1.7 MB one-appearance / 4.75 MB three-appearance you have now.

## Variant-by-variant results

### 1. Silently replace PNG with HEIC (named .png) — PARTIALLY WORKS, for non-icon images
- App icons: **NO.** actool rejects HEIC/AVCI as an app-icon source
  (`"did not have any applicable content"`). Apple requires sRGB PNG for app
  icons (HIG). You cannot get a smaller app icon via HEIC.
- Normal image sets (the app's non-icon images): **YES**, if the file extension
  is `.heic`/`.heif` (`.avci` is silently dropped). Measured on one 1024 image:
  - PNG → 641 KB car
  - HEIC → 433 KB car (**32.5% smaller**), stored as real `HEIF` in the car
- JPEG works too and is far smaller — measured **42.8 KB** (93% smaller than PNG)
  — but JPEG has **no alpha channel**. Use only where transparency isn't needed.
- So for any image sets/catalog images (not icons), switching source to `.heic`
  gives ~33% off; `.jpg` gives ~93% off when no alpha is needed.

### 2. Dark-mode icon auto-fallback ("apps that never updated") — CONFIRMED
Apple HIG (App icons → Appearances) states: **"the system automatically
generates variants you don't provide."** So if you ship ONLY the Any/Light icon,
the system derives Dark and Tinted automatically. This is exactly the "old apps
got dark icons without updating" behavior you remembered — it's real, and it's
still the behavior. You can drop the explicit Dark + Tinted layers and let iOS
generate them. (The layered `.icon` format won't compile without the appearance
structure, so the way to exploit this is a **classic `.appiconset` with one
PNG**, not a stripped `.icon`.)

### 3. Flat / 2-color icon auto-styling — CONFIRMED
The HIG "clear light/clear dark/tinted light/tinted dark" appearances, and the
optimization where a **tinted/monochrome tintable icon** (grayscale) is auto
tinted by the system to the user's chosen accent — this is real. A flat icon
that carries the shape in a single color benefits from the system tinting it
automatically, so you don't carry a large tinted render.

## Recommended action (biggest → smallest win)

1. **Switch the app icon from the layered `.icon` to a classic `.appiconset`
   with ONE flat/simplified sRGB PNG at 1024×1024.** The system auto-generates
   Dark + Tinted. Expected: ~45-95 KB below anywhere from 1738 KB
   (one-appearance) to 4865 KB (current three-appearance).
   - This alone takes the Assets.car from ~4.75 MB → under ~1 MB.
   - Even keeping the current gradient art, going to a single-appearance
     classic appiconset → ~1.7 MB (still a 64% / ~3.1 MB savings).
2. **If you keep the layered `.icon`**, simplify the art (fewer colors, hard
   edges, no noise gradient) so each 1024 render compresses harder.
3. **For non-icon images** in the catalog: convert sources to `.heic` (~33% off)
   or `.jpg` (~93% off, no alpha).

## Hard constraints discovered (what you CANNOT do)
- App icons MUST be sRGB PNG (no HEIC/JPEG/WebP/SVG-only) per Apple HIG and
  enforced by actool.
- App icons must be opaque (no transparency) — a transparent-foreground icon is
  rejected ("did not have any applicable content"). The system provides the
  background; supply an opaque 1024 PNG.
- Reducing the source pixel below 1024 does not shrink a 1024 slot (actool
  upscales; measured no gain).
- `compression-type: lossy` has NO effect on app icons (always stored premium).
  It only affects normal image sets.
- `--compress-pngs` has no effect on app icons (already pngcrushed).
- The app is code-signed and Assets.car is sealed in CodeResources; any manual
  edit invalidates the signature. A normal Xcode rebuild re-signs automatically.

## Measuring reproducibility
All numbers above come from `xcrun actool <cat>/Assets.xcassets --compile <out>
--platform iphoneos --minimum-deployment-target 13.0 --app-icon AppIcon
--output-partial-info-plist <p>.plist`, then `stat` the produced Assets.car.
