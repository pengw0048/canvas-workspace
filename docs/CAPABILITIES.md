# Capability and Gap Report

Status as of 2026-09-29. Test profile: one MacBook Pro (Apple M4 Max, 64 GB), macOS 27.0.1,
built-in display at 2× scale, Swift 6.4 Command Line Tools. Fixture applications: TextEdit
(system), the host's embedded WebKit browser. All fixtures are non-sensitive local files.

The product is **not complete**. The §7.2 native gate now passes for activation, 1:1 placement,
typing and saving in a real app, app menus, a save sheet above the canvas, return by hot key and
by canvas click, exit restoration, and reconnection after host restart. Native drag in both
directions, IME, a second unrelated app, display changes, and remote control of native apps are
still unverified.

Legend: **Verified** — exercised on this Mac with real applications, real system clipboard,
real files, or independent processes, with evidence. **Unverified** — implemented, not yet
exercised end to end. **Simulated** — exercised, but with a stand-in noted in the row.
**Unsupported** — not possible on this host or by design. **Not implemented** — still missing.

## Evidence summary

| Evidence | Where |
| --- | --- |
| Native objects on one plane (frame, sticky, text, shape, rotated ellipse, ink) in the real window | [evidence/native-objects.png](evidence/native-objects.png) |
| Real TextEdit window admitted, frozen region capture, live preview, and live view | [evidence/textedit-live-view.png](evidence/textedit-live-view.png) |
| Two real windows on the canvas with an overlapping note | [evidence/admitted-windows.png](evidence/admitted-windows.png) |
| Activation: real window placed 1:1 on its surface; TextEdit owns the menu bar | [evidence/activation-1to1.png](evidence/activation-1to1.png) |
| TextEdit Save As sheet usable above the canvas | [evidence/save-dialog-over-canvas.png](evidence/save-dialog-over-canvas.png) |
| After clicking the canvas: input returned, camera restored, preview shows the typed text | [evidence/returned-with-fresh-preview.png](evidence/returned-with-fresh-preview.png) |
| Annotated capture pasted into the real document; the image as stored inside `deliverable.rtfd` | [evidence/deliverable-pasted-graphic.png](evidence/deliverable-pasted-graphic.png) |
| Bold, italic, and link formatting in a text object and its pasted copy | [evidence/rich-text.png](evidence/rich-text.png) |
| Mixed selection copied to the system clipboard, read back by a separate process as PNG | [evidence/clipboard-composition.png](evidence/clipboard-composition.png) |
| Invariant tests (17): merge, atomic moves, undo conflicts, tombstones, crash-safe storage, asset durability, publication, copy semantics, connectors, frames, splices | `swift test` |
| Automation transcript commands used below | `scripts/cw.sh`, `Sources/CanvasHost/Automation.swift` |

## Canvas and document (package B)

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Continuous pan/zoom camera, dot grid, level of detail with hysteresis | Verified (rendering) | Screenshots at several zoom levels. Gesture feel not yet reviewed by a person. |
| Sticky, text, shape (rect/ellipse/line/arrow), ink, highlighter, eraser, frame, image, connector | Verified (rendering and storage); eraser Unverified | Created through automation; pointer creation paths not exercised by a person. |
| Rotation for native objects; app/file previews stay upright | Verified (rendering) | |
| Stable identities, fractional stacking, bring forward/back, select behind | Verified (unit) / Unverified (UI) | |
| Frames on the same plane; move carries descendants; resize changes boundary only; acyclic membership | Verified (unit) | Drop reparent preview and publication prompt not exercised by pointer. |
| Groups, align, distribute, tidy with preview (one undoable command) | Unverified | Core commands exist; tidy preview uses a modal confirmation. |
| Connectors track targets; removed endpoint is kept and marked | Verified (unit) | |
| Per-author undo that does not overwrite later edits by others | Verified (two processes) | Alice's undo reported a conflict and kept Bob's later move. |
| Durable local autosave, visible save state, failure retry and export | Verified | `fail chunks` → "Not saved…", kill -9, restart shows only confirmed state. |
| Asset bytes durable before any object references them | Verified | `fail assets` → capture creates no object. Unit test covers ordering. |
| Personal camera per user and display, navigation back, focus view | Verified (camera restore) / Unverified (focus, back) | |
| Search over text, titles, filenames, apps, URLs, named places | Unverified | |
| Rich text formatting and links in text objects | Verified (render, marks sync, RTF/HTML copy, formatted paste) | Bold, italic, links as Automerge marks. ⌘B/⌘I/⌘K editing not exercised by a person. Formatting changes are not part of canvas undo. |
| Workspace history preview (§8.5) | Not implemented | Undo history exists; historical arrangement preview does not. |
| Multiple workspaces | Not implemented | One workspace per profile (`--profile`). |

