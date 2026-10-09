<p align="center">
  <img src="Art/wordmark.svg" alt="SwiftCel" width="360">
</p>

<p align="center"><b>Frame-by-frame animation for Mac and iPad, with an old-school smoothing brush.</b></p>

SwiftCel is a small, native animation app in the spirit of the classic vector animation
tools of the late 2000s. Every stroke becomes a filled vector shape, drawings live on
keyframes along a timeline, and the brush re-fits your line when you lift the pen, which
gives it a slightly wobbly, hand-inked feel. A modern brush that keeps the line exactly
as drawn is one switch away.

It is written in Swift with Apple's own frameworks (AppKit, UIKit, Core Graphics and
AVFoundation) and no third-party code. There is no Xcode project: each app is built by a
short shell script.

## Features

**Drawing**
- Legacy brush with the classic re-fitted, wobbly outline, or a modern brush that keeps
  the stroke as drawn. Smoothing is adjustable for both.
- Pressure from a drawing tablet on the Mac and from Apple Pencil on iPad.
- Pencil (textured spray), eraser, paint bucket, eyedropper, line, rectangle and oval.
- Selection, Transform (move, scale, rotate, skew on Mac) and a Lasso that cuts through
  shapes, the way the classic lasso did.
- Painting merges with touching art of the same colour; erasing cuts holes.

**Animation**
- Layers with visibility, locking, opacity and drag-to-reorder.
- Clipping masks and a reference layer for filling colour under line art.
- Keyframes, blank keyframes and held frames; pick and move blocks of frames.
- Motion tweens for symbols and bitmaps, with easing presets and a graph editor (Mac).
- Onion skin with draggable range markers and tint settings.
- A soundtrack with waveform, scrubbing and looping playback.
- Storyboard panels, an animatic, and a printable storyboard sheet (Mac).

**Everything else**
- Library of symbols and bitmaps.
- Export to MP4 video (with sound), animated GIF, PNG sequence and SVG.
- Themes: five built in, and your own from four colours.
- A Home screen with all your animations.
- `.swcel` documents (plain JSON) that open on both Mac and iPad.

**On iPad**
- The same skin and layout as the Mac app, with a menu bar along the top.
- Apple Pencil with pressure, prediction and double-tap to switch to the eraser.
- Two fingers to pan, pinch to zoom and twist to rotate the stage.
- Two-finger tap to undo, three-finger tap to redo.
- Animations are kept in the app and appear in the Files app under On My iPad.

## Requirements

- **Mac:** macOS 13 Ventura or later, on Apple silicon or Intel. To build: Apple's command
  line tools (`xcode-select --install`) or Xcode.
- **iPad:** iPadOS 16 or later. To build: Xcode, opened once so it can finish installing
  its iOS components.

## Building

### Mac

Double-click `build-mac.command`. It compiles the app, puts `SwiftCel.app` next to the
script and opens it. Everything it prints is also saved to `build-mac.log`.

If macOS won't run the script, open Terminal in this folder and run:

```sh
bash build-mac.command
```

### iPad

Double-click `build-ipad.command`. It makes two things:

- `SwiftCel-iPad.ipa`, the app for a real iPad. It is unsigned, so install it with a
  sideloading tool that signs it with your Apple ID (such as AltStore or Sideloadly). With
  a free Apple ID the app has to be re-signed every 7 days.
- An iPad Simulator build, which the script opens in the Simulator if one is installed.

Everything it prints is also saved to `build-ipad.log`.

## Using it

The full guide is in [docs/Manual.md](docs/Manual.md). The essentials on the Mac:

| Key | Tool | | Key | Action |
|---|---|---|---|---|
| V | Selection | | F5 / Shift-F5 | Insert / remove frame |
| Q | Transform | | F6 / Shift-F6 | Keyframe / clear keyframe |
| L | Lasso | | F7 | Blank keyframe |
| B | Brush | | , and . | Previous / next frame |
| Y | Pencil | | Return | Play / stop |
| E | Eraser | | [ and ] | Brush size |
| K | Paint bucket | | Space-drag | Pan |
| I | Eyedropper | | Pinch or Command-scroll | Zoom |
| N, R, O | Line, rectangle, oval | | Command-Z / Shift-Command-Z | Undo / redo |
| H | Hand | | | |

## Project layout

```
Shared/          Code used by both apps: the document model, brush maths, tweening,
                 app state and undo, rendering and export, themes, onion skin,
                 storyboard and preferences
Mac/Sources/     The Mac interface (AppKit)
Mac/Resources/   Info.plist, app and document icons, splash picture, credits
iPad/Sources/    The iPad interface (UIKit)
iPad/Resources/  Info.plist and app icons
Art/             The wordmark
docs/            The manual
```

A few places to start reading:

- `Shared/Model.swift`: what an animation is. A `Doc` has `Layer`s, a layer has
  `KeyFrame`s, a keyframe has `Shape`s, and a shape is a filled outline and a colour.
  Everything is a value type, so undo is a stack of copies of the document.
- `Shared/Geometry.swift`: the brush. A stroke is laid down as overlapping round dabs,
  merged into one outline, thinned out with Ramer–Douglas–Peucker, then re-fitted with
  two quadratic curves per gap. The fewer points survive, the looser the curves, and that
  is the wobble.
- `Shared/AppState.swift`: the one object both interfaces talk to. It holds the open
  animation, the current tool and frame, the selection, undo and playback.
- `Shared/Render.swift`: draws a frame, and writes PNG, GIF, MP4 and SVG.

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## Credits

Designed by its author and written with Claude, from Anthropic. SwiftCel is an
independent project and is not affiliated with Apple or Adobe.
