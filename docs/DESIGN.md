# Xnap — Design

Xnap is a menu bar screenshot app for macOS 14+. It has three promises:

1. **Handy** — one shortcut, pick an area, and the image is on the clipboard.
2. **Scrolling capture** — capture a whole page, even the parts that don't fit on screen.
3. **Private** — the app can't reach the network. macOS enforces this, not just a policy.

## Architecture

```
┌──────────────────────────── Xnap.app (sandboxed, no network) ────────────────────────────┐
│                                                                                                 │
│  HotKeyCenter (Carbon) ─┐                                                                        │
│  Status bar menu ───────┼─► CaptureCoordinator ─► SelectionOverlay (frozen snapshot, per screen) │
│                         │         │                        │                                     │
│                         │         │            ┌───────────┴────────────┐                        │
│                         │         │         area / OCR             scrolling                     │
│                         │         │            │                        ▼                        │
│                         │         │            │          ScrollCaptureSession                   │
│                         │         │            │   SCStream(region) ─► StitchingPipeline         │
│                         │         │            │   HUD · highlight · auto-scroll   (serial queue)│
│                         │         │            │                        │  XnapCore       │
│                         │         │            │                        │  ScrollStitcher        │
│                         │         ▼            ▼                        ▼                        │
│                         │     OutputManager: clipboard (PNG + lazy TIFF) │ file (~/Pictures/…)    │
│                         │         ▼                                                              │
│                         │     FloatingPreview ─► Editor · Pin · Copy Text (Vision) · Drag out    │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Module     | Contents                                                                                             |
| ---------- | ---------------------------------------------------------------------------------------------------- |
| `XnapCore` | `Bitmap`, `FrameSignature`, `ScrollStitcher`. Pure Swift and CoreGraphics, no UI, fully unit-tested. |
| `Xnap`     | The app: capture, the scroll session, the editor, output, settings.                                  |

### Capture flow

1. A **global hotkey** comes from Carbon `RegisterEventHotKey`. It needs no Accessibility or Input
   Monitoring permission and works in the sandbox. Each action has a clipboard variant and a
   file variant (the default scheme is ⌃⇧N and ⌃⌥⇧N).
2. **Snapshot:** ScreenCaptureKit's `SCScreenshotManager` grabs every display with
   Xnap's own windows excluded.
3. **Selection overlay:** a borderless window per display shows its frozen snapshot, so menus and
   hover states are preserved. You can drag an area or click a window, which snaps to its frame
   using `CGWindowListCopyWindowInfo`. A loupe shows pixel coordinates and the hex color, and
   **C** copies the color. It is built from CALayers, so tracking the pointer is cheap even on 5K screens.
4. **Delivery:** the image goes to the clipboard as PNG, with TIFF supplied lazily on request, or to a file.
   Files carry their DPI (144 for Retina), so they open at the correct point size.
5. **Floating preview:** a thumbnail with quick actions (Annotate, Copy, Save or Show in Finder,
   Pin, Copy Text). You can drag it into any app. It dismisses itself unless you're hovering over it.

## Scrolling capture

### Session

- After you pick a region, a click-through window dims the rest of the screen and draws a
  marching-ants border. A non-activating HUD sits beside the region. Focus goes back to the
  captured app, so your trackpad, mouse wheel, Page Down and Space all keep working normally.
- An `SCStream` captures only that rectangle (`sourceRect`) at native resolution and 20 fps,
  in sRGB BGRA, with the cursor hidden. Only frames whose content changed are delivered.
  Xnap's own windows are excluded, so the HUD and border never end up in the image.
- ⏎ (or pressing the shortcut again) finishes and ⎋ cancels. Both are temporary hotkeys, so
  they work while the other app has focus.
- **Auto-Scroll** (optional, needs Accessibility) posts continuous pixel scroll events, the way a
  trackpad does, at the pointer. It waits for the frame that shows the new position, works
  out the scroll direction from the first move, halves its step if an app scrolls further than
  asked, and stops by itself after three steps with no movement (the end of the page). If you
  move the pointer out of the region, it pauses.

### Stitching algorithm (`ScrollStitcher`)

The page being scrolled is modelled as a _document_. Frame _k_ shows document rows
`[offset_k, offset_k + H)`, except for rows fixed on screen: sticky headers at the top
(`fixedTop`) and toolbars or footers at the bottom (`fixedBottom`).

1. **Row signatures** (`FrameSignature`). For each pixel row:
   - an exact hash (colors quantized to 5 bits, about 512 sampled columns),
   - a "flat" flag for rows with almost no detail, like a blank background,
   - 32 average-luminance bins, a descriptor that tolerates noise.

   The right edge is left out, so overlay scrollbars that move while you scroll don't disturb matching.

2. **Offset voting.** Every detailed row of the new frame votes for the offsets where an identical
   row exists in the previous frame. Rows that repeat more than 4 times are ignored, as are
   offsets whose overlap would be too small. The top candidates are **verified**: at least 60% of
   the detailed overlapping rows must match exactly.
3. **In-place changes.** Hover effects and blinking carets change the frame without moving it. If
   80% or more of the rows are unchanged in place, the frame counts as "unchanged". It becomes the
   new reference but contributes nothing.
4. **Fallback search** for content that doesn't re-render pixel-identically (fractional scroll
   positions, animations). An exhaustive search over offsets minimizes the mean feature distance,
   with early exit. It includes offset 0, so noise without movement stays "unchanged".
5. **Fixed regions** are decided at the first real movement. They are the leading and trailing
   rows that stayed identical in place, each capped at 40% of the frame height. Only the band
   between them is matched and appended.
6. **Appending.** Only rows beyond what's already committed are added, so scrolling back up
   and down again is harmless. The footer is added once at the end, taken from the frame
   scrolled furthest down. If the footer estimate is too generous (for example, blank space at
   the bottom), the output is still continuous, because the band is appended row by row up to
   exactly where the footer starts.
7. **Lost track.** If a frame has no overlap with the previous one (you scrolled too far between
   frames), the frame is rejected and the reference is kept. The HUD asks you to scroll back a
   little, and stitching resumes once the frames overlap again. A mismatched frame is never
   glued on, so jumps can't corrupt the image.

Cost: about 2 ms per frame for a 1600×1800 px (Retina) region in release builds, and about 5 ms
when the fallback search runs. Both are far below the 50 ms available per frame at 20 fps. Memory
holds only the appended slices and one reference signature. The height limit defaults to
30,000 px.

**Known limits:** a viewport that is entirely blank (a long empty gap) can't be matched, because
nothing moves visibly. Content that changes while you scroll, such as carousels or video, can
cause brief "lost track" warnings. Horizontal scrolling isn't supported. Capture starts at the
position shown when you begin; scroll to the top first if you want the whole page.

## Editor

- **Model:** `EditorDocument` holds `State { image, annotations }` as values plus a `CGImage`.
  Each edit swaps the whole state, so undo and redo are cheap snapshots through `NSUndoManager`,
  and a drag counts as one undo step. Cropping is destructive to the image but undoable, and it
  moves the annotations with it.
- **Annotations:** arrow (tapered, with a swept-back head), line, rectangle and ellipse (outline or
  filled), pen and highlighter (smoothed; the highlighter uses multiply blending), text (edited
  in place), numbered steps that count up automatically, pixelate, and crop. Geometry is stored
  in image pixels, so exports are exact at any zoom.
- **Pixelate** averages blocks of the _original_ pixels (at least 10 pt blocks, aligned to a grid).
  Unlike a blur, this destroys the text underneath.
- **Rendering:** a single `AnnotationRenderer` draws both the on-screen canvas and the flattened
  export, so what you see is what you copy.
- **Interaction:** select, move, resize handles, ⇧ to constrain (45° lines, squares), arrow keys
  to nudge, single-letter tool keys (V A L R O P H T N B C), 1–8 for colors, ⌫ to delete.
  Clicking an existing shape with any tool picks it up.
- **More tools:** Copy Text (Vision OCR, on-device), Pin to Screen (a floating always-on-top
  reference with adjustable opacity), and Save / Save As in PNG or JPEG.

## Privacy and security

| Mechanism                                                   | Effect                                                                                                                                                                                                                             |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App Sandbox **without** `network.client` / `network.server` | macOS denies every socket, outgoing and incoming.                                                                                                                                                                                  |
| No networking code                                          | No URLSession, analytics, update checks, crash reporters or accounts.                                                                                                                                                              |
| Files                                                       | Only `~/Pictures` (the default save folder) and locations you pick yourself (Save As, custom folder via a security-scoped bookmark).                                                                                               |
| OCR                                                         | Apple Vision, on-device.                                                                                                                                                                                                           |
| Runtime check                                               | Settings › Privacy reads the app's own entitlements with `SecTaskCopyValueForEntitlement` and shows whether the network is actually blocked. A development build without the sandbox is labelled honestly, not shown as protected. |
| Permissions                                                 | Screen Recording (required). Accessibility (optional, only for Auto-Scroll).                                                                                                                                                       |

## Decisions

- **AppKit with SwiftUI islands.** Overlays, the canvas and panels need precise window levels,
  event handling and layers, so they're AppKit. The toolbar, HUD, preview and Settings are SwiftUI.
- **Carbon hotkeys** rather than a CGEvent tap: no extra permission is needed.
- **Frozen-frame selection** rather than a live overlay: you get exactly what you saw, menus are
  capturable, and there's one capture path for area, window and OCR.
- **SCStream for scrolling** rather than repeated screenshots: lower latency, it delivers only
  changed frames, and it can exclude the app's own UI.
- **SwiftPM with a bundling script** rather than an Xcode project, so it builds with the Command Line
  Tools alone. It avoids SwiftUI's `@State` macro, whose plugin ships only with Xcode in the
  macOS 27 SDK, and uses small `ObservableObject`s instead.
