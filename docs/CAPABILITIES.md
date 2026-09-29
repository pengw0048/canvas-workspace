# Capability and Gap Report

Status as of 2026-09-29. Test profile: one MacBook Pro (Apple M4 Max, 64 GB), macOS 27.0.1,
built-in display at 2× scale, Swift 6.4 Command Line Tools. Fixture applications: TextEdit
(system), the host's embedded WebKit browser. All fixtures are non-sensitive local files.

The product is **not complete**. The native hybrid strategy (§7.2 gate) is only partly proven:
capture, previews, live views, and runtime reconnection work with real windows, but activation
with window positioning, native drag, remote control of native apps, and exit restoration still
need the Accessibility permission to be tested.

Legend: **Verified** — exercised on this Mac with real applications, real system clipboard,
real files, or independent processes, with evidence. **Unverified** — implemented, not yet
exercised end to end. **Simulated** — exercised, but with a stand-in noted in the row.
**Unsupported** — not possible on this host or by design. **Not implemented** — still missing.

## Evidence summary

| Evidence | Where |
| --- | --- |
| Native objects on one plane (frame, sticky, text, shape, rotated ellipse, ink) in the real window | [evidence/native-objects.png](evidence/native-objects.png) |
| Real TextEdit window admitted, frozen region capture, live preview, and live view | [evidence/textedit-live-view.png](evidence/textedit-live-view.png) |
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
| Rich text formatting and links in text objects | Not implemented | Text objects are plain text. |
| Workspace history preview (§8.5) | Not implemented | Undo history exists; historical arrangement preview does not. |
| Multiple workspaces | Not implemented | One workspace per profile (`--profile`). |

## Native integration (package A)

| Capability | Status | Evidence / limitation |
| --- | --- | --- |
| Explicit admission of an existing window; launch app from workspace | Verified (admission) / Unverified (launch) | TextEdit window admitted; real pixels shown. |
| Stored preview, live preview (ScreenCaptureKit stream), offscreen capture budget | Verified (preview, live) | Budget switching not measured. |
| Window and region capture excludes host overlays and overlapping canvas objects | Verified | Capture uses the window's own buffer (`SCContentFilter(desktopIndependentWindow:)`). |
| Protected/blank capture refused with explanation | Unverified | Blank-frame detector implemented; no DRM fixture tested. |
| Activation: 1:1 focus view, real window moved to the object's rect with AX, raised above canvas | **Unverified — needs Accessibility** | Without AX the app activates in place and the surface shows "Positioning needs Accessibility". |
| Host command ⌃⌥Space and clickable "Return to canvas" panel | Unverified | Carbon hot key registered (no permission needed). |
| First activation click consumed by host; zoom never grants input | Verified by construction | The canvas window receives the click; inactive windows sit behind it. Person review pending. |
| Dialogs, sheets, palettes of the active app | Unverified | Real windows of the active app stay above the canvas; expected to work, not tested. |
| Surviving runtime reconnect after host restart (pid + window number + bundle; document check) | Verified | Host killed and relaunched; TextEdit window rebound, no duplicate. |
| Reopen source by document path when the window is gone | Unverified — needs Accessibility | Document path comes from `AXDocument`. |
| Ambiguous windows ask instead of matching titles | Unverified | |
| Close application window through its normal close flow | Unverified — needs Accessibility | |
| Remove from canvas never terminates the runtime | Verified | TextEdit kept running across removal, host quit, and kill -9. |
| Exit restores original placement; recovery onto a display | Unverified — needs Accessibility | Windows are never moved offscreen, so a crash leaves them usable (verified: kill -9). |
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
| Paste composition into a real slide/document app | Unverified | Needs a real paste into Keynote/Pages/TextEdit. |
| Native drag out through the export grip (text, file URL, PNG file promise) | Unverified | Needs a real pointer drag. |
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
| Presence, cursors, remote selection outlines, follow mode, movement claims | Verified (presence exchange) / Unverified (visuals, follow, claims) | |
| Revoke member → future access denied, member keeps a private recovered copy | Unverified | |
| Shared browser runtime: single controller, generation tokens, stale/replayed events rejected, reclaim | Verified | Controller click incremented the page counter; generation 0 and post-reclaim generation 1 events rejected. Grant was issued through automation instead of the host's dialog. |
| Shared native app: live frames to members, control grant, CGEvent injection with target verification, local takeover reclaim, held-input release | **Unverified — needs Accessibility** | Remote control is reported unavailable without AX. |
| Explicit transfers: controller text/file into the remote app, copy from the remote app | Unverified | Host restores its own clipboard afterwards unless it changed meanwhile. |
| Reference page mode (per-user rendering, captures) | Verified (page load and preview) | |
| Provider-collaborative document mode | Unverified | Opens the link in the user's own browser; no credentials copied. |
| Purpose-built adapters, scroll-follow | Not implemented | |
| View-only membership | Not implemented | All members can edit a shared scope. |
| Runtime sharing from a member (not the session host) | Not implemented | Only the session host can share applications. |

## Performance (§14)

Not measured yet. The renderer uses one camera transform on a layer tree and re-rasterizes text
only after zoom settles. The §14 profile (500 objects, 50 previews, 3 live surfaces, 2 clients)
has not been run.

## Next steps

1. With Accessibility granted: run the §7.2 gate — activation and positioning across TextEdit and
   a second unrelated app, IME, menus, save dialog, native drag both ways, exit restoration, and
   display recovery. Record results here.
2. Paste a composition into a real document app and save it (E2E-03/04/12).
3. Shared native app handoff between the two profiles (E2E-09).
4. Performance profile and rich text.