## Native integration (package A)

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Explicit admission of an existing window; launch app from workspace | Verified (admission) / Unverified (launch) | TextEdit window admitted; real pixels shown. |
| Stored preview, live preview (ScreenCaptureKit stream), offscreen capture budget | Verified (preview, live) | Budget switching not measured. |
| Window and region capture excludes host overlays and overlapping canvas objects | Verified | Capture uses the window's own buffer (`SCContentFilter(desktopIndependentWindow:)`). |
| Protected/blank capture refused with explanation | Unverified | Blank-frame detector implemented; no DRM fixture tested. |
| Activation: 1:1 focus view, real window moved to the object's rect with AX, raised above canvas | Verified | Double-click (real events) → TextEdit frontmost, window at the surface's exact rect, typed text and ⌘S changed the real file. First attempt exposed an animation race; fixed. Without AX the surface shows "Positioning needs Accessibility". |
| Host command ⌃⌥Space, "Return to canvas" panel, click on canvas | Verified (hot key, canvas click) | Input returned, previous camera restored, fresh preview captured. Panel button not clicked yet. |
| First activation click consumed by host; zoom never grants input | Verified | The first click selected the surface; only the double-click activated it; TextEdit content was untouched. |
| App menus reflect the active app | Verified | Menu bar showed TextEdit's menus while active. |
| Dialogs, sheets, palettes of the active app | Verified (Save As sheet, RTFD conversion alert) | Palettes not tested. |
| IME input in an active app | Unverified | Needs a real input-method session. |
| A second unrelated application | Unverified | Both tested windows belong to TextEdit. |
| Surviving runtime reconnect after host restart (pid + window number + bundle; document check) | Verified | Host killed and relaunched; TextEdit window rebound, no duplicate. |
| Reopen source by document path when the window is gone | Unverified | Document path comes from `AXDocument`; it now follows app-side renames while connected (found when TextEdit converted `.rtf` to `.rtfd`). |
| Ambiguous windows ask instead of matching titles | Unverified | |
| Close application window through its normal close flow | Unverified — needs Accessibility | |
| Remove from canvas never terminates the runtime | Verified | TextEdit kept running across removal, host quit, and kill -9. |
| Exit restores original placement; recovery onto a display | Verified (exit restore) / Unverified (display recovery) | After activation moved the window, Exit put it back at its original (214, 112). |
| Multiple displays with independent cameras | Unverified | One display on the test Mac. |
| Transformed input into arbitrary windows at fractional scale | Unsupported | The hybrid strategy delivers input only to the real window at 1:1. |
| Dirty-state detection for ordinary apps | Unsupported | Reported as unknown. |
| App-specific session restoration adapters | Not implemented | |

## Material transfer (package C)

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Copy text/notes: internal + RTF + plain text in one transaction | Verified | `pbpaste` returned the note text. |
| Copy mixed composition: internal + PNG + PDF + TIFF at export resolution | Verified | Separate process read the PNG (evidence image). |
| Copy file reference as real file URL; app surface as frozen visual | Verified (unit semantics) / Unverified (pasteboard) | |
| Copy as image / text / link commands | Unverified | |
| Paste internal selection with remapped IDs, relative geometry, visible offset | Verified | Three objects recreated; unit test checks new IDs. |
| Paste external text → text object; image → image asset; URL → reference page; files → references | Verified (text) / Unverified (others) | |
| Paste composition into a real document app | Verified | Real ⌘C on the canvas, real ⌘V in TextEdit; saved `deliverable.rtfd` contains the annotated capture (evidence). |
| Native drag out through the export grip (text, file URL, PNG file promise) | Unverified | First attempt was interrupted (the person switched apps). Spring-loading onto app surfaces added so the real window can receive the drop above the full-display canvas. |
| Drag in (files, images, text, URLs, file promises) | Unverified | |
| Frozen capture never changes; live view follows its source; freeze creates a new capture | Verified (frozen/live coexist) | The fixture app did not reload the edited file, so live updates were seen as new frames only. |

