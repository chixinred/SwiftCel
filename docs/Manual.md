# SwiftCel manual

SwiftCel is a frame-by-frame animation app for Mac and iPad. This guide covers the Mac
app first, then what is different on iPad. Building is covered in the
[README](../README.md).

- [Tools](#tools)
- [The brush](#the-brush)
- [Pencil](#pencil)
- [Selecting, transforming and the lasso](#selecting-transforming-and-the-lasso)
- [Right-click on the stage](#right-click-on-the-stage)
- [Timeline](#timeline)
- [Selecting frames](#selecting-frames)
- [Onion skin](#onion-skin)
- [Layers, clipping masks and reference layers](#layers-clipping-masks-and-reference-layers)
- [Library: symbols and bitmaps](#library-symbols-and-bitmaps)
- [Tweens](#tweens)
- [Graph editor](#graph-editor)
- [Audio](#audio)
- [Storyboard](#storyboard)
- [Exporting](#exporting)
- [Documents, Home and Open Recent](#documents-home-and-open-recent)
- [Workspace](#workspace)
- [Themes](#themes)
- [Settings](#settings)
- [Splash screen and credits](#splash-screen-and-credits)
- [On iPad](#on-ipad)

## Tools

| Key | Tool |
|---|---|
| V | Selection |
| Q | Transform |
| L | Lasso |
| B | Brush |
| Y | Pencil |
| E | Eraser |
| K | Paint bucket |
| I | Eyedropper |
| N | Line |
| R | Rectangle |
| O | Oval |
| H | Hand (or hold Space) |

`[` and `]` change the brush size. Space-drag pans; pinch or Command-scroll zooms.
SwiftCel > Keyboard Shortcuts (Command-/) shows a short list in the app.

## The brush

Legacy Mode, a switch in Properties that is on by default, picks the brush.

- **On: the classic brush.** When you lift the pen, the outline is re-fitted with a few
  curves, which gives the wobble. Smoothing (0 to 100) sets how loose that fit is. It is
  measured in screen pixels, so zooming in keeps more detail.
- **Off: the modern brush.** The stroke stays as you drew it, and Smoothing only steadies
  your hand.

Both live in `Shared/Geometry.swift` (`Brush.smoothedShape` and `Brush.modernShape`).

Every mark becomes a filled shape. Painting over art of the same colour merges with it,
and the eraser cuts holes.

## Pencil

The pencil sprays a dense scatter of one-pixel specks, heavier toward the middle of the
stroke. Size sets the width of the spray. Each pencil stroke stays its own shape instead
of merging with the art around it.

## Selecting, transforming and the lasso

**Selection (V).** Click art on any visible, unlocked layer. Shift-click adds art from
other layers, and dragging a box picks up everything it touches on every layer. Moving,
transforming, deleting, copying, recolouring and arranging then apply to all of it, each
piece staying on its own layer. Select All (Command-A) selects the art on every visible,
unlocked layer.

**Transform (Q).** Click art to select it, or select with V first, then:

- drag a corner square to resize both ways (hold Shift to keep proportions)
- drag a side square to stretch one way
- hold Command and drag a side square to skew
- drag the round knob above the box to rotate (Shift snaps to 15° steps)
- drag inside the box to move

It works on fills, symbols and bitmaps, and skew is kept through tweens. Modify also has
Flip Horizontal, Flip Vertical and Rotate 90°.

**Lasso (L).** Draw a loop around art to select it. Art wholly inside the loop is
selected. Art the loop crosses is cut in two along the loop, the way the classic lasso
worked, and the piece inside is selected, ready to move, recolour or delete on its own.
Drag what you picked to move it, and hold Shift to add to the selection. Symbol and bitmap
copies can't be cut; they are picked when the loop touches them. The lasso works on the
current layer.

## Right-click on the stage

Right-click a drawing to select it and get Convert to Symbol, Cut, Copy, Paste in Place,
Delete, Bring to Front, Send to Back, flips and 90° rotations, plus Edit Symbol and Break
Apart on a symbol. Right-click empty space for Paste in Place and Select All.

## Timeline

| Key | Action |
|---|---|
| F5 | Insert frame |
| Shift-F5 | Remove frame |
| F6 | Insert keyframe |
| Shift-F6 | Clear keyframe |
| F7 | Insert blank keyframe |
| , and . | Previous / next frame |
| Return | Play / stop |

The loop button at the bottom left of the timeline (or Command-L) switches between
repeating the animation and playing it once.

Right-click a frame for frame and keyframe commands, copying and pasting that frame's art,
tweens, and the onion skin switch. Right-click a layer's name for layer commands.

## Selecting frames

Click a frame to pick it. Drag across frames (and down across layers) to pick a block,
Shift-click to stretch the block to another frame, and Command-click to add or remove
single frames on any layer. The ruler along the top scrubs the playhead.

Drag any picked frame to slide the whole block, with its keyframes, earlier or later.
Right-click the block and choose Remove Frames (or press Shift-F5) to take the picked
frames out and close the gap; Insert Frames adds that many frames instead. Insert
Keyframe, Insert Blank Keyframe, Clear Keyframe, Create Tween and Remove Tween apply to
every picked frame when more than one is picked.

## Onion skin

View > Onion Skin (Option-Command-O) shows earlier and later frames as tinted ghosts. Two
markers appear on the timeline ruler either side of the playhead: drag them to choose how
many frames show each way (up to 20). Onion Skin Settings, in Properties or the View
menu, sets the tint colours and how faint the ghosts are.

## Layers, clipping masks and reference layers

New Layer is Shift-Command-L. Drag a layer's name up or down in the timeline to reorder
it. The dot and padlock beside each name hide and lock the layer, and Properties has the
selected layer's opacity.

**Clipping masks.** A clipped layer only shows where the layer beneath it has art, so you
can shade or texture a character without going over the edges. Several clipped layers in
a row all clip to the first unclipped layer below them. Clipped layers are indented with
a ↳ arrow in the timeline. Use Layer > Clipping Mask On or Off, or right-click the
layer's name. The bottom layer can't be a clipping mask.

**Reference layer.** Make your line art the reference layer and the paint bucket fills
between its lines while putting the paint on whichever layer you are working on, so
colour can live on its own layer under the lines. The reference layer has a ◎ after its
name, and only one layer is the reference at a time. Use Layer > Reference Layer On or
Off, or right-click the layer's name.

## Library: symbols and bitmaps

The Library panel sits under Properties.

- **Bitmaps.** Import Bitmap (Command-R) adds an image to the library and places it on
  the stage, shrunk to fit if it is bigger than the stage.
- **Symbols.** Select art, then New Symbol (F8). The art becomes one reusable item. Place,
  or double-click its row, puts more copies on the stage.

Double-click a symbol on the stage, or use Edit, to change its art; every copy updates.
Press Esc when done. Break Apart (Command-B) turns a copy back into loose art. Copies can
be moved, layered and deleted like any shape; the brush, eraser and bucket leave them
alone.

## Tweens

A tween moves symbol and bitmap copies smoothly between two keyframes.

1. Put a symbol (or bitmap) on a keyframe.
2. Go to a later frame and press F6 to add a keyframe there.
3. On that keyframe, move, scale or rotate the copy with the Transform tool.
4. Right-click any frame between the two and choose Create Tween (or Option-Command-T).
   The span turns the accent colour with an arrow.

Right-click the span again to pick the easing (Linear, Ease In, Ease Out, Ease In and
Out) or to remove the tween. Changing a copy partway through a tween adds a keyframe
there automatically. To fade a copy, lower the opacity in the fill colour picker; the
tween blends that too. Loose brush art doesn't tween, so turn it into a symbol first
(F8). Copies are paired between keyframes by library item, in order.

## Graph editor

Timeline > Graph Editor (Option-Command-G), or Custom Curve in a tween's right-click
menu, shows the easing of the tween under the playhead as a curve: time runs left to
right, progress bottom to top. Drag the two round handles to reshape it. Pulling a handle
above "end" or below "start" makes the motion overshoot or wind up first. The buttons
underneath are presets.

Play Tween loops just that tween, so you can reshape the curve and watch the motion
change as it plays. Stop, or Return, ends it.

## Audio

File > Import Audio (Shift-Command-I) adds one soundtrack (WAV, AIFF, MP3 or M4A). It
starts at frame 1, plays in sync with Play, and shows as a waveform row under the layers.
Dragging or stepping through the timeline plays the sound at that frame. On the Mac the
document stores where the sound file is, not a copy, so keep the file where it is.
File > Remove Audio takes it off.

## Storyboard

View > Storyboard (Shift-Command-B) opens the board. New Panel starts one and adds a
Storyboard layer to the timeline. Every panel is a drawing on that layer, so you draw
panels on the stage with the normal tools.

In the board window, click a panel to go to it, and type its caption and how many frames
it holds for at the bottom. Duplicate, Delete, Earlier and Later shape the sequence, and
later panels shift automatically. Play Animatic plays the board from the start with your
audio. Export Sheet saves a printable PDF, six panels to a page with captions and
timings, and Export Video gives you the animatic as a movie.

When you start animating, add layers under the Storyboard layer, lower its opacity in
Properties to use it as a guide, and hide it before exporting.

## Exporting

- File > Export Video (Option-Command-E): an MP4, with the soundtrack.
- File > Export Animated GIF (Shift-Command-E).
- File > Export PNG Sequence: one PNG per frame.
- File > Export Frame as SVG: the current frame as vector art. Clipping masks are kept.

GIF, PNG and SVG exports are silent.

## Documents, Home and Open Recent

Animations save as `.swcel` files, which are plain JSON. After a build, Finder shows them
with the SwiftCel document icon, and double-clicking one opens it.

Home opens when SwiftCel starts (File > Home, Shift-Command-H, brings it back). It shows
a New Animation card and a card for every animation you have opened or saved, newest
first, with a picture of its first frame. Click a card to open it. Right-click one for
Show in Finder or Remove from Home, which only takes it off the list. Open Other finds a
file that isn't listed.

File > New asks for the stage size (with presets), the frame rate and the background
colour. Modify > Document Settings (Command-J) changes the same things for the open
animation, and so does the Document section at the bottom of Properties. File > Open
Recent lists the last ten animations you opened or saved.

## Workspace

Drag a panel by its header strip (the row of small dots) to move it to the other side of
the window. Drag the gap beside Properties or the Timeline to resize. The Workspace menu
can hide panels or reset the layout, and the arrangement is remembered between launches.

## Themes

The Theme menu switches the look of the whole app. Five are built in: Porcelain,
Graphite, Midnight, Paper and Bolt. Theme > Customize Theme (Shift-Command-T) lets you
pick four colours (panels, accent, text, and the area around the stage); every other
shade is worked out from those. Save Theme adds it to the menu. The theme is remembered
between launches.

## Settings

SwiftCel > Settings (Command-,):

- **Interface size** makes everything in the main window larger, up to double size.
- **Timeline frame width**: wider frames are easier to click.
- **Splash screen**: whether it shows at launch.
- Whether Home shows at launch.

If Properties is too short to show everything, scroll it.

## Splash screen and credits

The splash shows for a few seconds at launch (click to skip) and again from SwiftCel >
About SwiftCel. The picture is `Mac/Resources/Splash.png` and the wording under the sign
is `Mac/Resources/Credits.txt`; edit either and rebuild. In `Credits.txt` each line is
one line on the plate, the first line is the bold one, and `{version}` becomes the app's
version number.

## On iPad

The iPad app has the same look and layout as the Mac app: tools down the left, Properties
and Library down the right, the timeline under the stage, and a menu bar along the top.
The wordmark at the left of the menu bar is the app menu, with About, Preferences and
Home.

**Drawing and moving around**

- Apple Pencil draws, with pressure. Double-tap the side of the Pencil to switch between
  the eraser and the last tool.
- Two fingers drag the stage, pinch to zoom and twist to rotate it. A turned stage snaps
  upright, or to a quarter turn, when you let go close to one. View > Reset Rotation puts
  it back upright, and Fit Stage on Screen also straightens it.
- A two-finger tap undoes and a three-finger tap redoes.
- Once a Pencil has been used, one finger moves the stage instead of drawing. Turn on
  View > Draw with a Finger, or the same switch in Preferences, to draw with a finger.

**Timeline.** Tap a frame to go there, drag across frames to pick a block, and drag a
picked keyframe to move what is picked. Drag in the ruler to scrub and drag the onion
skin markers to set their range. Drag a layer's name to reorder it and double-tap it to
rename. Two fingers scroll the timeline. Playback and keyframe buttons are in the strip
along its bottom, since there is no right-click.

**Selecting.** The Selection, Transform and Lasso tools replace the selection when you
tap. Turn on Edit > Tap Adds to Selection to add to it instead.

**Menus.** File, Edit, View, Modify, Timeline and Layer hold the same commands as on the
Mac, including clipping masks and the reference layer under Layer.

**Saving.** Work is saved automatically as you go. Animations are kept in the app and
show in the Files app under On My iPad > SwiftCel. Touch and hold a card on Home to
rename, duplicate, share or delete an animation. Import on Home brings in `.swcel` files
from elsewhere.

**Audio.** File > Import Audio copies the sound into the app, so it stays with the
animation even after reinstalling. A soundtrack added on iPad shows as missing if the
animation is opened on the Mac.

**Exporting.** File > Export shares the current frame as PNG or SVG, the animation as an
animated GIF or MP4, or the `.swcel` file itself, through the share sheet.

**Preferences.** Open it from the wordmark menu or the gear on Home. Pick a theme, make
your own from four colours (and name and save it, or delete one you saved), switch
drawing with a finger, and set the timeline's frame width.

**Not on iPad yet:** the graph editor, the storyboard, onion skin tint settings, skewing
and rearranging the panels. See the [roadmap](../ROADMAP.md).

**Show Performance.** View > Show Performance adds a small readout to the stage: the
screen's frame rate, Pencil samples per second and how late they arrive, and how long
drawing the stage and finishing a stroke take. It is there for tracking down slowness.
