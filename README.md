# Xnap - A handy screenshot app for macOS

A handy screenshot app for macOS with rich image tools. It is easy to use and fully local.

- **Scrolling capture:** capture a whole page, including the parts that don't fit on screen.
  Just scroll, or let Auto-Scroll do it. Sticky headers and toolbars are kept once.
- **Area, window and full-screen capture** from a frozen frame, with a magnifier loupe and a color picker.
- **Clipboard by default.** A different shortcut saves straight to a file.
- **Editor:** arrows, shapes, pen, highlighter, text, numbered steps, pixelate (redact) and crop,
  with undo, zoom, Copy Text (OCR) and Pin to Screen.
- **Private by construction:** it runs in the App Sandbox with no network entitlement, so macOS
  blocks all connections. Settings › Privacy verifies this on the running copy.

## Shortcuts

| Action                      | Clipboard | Save to file |
| --------------------------- | --------- | ------------ |
| Capture area or window      | ⌃⇧1       | ⌃⌥⇧1         |
| Scrolling capture           | ⌃⇧2       | ⌃⌥⇧2         |
| Capture full screen         | ⌃⇧3       | ⌃⌥⇧3         |
| Copy text from screen (OCR) | ⌃⇧4       | —            |

Every shortcut can be changed in Settings › Shortcuts.

**During selection:** drag to select an area, or click to take the window under the pointer.
⇧ makes a square, **C** copies the pixel color, ⏎ takes the window or screen, and ⎋ cancels.

**During a scrolling capture:** scroll the content inside the frame. Press ⏎ (or the shortcut
again) to finish, or ⎋ to cancel. _Auto-Scroll_ in the HUD scrolls for you and stops at the end
of the page.

**In the editor:** tools V A L R O P H T N B C, colors 1–8, ⇧ to constrain, arrow keys to nudge,
⌫ to delete, ⌘C to copy, ⌘S to save, ⇧⌘T to copy text, ⌃⌘P to pin.

## Build and run

You need macOS 14 or later and Swift 6 (the Command Line Tools are enough; Xcode isn't required).

```sh
make app        # builds and signs build/Xnap.app (release, sandboxed)
make run        # builds, then opens the app
make test       # unit and rendering tests
make bench      # stitcher performance, release build
```

On first launch, allow **Screen Recording** in System Settings › Privacy & Security.
**Accessibility** is optional and only used by Auto-Scroll.

macOS ties permissions to the code signature. The default ad-hoc signature changes on every
build, so you re-grant Screen Recording after each rebuild. To keep the permission, sign with
a real identity:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

Screenshots are saved to `~/Pictures/Xnap` by default. You can change this in Settings.

## Project layout

```
Sources/XnapCore/     Scroll stitching engine (pure, unit-tested)
Sources/Xnap/
  App/                       Entry point, menus, status item
  Capture/                   ScreenCaptureKit snapshots, selection overlay, coordinator
  Scrolling/                 Scroll session, SCStream, HUD, auto-scroll
  Editor/                    Annotation model, renderer, canvas, toolbar, window
  Output/                    Clipboard, files, OCR
  UI/                        Floating preview, toast, pin window
  Settings/                  Preferences, Settings window, shortcut recorder
  Shortcuts/                 Global hotkeys and capture actions
Resources/                   Info.plist, entitlements, icon
scripts/                     App bundling and icon rendering
docs/DESIGN.md               Architecture, stitching algorithm, privacy model
```

See [docs/DESIGN.md](docs/DESIGN.md) for how scrolling capture works and why.