## Lifecycle and recovery (package D)

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Scene loads without launching apps; stored previews labeled "Last captured … · not connected" | Verified | |
| File reference: external change, move/rename via bookmark, one of two references removed, file deleted | Verified | Statuses "Changed…", "Moved — found at…", "File missing — relink"; file kept after removing a reference. |
| Relink, duplicate on disk, managed copy, move source to Trash | Unverified | |
| Background task survives navigation and host exit | Verified by construction | The host never terminates external processes; no dedicated long-task fixture yet. |
| Device restart | Not verified | |

## Collaboration (packages E, F, G)

Two participants were run as two independent host processes with separate profiles, storage,
and identities on the same Mac, connected over loopback TLS-PSK. **Simulated:** not two machines.

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Share a frame: preview of consequences, new scope document, private material stays out | Verified | Bob received only the frame's objects; Alice's private app surface and captures were absent. |
| Invite-code TLS-PSK transport, auto-reconnect, stored address | Verified | Restart of either side reconnected. |
| Concurrent text edits merge at operation level (from stale editor base) | Verified | "Alice: Research notes (Bob)" on both sides. |
| Concurrent moves are atomic transforms | Verified | Same result on both sides; no x/y mixing (also unit-tested). |
| Offline member edits replay after the host returns | Verified | |
| Asset fetch permission: private asset denied; published asset delivered | Verified | |
| Presence, cursors, remote selection outlines, follow mode, movement claims | Verified (presence, cursor and dashed selection outline, follow) / Unverified (claims) | Bob's camera followed Alice's; banner offered Stop following. |
| Revoke member → future access denied, member keeps a private recovered copy | Verified | Bob's shared scope was removed, its 12 objects kept as private copies; rejoining with the code and joining with a wrong code were both refused. |
| Shared browser runtime: single controller, generation tokens, stale/replayed events rejected, reclaim | Verified | Controller click incremented the page counter; generation 0 and post-reclaim generation 1 events rejected. Grant was issued through automation instead of the host's dialog. |
| Shared native app: live frames to members, control grant, CGEvent injection with target verification, local takeover reclaim, held-input release | **Unverified — needs Accessibility** | Remote control is reported unavailable without AX. |
| Explicit transfers: controller text/file into the remote app, copy from the remote app | Unverified | Host restores its own clipboard afterwards unless it changed meanwhile. |
| Reference page mode (per-user rendering, captures) | Verified (page load and preview) | |
| Provider-collaborative document mode | Unverified | Opens the link in the user's own browser; no credentials copied. |
| Purpose-built adapters, scroll-follow | Not implemented | |
| View-only membership | Not implemented | All members can edit a shared scope. |
| Runtime sharing from a member (not the session host) | Not implemented | Only the session host can share applications. |

## Performance (§14)

Measured with the release build on the test Mac, windowed 1280×820 at 2×, automation-driven
(`populate 500`, `bench 600`): 500 objects (150 notes, 100 text, 100 shapes, 100 ink, 50 images
with distinct 1600×1000 stored previews). Live surfaces and a second participant were not part of
this run.

| Measure | Result | Target |
| --- | --- | --- |
| Main-thread cost per camera frame (update + layer commit), p50 / p95 / max | 2.8 / 9.2 / 34 ms; no frame over 100 ms | p95 ≤ 33 ms display frame time |
| Reopen the saved 500-object scene to responding | 0.48 s | ≤ 1 s |
| Memory: empty workspace / 500 objects fit-all / after touring zoom levels | 31 MB / 80 MB / 140–220 MB | — |
| Stored asset bytes for 50 previews (PNG) | 1.8 MB | — |

This measures main-thread work, not presented display frames. Memory work so far: images decode
at on-screen size buckets with a 64 MB budget, offscreen objects drop their pixels, shadows use
explicit paths, and text rasterizes at on-screen resolution. Before these changes the same scene
used 825 MB.

## Next steps

1. In a notified input window: native drag both ways (with spring-loading), IME, a second
   unrelated app, the Return panel button.
2. Shared native app handoff between the two profiles (E2E-09).
3. Performance with three live surfaces and two participants.
4. Workspace history preview (§8.5), multiple workspaces.
