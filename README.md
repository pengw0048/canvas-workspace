# Canvas Workspace

A persistent, freely arranged, collaborative 2D desktop canvas for macOS. Real application
windows, files, and web pages sit on the same plane as sticky notes, text, shapes, ink, frames,
images, and connectors. The screen is a viewport into that plane.

The product destination is defined in [spec/canvas-workspace-spec.md](spec/canvas-workspace-spec.md).
This repository is an incremental implementation toward that destination; see
[docs/CAPABILITIES.md](docs/CAPABILITIES.md) for what is verified, unverified, simulated,
unsupported, or not implemented yet.

## Build and run

Requirements: macOS 14 or later, Swift 6 toolchain (Xcode or Command Line Tools).

```sh
swift build                    # debug build
scripts/test.sh                # core model, merge, undo, persistence, control-arbitration tests
scripts/build-app.sh           # release build → dist/CanvasWorkspace.app
open dist/CanvasWorkspace.app
```

The app covers the display's visible area (menu bar and Dock stay available). For development,
run a normal resizable window instead:

```sh
.build/debug/CanvasWorkspace --windowed
```

### Permissions

- **Screen & System Audio Recording** — window previews, capture, live views, live sharing.
- **Accessibility** — positioning real windows during activation, closing windows through their
  normal close flow, and remote control of a shared application.

Without them the canvas still works; affected actions explain what is missing.

### Leaving the canvas

- `⌃⌥Space` returns input from an active application to the canvas.
- Workspace menu → **Exit to desktop** (`⌘Q`) restores admitted windows to their original place.
  Applications keep running.
- Admitted windows stay on screen behind the canvas, so a host crash never strands them.
  **Window → Bring Managed Windows onto a Display** recovers windows after a display change.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — architecture decisions.
- [docs/CAPABILITIES.md](docs/CAPABILITIES.md) — capability and gap report with evidence.
- [docs/USER-GUIDE.md](docs/USER-GUIDE.md) — gestures, copy/reference/live semantics, sharing, exit.
- [docs/STORAGE.md](docs/STORAGE.md) — durable storage and recovery for operators.

## Layout

- `Sources/CanvasCore` — document model (Automerge scope documents), commands, undo, transfer
  semantics, SQLite/asset storage, control arbitration, wire format. No AppKit.
- `Sources/CanvasHost` — the AppKit host: renderer, input, native windows (AX + ScreenCaptureKit),
  capture, clipboard/drag, files, browser surfaces, collaboration, automation socket.
- `Tests/CanvasCoreTests` — invariant tests.
- `scripts/` — app bundling and development automation helpers.
