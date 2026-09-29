# Architecture Decision Record

Status: working decisions for the first implementation. Each decision is a proposed default from
`spec/canvas-workspace-spec.md` §1.2 and §18, made concrete. Consequential departures are
recorded here with evidence.

## ADR-1 Host: native macOS AppKit application (Swift)

- One Swift Package Manager executable (`CanvasHost`) bundled into `CanvasWorkspace.app` by
  `scripts/build-app.sh`. Builds with the Command Line Tools only; no Xcode project.
- The canvas is a borderless window per display that takes the wallpaper's place: it fills the
  display, and the menu bar and the Dock stay visible above it, so application menus, app
  switching, and system UI keep working and the menu bar does not appear and disappear as input
  moves between the canvas and real apps. The canvas lives on one Space. A macOS full-screen Space
  was rejected because activating another app would switch Spaces and real windows could not come
  above the canvas; a desktop-level window was rejected because real windows would always float
  above canvas content.
- Why: ScreenCaptureKit, Accessibility (AX), NSWorkspace, NSPasteboard, NSDraggingSession, file
  promises, IME (`NSTextInputClient`), and Carbon global hot keys are all in-process. A web-only
  stack cannot reach these; a web renderer inside a native host would need a bridge for every one
  of them.

## ADR-2 Renderer: Core Animation layer tree driven by a Swift scene model

- Every object is a `CALayer` subtree. A single container layer carries the camera transform, so
  pan and zoom change one transform and are GPU-composited.
- World coordinates are `Double`. Layer positions are `world - rebaseOrigin`; the origin is rebased
  when the camera moves far away, which keeps `CGFloat`/`Float` precision at distant coordinates.
- Hit testing, selection, and layout run in world space on the model, not on layers.
- Text editing uses a real `NSTextView` overlaid at the object's projected rect, so IME, text
  selection, spell checking, and accessibility come from AppKit.

## ADR-3 Document model: Automerge documents per publication scope

- The workspace is the union of *scope documents*. Each scope document is an Automerge document
  with the same schema. The private scope never leaves the device. Each shared scope (a published
  frame, selection, or whole workspace) has its own document that is synchronized.
- Consequence: unpublished content is never serialized to a participant, which satisfies the §11
  requirement to protect it by construction instead of by UI hiding. Publishing moves an object
  from the private document to a shared document.
- Geometry is stored as one atomic scalar per object, so concurrent moves never merge `x` from one
  move with `y` from another (§9.2). Text uses Automerge text for operation-level merging.
  Deletion sets a tombstone flag. Automerge change hashes deduplicate replayed operations, so a
  reconnect cannot apply a frame move twice.
- Undo is per author: each local command records before/after values; undo applies the inverse only
  where the current value still equals the author's value, and reports conflicts otherwise.

## ADR-4 Persistence: SQLite (WAL, `synchronous=FULL`) plus content-addressed asset files

- Automerge incremental chunks are appended in SQLite transactions; the store compacts them.
- Asset bytes are written to `staging/`, `fsync`ed, and renamed into `assets/<sha256>` *before* the
  transaction that references them commits. Startup removes interrupted staging files. A saved
  object therefore never points to missing bytes (§8.1).
- Restricted local data (file bookmarks, absolute paths, window hints, recovery descriptors,
  personal cameras) lives in local tables, not in any scope document.

## ADR-5 Native applications: hybrid preview + real window activation

- Admitted windows stay real windows owned by their process. While inactive, the real window sits
  *behind* the canvas window at an on-screen position, and the canvas shows a ScreenCaptureKit
  preview at the object's world location.
- Activation moves the camera to 1:1 around the object, moves the real window to the object's
  projected rect with AX, and raises it above the canvas. Returning to the canvas captures a fresh
  preview and raises the canvas window again.
- Because windows are never moved offscreen, a host crash or exit leaves them usable. Exit also
  restores recorded original placement.
- This is the candidate strategy that §7.2 requires us to prove with real applications; results are
  tracked in `docs/CAPABILITIES.md`.

## ADR-6 Collaboration transport: Network.framework TCP with TLS pre-shared key

- A host shares a scope and exposes a listener; participants join with an invite code that derives
  the TLS PSK. Bonjour advertises on the local network.
- Channels on one connection: Automerge sync messages, asset requests (served only for assets
  referenced by that scope), ephemeral presence, live surface video, and control messages.
- Live surfaces stream as hardware H.264 (VideoToolbox), as video calls do: real-time rate control,
  no frame reordering, keyframes with parameter sets on request, and bitrate adapted to the slowest
  member. A member whose sends back up skips frames until the next keyframe. Members decode into
  IOSurface-backed buffers that layers show directly. The video rides the same TLS/TCP connection;
  UDP with SRTP and loss-tolerant pacing, as WebRTC uses, is the next step for lossy networks.
- Remote control uses session-bound grants with a monotonically increasing generation. The host
  rejects events carrying an old generation, clears held keys/buttons on every transfer, and
  verifies the target window family before posting each event.

## ADR-7 Browser surfaces

- Reference page: a URL source with captures and annotations; opens in the user's browser.
- Provider-collaborative document: a reference that opens the provider document with each person's
  own account; no credentials are copied.
- Shared browser runtime: a `WKWebView` owned by the host. It is a real browser session that is
  embedded directly in the canvas, published as frames, and operated by one controller.
