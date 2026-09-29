# Canvas Workspace — Product and Implementation Specification

Version: 1.0 · 2026-09-28 · Working product name

Audience: product, design, and implementation agents building the same product.

Navigation: [product contract](#1-product-contract) · [objects](#4-object-model-visible-to-users) · [input](#5-navigation-selection-and-input-ownership) · [material flow](#6-material-flow-capture-clipboard-drag-and-return) · [native integration](#7-native-desktop-integration) · [resume](#8-persistence-lifecycle-and-resume) · [collaboration](#9-collaboration-across-the-workspace) · [architecture](#12-minimal-conceptual-architecture) · [acceptance](#16-end-to-end-acceptance) · [implementation](#17-implementation-plan-without-reducing-the-product).

## 1. Product contract

**The desktop is a persistent, freely arranged, collaborative two-dimensional canvas. Real application windows, files, and canvas-native material inhabit the same space. The physical screen is a viewport into that space.**

A person should be able to work in a real application, capture part of it onto the surrounding canvas, annotate it with someone else, paste the result into another application, leave, and return to the same working context. None of those actions should require reconstructing the activity in a separate whiteboard application.

This specification defines the complete intended product. Implementation may proceed in increments; an increment does not redefine the destination or satisfy requirements it only simulates. It is intentionally more specific than the accompanying [vision](canvas-workspace-vision.md). Where the earlier vision leaves a behavior open, this specification supplies a proposed default.

### 1.1 Authority and decision status

- **Established requirements:** the product invariants in §2 reflect the user's direction. Do not remove or replace them without discussing the change with the user.
- **Proposed defaults:** concrete gestures, platform choices, architecture boundaries, and numerical targets in this document let implementation proceed. They are design decisions proposed by this specification, not claims that the user previously chose them. Adjust them when evidence supports a better way to meet the invariants; document consequential changes.
- **Platform-dependent capabilities:** embedding, capture, input routing, application restoration, and remote control must be demonstrated on real applications. A diagram, API name, or simulated window is not evidence of support.

“Must” describes the target product contract. “Default” describes the initial behavior to implement. An unsupported capability must remain visible in the implementation's gap report; it must not be silently redefined as complete.

### 1.2 Working implementation defaults

| Decision | Default | Reason and tradeoff |
| --- | --- | --- |
| First desktop host | macOS | Matches the user's current computer and desktop request; native window composition is a significant feasibility question. Preserve a platform boundary without building multiple backends now. |
| Persistence | Local durable workspace, with synchronization for shared work | Personal work must survive without a server. Requires explicit handling of unavailable collaborator assets and runtimes. |
| Collaboration | Shared object layout; independent cameras | Supports shared spatial discussion without forcing people to follow one viewport. Concurrent rearrangement needs predictable conflict behavior. |
| General applications | Real local runtime, capability-dependent presentation and control | Gives access to existing tools; arbitrary applications do not expose equivalent restoration or collaborative editing. |
| Common applications | Adapters where they improve a concrete workflow | Richer semantics are valuable, but the product must remain useful with ordinary unmodified applications. |
| Organization | Free placement, optional frames and tidy | Preserves spatial intent; search and overview must handle large, irregular workspaces. |

The initial deployment profile is one person's machine and trusted collaborators. Build ordinary authentication, explicit sharing, and durable storage appropriate to this profile. Enterprise administration, marketplaces, billing, and general cloud infrastructure are outside this specification.

## 2. Non-negotiable product invariants

| ID | Requirement |
| --- | --- |
| INV-01 | The primary environment is a desktop canvas with continuous pan and zoom. A web dashboard, rigid tile layout, or series of project pages does not satisfy this requirement. |
| INV-02 | Arbitrary application windows and real files are first-class inhabitants, alongside sticky notes, text, shapes, drawing, images, frames, and connectors. “Arbitrary” means an integration path for unmodified applications, with explicit platform limitations; it does not promise every protected surface can be captured or controlled. |
| INV-03 | Position, size, overlap, grouping, and meaningful mess belong to the user. Organization tools operate on explicit targets and can be undone. |
| INV-04 | Scale controls presentation; focus controls input. Zooming alone never grants keyboard input or remote control. |
| INV-05 | Material moves in both directions between applications and the canvas through capture, ordinary copy/paste, and drag/drop, using real system facilities. |
| INV-06 | A workspace object's identity and location outlive a running window. Resume preserves context and states precisely what application continuation is available. |
| INV-07 | Canvas-native content supports concurrent editing. Ordinary applications can have one controller and multiple viewers. Richer collaboration depends on explicit capabilities. |
| INV-08 | A frozen capture, a reference, and a live view have different semantics. Source changes never silently rewrite frozen evidence. |
| INV-09 | Unsaved work, running tasks, and external documents are not disposable because an object is distant, hidden, or removed from a canvas. |
| INV-10 | The complete vision is the implementation destination. AI assistance, project schemas, and mandatory document ingestion are not prerequisites for ordinary work. |

## 3. Desktop experience and scope

### 3.1 Entering and leaving

The workspace opens as a desktop-scale surface without an enclosing browser tab or ordinary document-window frame. This is an experience requirement; it does not prescribe replacing the operating system's compositor.

System facilities remain reachable: application switching, menu commands, file dialogs, notifications, accessibility settings, and a reliable return to the conventional desktop. A visible workspace menu and a configurable global command provide an exit. Exiting the canvas host preserves its state and leaves underlying applications usable. It must not force-quit them.

A desktop host can technically be an application. It satisfies the requirement only if real applications participate coherently in the spatial environment. A full-screen webpage containing painted application lookalikes is an interaction study.

### 3.2 Spatial continuity

There is one continuous plane per workspace. Frames and named destinations mark places on that plane; entering them does not navigate to another page. The user may maintain several workspaces, but splitting one activity across mandatory workspaces is not the organizing model.

Opening an app or file normally places it near the current view or reuses its existing object. When several views exist, offer a concise choice to reveal one or create another. Do not silently scatter duplicates on every reopen. A new view of a source and a copied source are different operations.

Search finds objects, application titles, filenames, text, and named places. Selecting a result moves the camera to it and highlights it. Search does not silently activate its runtime. A navigation-back action returns to the previous camera; it does not undo document edits.

### 3.3 Multiple displays and focused work

Default: each physical display has an independent camera into the same workspace. Content and geometry are shared; cameras and focus are personal. A “bring here” action deliberately changes object position; “reveal here” changes only this display's camera.

Only one target receives a given user's keyboard input. An unmodified local native window need only have one interactive physical presentation at a time; another display may show its preview. This limitation must be legible, with an action to activate it on the desired display.

Focus view temporarily fits one object for comfortable operation while preserving its world position and surrounding arrangement. Leaving focus view restores the previous camera. Full-screen video or app-specific full-screen behavior may use a conventional system presentation when necessary; returning must reveal the same object, not create a detached duplicate.

## 4. Object model visible to users

| Type | Core behavior | Relationship to external state |
| --- | --- | --- |
| Application surface | Real window/session, preview, app identity, activate/capture/control actions | Refers to a runtime and its source; never treats pixels as editable application state. |
| Browser surface | Page or browser session with URL and adapter-specific state | Uses one of the explicit browser collaboration modes in §10. |
| File | Actual file reference, useful preview, open, reveal, drag/import, copy | Defaults to a reference to the existing file; importing a managed copy is a separate action. |
| Sticky note | Quickly editable text, color, lightweight size adjustment | Native workspace content. |
| Text | Free text with basic rich formatting, links, and predictable wrapping | Native content; copy retains usable text. |
| Shape | Rectangle, ellipse, line, arrow and basic style/fill | Native content. |
| Ink | Pen/highlighter strokes and erasing | Native vector strokes where practical. |
| Image / capture | Resize, crop, source metadata, annotate alongside, export | A stored image revision unless explicitly made live. |
| Frame | Named region with optional background and membership | A region on the same plane, not a page or compulsory container. |
| Group | Move, transform and duplicate selected members together | Selection convenience; does not acquire runtime control. |
| Connector | Line/arrow between object anchors or free endpoints; optional label | Expresses a relationship. It does not imply computation, automation, or a pipeline execution edge. |

All objects support selection, move, duplicate, layering, delete-from-canvas, and inspection as applicable. Text, notes, shapes, images, and ink support rotation; application/file previews remain upright by default. Windows have separate logical application dimensions and canvas presentation dimensions. Scaling a window preview must not repeatedly reflow the underlying application.

### 4.1 Identity and duplication

- Moving, resizing, hiding, or reconnecting an object preserves its identity and links.
- Duplicating a native note, image, or composition creates independent content, sharing immutable asset bytes where useful.
- Duplicating a file object creates another reference by default, not a filesystem copy. “Duplicate file” creates an actual copy and makes that outcome clear.
- Duplicating an application surface defaults to an independent frozen capture. “Open another view” is explicit and depends on the application. Do not silently start a second editor against the same unsaved document.
- A reference to another canvas object follows that object's identity. A reference to a source file follows the source. The UI must identify which relationship was created.

### 4.2 Frames, groups, overlap, and connectors

Dragging a frame border or label moves the frame and its members. Clicking empty frame interior permits selecting or creating content. Dragging a member moves that member. A geometry overlap alone does not continuously change membership; a drop across a frame boundary previews the proposed membership change and commits it on release. A modifier allows moving across the boundary without reparenting.

Moving a group acts on the group until the user explicitly enters it. In a dense overlap, context-menu “select behind” or an equivalent cycling command exposes covered objects. Bring forward/back and bring to front/back are available. Activating an app may raise its local interactive presentation, but must not silently rewrite the shared document's stacking order.

Connectors track target movement. Removing an endpoint leaves a visible, repairable free endpoint or removes the connector as part of the same undoable command; the implementation must choose and apply one behavior consistently. Default: retain the other endpoint and mark the missing endpoint until repaired or deleted.

## 5. Navigation, selection, and input ownership

### 5.1 Interaction states

Input ownership is explicit and independent of display scale:

| State | Pointer / scroll | Typing and clipboard | Exit |
| --- | --- | --- | --- |
| Canvas navigation / selection | Select, move, marquee, pan and zoom | Canvas shortcuts and clipboard | Activate or edit an object. |
| Native canvas editing | Text selection, caret or drawing tool | Content editing; normal text copy/paste | Click canvas, finish edit, or Escape where appropriate. |
| Application active | Native application semantics | Application owns ordinary keys, shortcuts and clipboard | Dedicated host command or visible return-to-canvas control. |
| Application viewer | Point, inspect, annotate outside app; no remote input | Canvas/viewer commands | Request control or return to canvas. |
| Modal operation | Capture region, transform, control request, etc. | Only commands relevant to the operation | Complete or cancel without changing unrelated state. |

### 5.2 Proposed gesture defaults

| Action | Default |
| --- | --- |
| Select object | Single click on inactive object. |
| Multi-select | Shift-click; marquee from empty canvas. |
| Activate application / edit native object | Double-click or Enter on selection. Application activation may first enter a usable focus view. |
| Move object | Drag its selected body in canvas mode; application surfaces always expose an outer grip/title handle. |
| Pan | Trackpad scroll in canvas mode; Space-drag or middle-button drag where available. |
| Zoom | Pinch or Command-wheel in canvas mode, anchored to pointer/gesture center. |
| Fit all / fit selection | Shift-1 / Shift-2 in canvas mode. |
| Return application input to canvas | Configurable global host command; proposed macOS default Control-Option-Space, subject to collision/accessibility testing. Also provide a clickable host control. |
| Escape | Cancels the current canvas operation. While an app owns input, Escape belongs to the app; it is not the universal host escape. |
| Copy / paste / undo | Command-C / V / Z act on the current input owner. The host must not execute a second operation from the same event. |

Entering an inactive object must not also click a destructive button inside the application. First activation is consumed by the host. Subsequent events go to the active app. Do not rely on hover to activate or grant control.

Space-drag must not intercept spaces in an application or text field. A host navigation gesture initiated while an application is active first transfers ownership to the host and suppresses the initiating gesture from the app. Return requires deliberate activation. Global-command collisions must be configurable and verified, including with input methods and assistive features.

Application title bars, host selection handles, frame borders, resize handles, and content regions have separate hit targets. Small zoom levels expand handle hit areas without covering most of the object. Cursor shape and a restrained focus outline communicate the current operation before movement begins.

### 5.3 Zoom and level of detail

The renderer chooses detail from projected screen size, visibility, freshness, and capability. Initial tuning defaults:

- Below roughly 120 CSS-equivalent pixels in width: recognizable icon, short title, and only essential status.
- Roughly 120–480 pixels: cached thumbnail or inexpensive live preview with title; no unusable miniature toolbar.
- Above roughly 480 pixels: legible preview and contextual controls. Live rendering is selected only where useful and available.
- Active application: interactive presentation at a usable scale; use focus view if the backend cannot deliver accurate transformed interaction.

These thresholds are adjustable, use hysteresis to prevent flicker, and are not app activation thresholds. Avoid changing representations in a way that shifts the object's anchor or moves its neighbors. Low zoom must preserve a recognizable silhouette, title, or selected state. Native text and notes may simplify without erasing their usefulness as landmarks.

The design does not require arbitrary native windows to accept input at fractional scale. A preview-to-native transition can satisfy the interaction if it is spatially coherent, quick, and returns to the same canvas position. Whether this is convincing must be tested, not asserted.

### 5.4 Rearrangement and undo

Align, distribute, tidy, resize-to-content, and frame-to-content are explicit commands with visible target selection. Tidy works on the selection or chosen frame, previews substantial moves, and is one undoable operation. It never runs automatically because a new object arrived, content changed, or a collaborator joined.

Canvas undo covers native edits, geometry, grouping, membership, and layout operations. It does not claim to undo application actions or remote service effects. In collaborative use, undo reverses the user's own operation without overwriting another participant's unrelated later work. Camera history is separate from content undo.

## 6. Material flow: capture, clipboard, drag, and return

This section is a core acceptance contract, not a convenience feature.

### 6.1 Capture an application or region

1. Invoke capture from a selected/active application surface or a configurable global command.
2. Choose whole surface or drag a region. Region capture shows exactly which pixels will be included; cancel leaves no object.
3. Commit an immutable image asset and a canvas object in one durable operation.
4. Place it next to its source or at the user's drop point, visible in the current viewport. Avoid covering the source's active controls where possible.
5. Keep the app available. The new capture is selected for immediate annotation or copying.

No mandatory Save As, screenshot-folder visit, file picker, or upload step appears in this flow. A requested save/export remains available. During an asynchronous capture, a placeholder may show progress but is not described as a completed capture until pixels are durably stored.

Capture metadata includes time, source object, source application, available file/URL, captured region, and source revision when known. Provenance is inspectable and linkable, not a mandatory label covering every image. File paths, private URLs, and window titles follow the sharing policy in §11.

Protected, unavailable, or denied capture produces an actionable explanation. Do not create an apparently successful blank image or silently capture a different window. A video frame capture is a frozen frame, not a live video link.

### 6.2 System clipboard representations

Publish multiple representations in one system clipboard transaction. A receiving app selects a supported representation; the host cannot universally negotiate an arbitrary application's paste behavior in advance.

| Canvas selection | Representations, in preferred semantic order |
| --- | --- |
| Text or note text | Internal editable object data; rich text/HTML where supported; plain text. |
| Single image/capture | Internal object data; standard image data; optional promised image file for drag targets. |
| File reference | Internal object reference; real file URL or platform file promise; readable filename where useful. Never substitute an unusable private path for the file. |
| URL/reference | Internal reference; standard URL; readable link text. |
| Shapes, ink, or mixed annotated composition | Internal editable selection; vector format when correct and supported; high-quality raster fallback. Also include a sensible text representation only when it does not change the intended paste result. |
| Application surface | Frozen visual of the selected surface, plus a source link when available. Runtime ownership is not copied. |

Copying a selected frame or group includes its descendants. Directly selecting only some members copies only those members. Cloned objects receive new identities; copied hierarchy and internal connector endpoints are remapped. External targets are not implicitly cloned, and connectors with an unselected endpoint are not included implicitly. An explicitly selected connector may retain its external target reference where access permits. Application surfaces and files follow §4.1's duplication semantics even inside a copied group. Copying a composition uses the selection bounds, a predictable background/transparency policy, and a sufficient export resolution independent of current zoom.

Default mixed composition paste into an image-capable destination produces the composed visual. Provide explicit “Copy as image,” “Copy text,” and “Copy link” for cases where the app's type preference is unsuitable. An ordinary copy must not open a format dialog each time.

Clipboard failure leaves the previous clipboard intact where the platform permits and reports the failure. Do not fall back to an internal-only clipboard while claiming system interoperability. Large assets use platform-supported deferred delivery/file promises when appropriate; their backing bytes must remain available through the transfer lifetime.

Pasting into the canvas creates objects around the last intentional canvas pointer location when it is inside the current view; otherwise use the viewport center. Repeated pastes offset visibly instead of overlapping exactly. Preserve relative geometry, remap internal IDs/connections, and select the new objects. A paste into an active native text editor or app belongs to that editor/app and does not create an additional canvas object.

### 6.3 Drag and drop

Dragging an object's body in canvas mode arranges it. A visible export/content grip, also available through a context action, initiates a native content drag into an application. This separates “move my note” from “insert this note's text” without guessing from a boundary crossing. Test whether a simpler gesture can safely replace it.

Inbound drags of text, images, URLs, and files create the appropriate native canvas object with provenance where available. A file dropped on empty canvas becomes a reference by default. A file dropped on an active application's import target follows that application's import behavior; the host does not also create a canvas duplicate.

The destination advertises copy/import/link where available. Default content export never moves or deletes the original file. Rejected drops leave the source unchanged and show a brief reason. Local private paths are not transferable file content for remote collaborators.

### 6.4 Copy, reference, live, and return-to-source

| Form | Meaning | Update behavior |
| --- | --- | --- |
| Frozen copy | Independent material captured at a moment | Never changes with its source. Refresh creates a new revision/capture rather than silently rewriting existing annotated evidence. |
| Reference | Route to an existing canvas object or external source | Reveals or opens its target; access and runtime availability remain separate. |
| Live view | Follows a specific source while available | Shows current updates and exposes freshness. Freeze creates a separate immutable object. |

Annotations on a frozen capture remain attached to that capture. Annotation on a live surface must choose either surface-relative marks that may become stale or a frozen frame for stable review. Default review action freezes first; persistent live annotations carry a visible anchoring/freshness limitation.

“Reveal source” moves to the existing source object when possible; “Open source” activates/reopens it. Returning an edited image/file from an app updates its live/reference preview or creates a new frozen result next to the originating discussion, as the operation specifies. File replacement changes current source state without rewriting historical captures. Do not require every app to expose a return callback: ordinary drag, paste, save-and-observe, and capture remain valid paths.

### 6.5 Transfer into a remotely controlled application

Clipboard and drag are local operating-system facilities; remote input alone does not transfer their content. When a controller pastes material from their canvas/device into a remote app, transfer the explicitly selected payload through the authorized session and then perform the destination operation. Sending Command-V to the host's unrelated old clipboard is not a valid implementation.

Do not continuously mirror global clipboards. Copying from the controlled app to the controller is an explicit data-transfer action; copying an already published capture is an ordinary local action. File transfer provides authorized bytes or a fulfilled file promise on the destination host, not a path valid only on the sender's machine. Show progress and preserve the source on failure or cancellation. The host pasteboard may be used for an explicit paste, but unrelated intervening clipboard changes must not be silently overwritten by delayed transfer completion.

Adapters/transports declare remote clipboard and remote drag support separately. Until supported, disable or explain that action and expose an accurate alternate transfer route; do not pretend that forwarding a keyboard shortcut or pointer drag completed it.

## 7. Native desktop integration

### 7.1 Admission, ownership, and window families

Users can bring an existing native window into the canvas, launch an app from the workspace, open a referenced file/URL, or drag content from the conventional desktop. Imported windows retain their actual processes and documents. Capture/access permissions are requested when the corresponding capability is first used, with a useful explanation and recovery path.

Default admission is explicit. Do not immediately seize every open window on the machine. An app can be configured to admit future document windows into the current region; unrelated applications remain outside that rule. New dialogs, sheets, popovers, menus, and dependent palettes belong to the active window family and remain operable without requiring manual admission.

A save dialog must not be hidden behind a captured parent. A floating palette must not be mistaken for a saved document. Persistent document windows receive durable object identities; transient UI usually does not. App menus reflect the active application. A failed association must leave the native UI accessible and report the integration limitation.

The host records enough information about original placement to return admitted windows to a usable ordinary desktop on exit. Windows must not be stranded offscreen if the host fails, permissions disappear, or a display is disconnected. Provide a recovery command that brings managed native windows onto an available display without deleting their spatial layout.

### 7.2 Candidate macOS strategy and proof obligations

Start with a native host coordinating a canvas renderer, per-window capture, application activation, and available window accessibility operations. A renderer implemented with web technology is acceptable inside that host. A web-only rendering stack does not solve OS integration.

Investigate captured surfaces for overview/manipulation and real native presentation during activation. Apple ScreenCaptureKit, Accessibility APIs, AppKit, and system pasteboards are candidate building blocks, not a guarantee of arbitrary window embedding or transformed input. In particular:

- Per-window pixels do not provide editable application state.
- A transient window handle or title is not a durable document identity.
- A captured preview does not establish that input can be accurately delivered at an arbitrary scale.
- Reducing capture frequency does not release the application's process memory.
- Reopening a file is not equivalent to restoring every unsaved edit, selection, connection, or task.

Before committing to this presentation approach, demonstrate real editing across two unrelated native applications, overlapping surfaces, pan/zoom, input methods, menus, save dialogs, drag/drop, display changes, and exit/recovery. Record exact limitations. If the experience cannot meet INV-01/02/04/05, compare alternative integration strategies and bring the concrete tradeoff to the user. Do not replace the target with screenshot cards and call the gate passed.

Remote/virtualized applications or another operating system/compositor are possible alternative hosts, not silently authorized replacements for the user's local desktop. They have latency, file-access, account, and operating-cost consequences that require a deliberate platform decision.

### 7.3 Capabilities and graceful failure

Discover capabilities per runtime instance and permission state: still/live capture, activate, move, resize, associate child UI, native input, remote input, source identification, source reopen, session restoration, dirty-state observation, graceful close, and publication.

Each capability has a status such as available, unsupported, permission required, or temporarily unavailable, plus a reason and possible action. Do not use one `supportsNativeWindows` flag. UI language should say “Open original,” “Reconnect,” “Allow screen recording,” or “Last captured …,” not expose adapter enum names.

If capture permission fails, the rest of the canvas remains useful. If native positioning fails, retain the object and offer access to the original app; mark this as degraded integration. Do not send input to a preview whose runtime binding has not been confirmed.

## 8. Persistence, lifecycle, and resume

### 8.1 Durable workspace state

Persist object identities and native content, geometry and stacking, frame/group membership, connectors, source references, stored captures, named places, sharing decisions, and available recovery descriptors. Persist each user's camera and recent navigation separately. Do not restore active input or a remote control grant merely because it existed before a crash.

Native content edits autosave locally as transactions. Distinguish “Saved on this device,” “Syncing,” “Shared,” and a visible saving failure. A local save acknowledgment means the relevant content and required asset data are recoverable after a host-process crash; network acknowledgment is separate. Never silently stop saving after an object, string, or storage-size threshold.

Asset writes and object updates must be committed so that a saved capture cannot point to missing bytes. Use recoverable staging and cleanup for interrupted writes. Keep unacknowledged changes visible as pending. If storage is full, preserve available in-memory work, allow export/retry, and avoid claiming durability.

### 8.2 Independent lifecycle dimensions

Do not encode the following as one mutually exclusive “window state”:

| Dimension | Representative values |
| --- | --- |
| Presentation | Icon, stored preview, live visual, interactive presentation |
| Runtime | None, opening, connected, disconnected, failed |
| Input | Canvas, native object editor, application, modal operation |
| Availability | Ready, permission needed, source missing, host offline, unsupported |
| Publication | Private, frozen shared revision, live shared surface |
| Control | No controller, host controller, granted remote controller |
| Recovery depth | Visual record, source reopen, adapter session, surviving runtime |

A running app may have only a cached preview displayed. A live shared surface may be read-only. A disconnected source may still have useful editable canvas annotations.

### 8.3 Resume protocol

1. Load the scene and durable native content without launching all applications.
2. Show stored previews immediately, labeled as historical/disconnected when appropriate.
3. On activation, look for a verified surviving runtime binding first.
4. Otherwise use a supported session descriptor or reopen the current source.
5. Confirm the identity of the resulting document/window before delivering input or replacing its current preview.
6. Report the achieved continuation depth and any material lost context through concise user-facing status.

Repeated activation while opening coalesces into one request. Canceling an open leaves the persistent object. An ambiguous match asks for a target instead of connecting to the first similarly named window. App/window titles alone are insufficient for silent rebinding.

| Recoverable material | Promise | Example user-facing behavior |
| --- | --- | --- |
| Last visual only | Inspect and reuse the saved visual | “Last captured yesterday. Original session unavailable.” |
| Source reference | Open the current file or URL | “Reopen file”; old capture remains available. |
| Adapter session | Restore the specific fields the adapter saved | Restore tab/scroll/document state only where supported and valid. |
| Surviving runtime | Reconnect to the still-running application | Continue its existing task after identity verification. |

If a source moved, attempt supported file identity/bookmark resolution, then offer relink. If deleted or unavailable, preserve the object and saved material. If changed externally, reopening uses current source data; it does not overwrite the source with historical workspace state. If an adapter restoration would replay stale data over a current document, it must reconcile or request a deliberate user choice.

### 8.4 Resource management and unsaved work

Visibility may reduce capture frequency, stop offscreen rendering, evict decoded preview buffers, or downgrade stream resolution. It must not automatically terminate native processes, close unsaved documents, stop downloads, interrupt computations, or pause audio/video solely because the user navigated away.

Externally owned application runtimes remain owned by their application/user. Workspace-launched runtimes may be gracefully closed only under an explicit policy when their safety is known. “No dirty flag observed” means unknown, not safe. Normal save/cancel prompts must remain reachable. Force quit is not a memory-management strategy.

User actions have distinct names and consequences:

- **Deactivate:** return input to the canvas; application can keep running.
- **Stop live preview:** stop visual updates; application can keep running.
- **Close application window:** invoke the normal application close flow; keep the persistent canvas object and available recovery state.
- **Remove from canvas:** remove this reference/object, with undo; preserve external files and do not terminate a runtime still in use.
- **Delete source file:** an explicitly named filesystem action, separate from ordinary canvas deletion.

If an application cannot save an unsaved draft or restore it later, keep the runtime alive during ordinary workspace departure where possible and describe the limitation before an action that would close it. The product cannot guarantee unsaved third-party state after an application/device crash; it must retain its own durable content and accurately report the available recovery.

### 8.5 History and recovery

Workspace history restores layout, native content, and stored artifact revisions. External files, application undo stacks, websites, sent messages, and remote actions are outside that history. Preview a historical arrangement before applying it; do not launch historical application actions as a side effect.

On a host crash, reconnect to surviving apps after restart. On an app crash, preserve the object and offer recovery/reopen. On device restart, restore the scene first and activate sources on demand. On network interruption, keep local work usable and mark pending synchronization. On saving failure, retain the last confirmed durable revision and expose the unsaved delta for recovery/export.

## 9. Collaboration across the workspace

### 9.1 Shared document, personal view

Shared state includes published native objects, their geometry, membership, stacking, content, connectors, and revisions. Personal state includes camera, local selection, keyboard focus, temporary focus view, open inspectors, and pointer preferences. Presence may show other people's cursors and selection outlines without granting input ownership.

Following a collaborator is opt-in and visibly active. The follower's own navigation exits follow mode. Follow never grants app control, copies account sessions, or activates keyboard input automatically.

Native notes/text support concurrent editing with preserved contributions. Use a proven collaborative data model rather than homegrown whole-document overwrites. Selection and drag feedback can be ephemeral; committed content must be durable and synchronizable.

### 9.2 Conflict defaults

- Different objects can be edited/moved concurrently.
- Simultaneous text edits merge at the text-operation level.
- The first online drag of an object obtains a short-lived movement claim with visible presence. A frame/group drag claims its affected descendants as well as the container. Conflicting descendant movement or membership changes are blocked with an explanation until release/expiry, after which the user may retry. Other participants can inspect or edit unrelated content.
- Offline/concurrent geometry updates resolve as an atomic transform operation, using deterministic operation ordering. Retain the overwritten intent in history; do not merge x from one move with y from another.
- Frame moves and membership changes are atomic commands. Each committed move records its explicit affected object set; recipients do not recompute it from their current membership. Offline concurrent commands use deterministic ordering and operation deduplication. A reconnect must not apply a frame delta twice. Membership cannot form cycles.
- Deletion leaves a tombstone. Concurrent edits to removed content remain recoverable through history/recovery rather than silently resurrecting or discarding the object.
- Undo targets the author's operation. If a later incompatible edit prevents a faithful inverse, explain the conflict or offer a recovered copy instead of overwriting someone else's work.

These are observable semantics. CRDT, operation log, and server arbitration choices may vary if these outcomes hold.

### 9.3 Ordinary application sharing

An ordinary runtime has one operator at a time. Other participants see a live stream, periodic images, or the last published visual according to the selected mode and actual capability. They can point, discuss, and annotate the surrounding canvas without controlling the application.

Default: the host is controller. A viewer requests control; the current controller/host grants it through an explicit action. The UI identifies controller and host separately. Transfer clears pressed-key/pointer state before accepting events from the new controller. The former controller's remote events are rejected. The host always has a visible reclaim/stop-sharing action and an emergency host shortcut.

Control grants are session-bound, expire on disconnect, and cannot be queued offline. Use a generation/token or equivalent mechanism so delayed events from a former grant cannot operate the app. The protocol must avoid duplicate input on retry. Do not automatically give control to the next viewer when a controller disappears.

The host's local physical input must not race a remote controller. Default: a local action that would operate the shared app first reclaims control, revokes the remote grant, and clears held inputs; announce the change before accepting subsequent app input. Local activity elsewhere need not reclaim control, but any loss of a safe authorized input target pauses remote delivery. Before delivering remote input, verify that its target remains the granted runtime/window family; never allow a focus change to redirect input to an unrelated app. A backend unable to enforce this must report remote control as unavailable rather than offer unsafe approximate routing.

Remote control operates the existing host session with its existing application account; it does not transfer that account or create independent edits. The host deliberately chooses which surface family to expose. Viewers do not receive unrelated desktop windows or notifications through a silent full-screen fallback.

When the runtime host leaves, remaining users retain only the material actually published and the native canvas content they can access. Show last-update time and “Host offline.” A fresh local or remote runtime is a distinct action with its own source access and restore capabilities, not automatic session migration.

## 10. Browser and application adapters

“Native collaboration for a webpage” has several meanings. Implement and label the actual mode rather than pretending that identical URLs create identical collaborative sessions.

| Mode | What is shared | What remains individual | Intended use |
| --- | --- | --- | --- |
| Reference page | URL, published capture/excerpts, canvas annotations; optional explicit navigation/scroll-follow events | Account session, rendered page state, local scroll unless following | Research, reading, collecting evidence. |
| Provider-collaborative document | Provider document identity/link plus surrounding canvas context | Each person's authorized provider account; provider owns its edit protocol | Documents already supporting simultaneous editing. |
| Shared browser runtime | One browser session's published pixels and single-controller input | Workspace cameras and surrounding native canvas edits | Complex sites, forms, dashboards, or account-specific state that cannot be merged. |
| Purpose-built adapter | Precisely declared application state and operations | Everything outside that declaration | Deeper integration where APIs and behavior are understood. |

In reference mode, the same URL can render different content for different users. Display that distinction; do not replay clicks as a substitute for application synchronization. Scroll-follow is optional and may be approximate across responsive layouts. A frozen captured quotation remains stable if today's page changes.

In provider-document mode, do not rebuild the provider's editor, copy credentials, or claim its offline guarantees. Open the same provider document with each person's own access. Lack of provider access does not erase the surrounding shared discussion.

In shared-runtime mode, there is one browser state and one controller. Authentication, form drafts, downloads, and side effects occur in that runtime. Sharing a browser surface must make that fact clear. Never replicate cookies, passwords, or private storage into collaborators' independent browsers as a convenience mechanism.

Adapters must declare their source identity, supported operations, shared state, recoverable state, account boundary, and failure modes. An adapter can add stable text extraction, selected-element capture, document-relative annotations, return-to-source anchors, or restoration. These improve the base workflow; installation of an adapter is not required to place an ordinary native window on the canvas.

## 11. Sharing and access boundaries

Personal workspaces are private by default. Sharing can publish selected objects/a frame or a workspace. Provide a preview of what will become visible, with clear file and live-window consequences. Access to a canvas preview, source bytes, and runtime control are separate permissions.

| Material | Default sharing behavior |
| --- | --- |
| Native notes, shapes, and captures in a shared scope | Share durable content and its revisions according to that scope. |
| Local file reference | Share a chosen preview/reference; indicate that source bytes are unavailable to others until explicitly published or linked to an accessible shared source. |
| Application window | Share a chosen frozen visual until live sharing is explicitly enabled; control is separately granted. |
| New native material placed inside an explicitly shared frame | Share it, with a visible frame scope indicator and drop feedback. |
| Newly admitted app window or local file inside that frame | Show its limited publication state; do not silently start live capture or upload private file bytes. |
| Application child UI | Include only the declared window family; a new runtime binding or unrelated window requires an explicit scope decision. Ordinary content changes within the already shared surface remain visible. |

Members have view/edit access appropriate to the shared scope; runtime control is an additional grant. Protect unpublished local content from serialization or asset fetches by other participants, not merely by hiding it in the UI. Local absolute paths and private URLs are not automatically public provenance.

An adapter that can detect account or document-identity changes may pause publication or request a scope decision. A generic captured window cannot reliably detect every in-app account switch; the product must not promise that protection. The sharing UI identifies the published surface, and the host can pause it immediately.

Publication persists when an already published object is moved or reparented. Moving it out of a shared frame or into a private frame does not revoke access; it remains visibly shared until explicitly unshared. Moving private material into a shared scope previews and applies the publication rules above. Moving between shared scopes previews any added audience; audience reduction is explicit. A private parent is not published merely because it contains a shared object: other participants see the permitted object at its world position without private parent metadata. A drop affecting publication shows the resulting audience before it commits.

Revoking access prevents future retrieval and updates; it cannot retract a screenshot or file already legitimately copied by another person. This boundary should be stated where sharing/revocation decisions are made, without repeated warnings during ordinary work.

Offline clients may keep previously authorized cached material. Reconnect verifies current access before publishing pending edits. If access was removed, preserve those edits as a private recoverable draft and offer export or another authorized destination; do not silently discard them or publish them anyway.

## 12. Minimal conceptual architecture

The boundaries below prevent incompatible implementations by different agents. They are responsibilities, not a demand for separate services or a specific framework. Prefer a small number of components in one deployable host until a real need requires separation.

```text
Desktop host
  ├─ Canvas renderer + selection + tools + camera
  ├─ Input/focus router + system clipboard + native drag
  ├─ Durable workspace document + assets + history
  ├─ Runtime coordinator
  │    ├─ General native application adapter
  │    ├─ Browser/application adapters
  │    └─ Capture + restore + control capabilities
  └─ Collaboration
       ├─ Shared document operations + presence
       ├─ Published assets + permissions
       └─ Live media + single-controller input
```

### 12.1 Persistent records

Use stable generated identifiers, explicit schema versions, and migrations. The following fields describe semantic needs, not a frozen wire format:

| Record | Minimum responsibilities |
| --- | --- |
| Workspace | ID, schema version, title, object collection, named destinations, share scopes. |
| Object | ID, type, transform, logical bounds, stacking key, parent/group membership, content reference, revision, deletion state, publication scope. |
| Source | ID, kind, canonical file/URL/document identity where available, local access locator, optional adapter ID; restricted metadata separate from shared fields. |
| Asset | ID, media type, dimensions/size, local storage locator, durable availability, revision, publication state. |
| Capture | Asset ID, source/object link, capture time, region, available source revision, frozen/live-origin distinction. |
| Recovery descriptor | Source ID, adapter and version, supported saved fields, saved time, known restore depth. Sensitive session data stays in appropriate local secure storage. |
| Personal view | User/device/display ID, camera, recent destinations, local focus context; no persisted remote input grant. |
| Operation/history entry | Operation ID, author, ordering metadata, affected IDs, semantic operation/inverse or recoverable prior state. |

Runtime bindings, transient OS handles, pointer presence, capture streams, open processes, and control grants are ephemeral. Persist hints only when useful, never as guaranteed identities. A source can have multiple views; an object can reconnect to a different runtime without becoming a new object.

### 12.2 Coordinate and transform rules

Store world-space positions independent of monitor dimensions and device pixel ratio. Keep app viewport dimensions, canvas transform, camera transform, and capture crop coordinates distinct. Convert explicitly at each input/capture boundary. Use a representation and origin-rebasing strategy that retain precision at distant coordinates.

Nested frames are allowed with acyclic membership. Resizing a frame changes its boundary, not its members. Scaling a group changes eligible native canvas geometry; application members change their presentation geometry, not their internal viewport, unless the user invokes an explicit window-resize operation. A group containing an unsupported transform exposes that restriction before committing.

### 12.3 Runtime/adapter interface

Every adapter provides the equivalent of these operations, with unsupported outcomes allowed and typed:

- Discover/identify a source and runtime; report current capabilities.
- Attach to a verified runtime; open a source; optionally restore a supported session.
- Activate/deactivate and coordinate native presentation when available.
- Capture still/live visuals with source identity, timestamp, size, and crop mapping.
- Export/import material through supported semantic operations.
- Observe lifecycle and child surfaces; expose dirty-state knowledge as known/unknown.
- Gracefully close when explicitly requested; cancel pending operations.
- Publish a scoped surface; acquire/revoke a control grant where supported.

Use cancellable requests with request IDs. Opening requests are coalesced; stale capture/open responses cannot overwrite a newer object binding. Disposal removes observers, streams, and temporary resources without implicitly killing the source app. Never retry arbitrary application input or external side effects as though they were idempotent reads.

### 12.4 Synchronization and media

Document synchronization carries native content, structure, geometry, and published metadata. Assets travel through a durable asset channel. Presence and high-rate pointer positions are ephemeral. Live application pixels use an appropriate media transport; do not store every video frame as a workspace document edit.

A shared capture becomes usable to others only when its permitted bytes are available; until then show “Uploading” or equivalent. An offline operation references stable asset IDs and can resume transfer without duplicating objects. Failed partial transfers retain retry state and do not masquerade as complete publication.

Use ordinary authenticated transport for remote sessions. Keep local-only work available without a relay/service dependency. Do not build a general distributed application runtime scheduler merely to satisfy collaboration.

## 13. Interface and discoverability

The canvas occupies the screen. Use a compact creation/tool strip, unobtrusive workspace/search control, contextual object actions, and an optional inspector. Panels should be dismissible and should not turn the environment into a permanently partitioned dashboard.

Essential creation tools are pointer, hand, text, sticky, shape, connector, pen/highlighter, frame, image/file import, and app/window admission. Creation is direct: choose a tool, click/drag in place, begin editing. Avoid a configuration form before a note can exist. Tool shortcuts operate only when their recipient is the canvas.

Object titles and subtle type cues support recognition at a distance. Only consequential state is persistently visible: selected, receiving input, shared/live, unavailable, saving failure, or controlled by someone else. Detailed provenance, source access, and capability information belongs in inspection/context actions. A thumbnail must not appear live if it is stale; a persistent timestamp need not clutter every up-to-date image.

Selection outlines, focus outlines, and collaboration cursors have distinguishable treatments. Status cannot rely on color alone. Provide keyboard access to search, creation, selection, activation, host escape, and essential object actions. Native IME, text selection, accessibility focus, display scaling, and reduced-motion preferences must survive host integration. These are ordinary desktop usability requirements, not a separate accessibility platform project.

An empty workspace supports immediate creation and bringing in an actual application. Example content can teach the gestures but must be removable and clearly synthetic. Do not present fake collaborator avatars, fake runtime activity, or fake save confirmations as product state.

## 14. Performance and operational quality

The product should feel like a working desktop under representative use, not only an empty canvas. Initial measurement profile: one documented contemporary Mac, 500 mixed objects including 50 stored window/file previews, three live surfaces, and two participants on a documented local network. Record OS, hardware, application versions, display scale, content sizes, and whether runtimes were already running.

The following are proposed tuning budgets, not measurements or established feasibility claims:

| Interaction | Initial target |
| --- | --- |
| Pan/zoom while previews are available | Aim for display refresh rate; p95 frame time at most 33 ms on a 60 Hz measurement setup, with no repeated 100 ms main-thread stalls. |
| Local pointer/selection feedback | Visible response within 50 ms under the representative scene. |
| Reopening a saved scene | First useful stored view within 1 second; application launches may continue independently. |
| Capture | Immediate visible acknowledgment; a normal window capture available to annotate within 1 second when the source is ready. |
| Small native content edits | Local durable save normally within 1 second after the edit settles; indicator remains pending until acknowledged. |
| Ordinary local application activation | Host overhead should normally remain below 200 ms when the app is already usable; report application launch time separately. |
| Shared surface | Target usable 15–30 fps and under 250 ms input-to-visible-update latency on the stated local-network profile; measure rather than promise across the internet. |

Measure canvas rendering, capture/encoding, network media, decoded assets, and external application memory separately. Report the actual cost of keeping runtimes alive. Use visibility culling, level of detail, bounded caches, and capture scheduling before inventing process termination policies. Repeated open/close/share/unshare operations must not leak streams, observers, windows, or ever-growing asset buffers.

Diagnostics should identify failed source binding, persistence, capture, control, and transfer operations with useful reasons. Avoid logging document contents, clipboard payloads, account tokens, or private URLs by default. A local diagnostic export can help reproduce a failure without becoming a telemetry infrastructure project.

## 15. Failure behavior matrix

| Failure | Preserve | User-visible recovery |
| --- | --- | --- |
| Capture permission denied/revoked | Canvas content and saved visuals | Explain affected capability; open appropriate permission guidance; retry when available. |
| Native input/positioning unsupported | Spatial object and source identity | Open original app; show degraded integration; never route input blindly. |
| App/window disappears | Last durable visual and context | Reconnect, reopen source, or inspect historical capture. |
| Source renamed/moved | Object identity, history, annotations | Resolve through supported identity or offer relink; do not guess by filename. |
| Source deleted or changed externally | Historical captures and workspace edits | Open current source when available, relink, or preserve unavailable reference. |
| Native app has unsaved work | Running instance whenever possible | Normal save/cancel before closure; accurate recovery-depth indication. |
| Disk full or asset write interrupted | Confirmed durable revision and available pending changes | Clear saving failure, retry, recover/export pending work. |
| Network disconnected | Local edits and permitted cached assets | Offline indicator; replay document operations after access revalidation; never replay queued app input. |
| Runtime host offline | Last actually published visual and shared canvas content | Host-offline status; await reconnect or explicitly open a separate source instance. |
| Control connection interrupted | Application state; consistent input release | Revoke grant, clear held inputs, allow deliberate reclaim/re-request. |
| Clipboard/drop rejected | Original canvas content/file | Keep source unchanged; explain failure; permit explicit alternate format. |
| Host crash or display removed | Durable scene and surviving apps | Reopen scene; bring native windows onto an available display; retain world positions. |
| Sharing revoked while offline | Authorized cache and unshared pending local work | Stop future publication; recover edits privately; never silently discard them. |

## 16. End-to-end acceptance

Acceptance uses real supported applications, actual system clipboard and drag sessions, real files, independent participant sessions, and process restarts. A simulated editor or a replayed prerecorded screen may validate design but cannot pass native, persistence, or collaboration requirements. Label such evidence explicitly.

Choose and record a small set of locally available applications: a browser, document/text editor, image or slide editor, PDF viewer, and an application running a background task. Use non-sensitive fixture documents and reversible operations. Do not install paid applications or depend on private production accounts merely to make a demo pass.

### E2E-01 — A real desktop scene

Admit an existing document window and launch another unrelated application. Place them at arbitrary overlapping coordinates alongside a file, sticky, text, shape, ink, image, and connector. Edit an actual source document through its active presentation. Open that document outside the workspace.

**Pass:** the actual source changed; all objects coexist on one plane; the app remains operable; the workflow did not require a fake editor or reconstructing the scene elsewhere. Exit the host and verify that the native windows remain reachable.

### E2E-02 — Free arrangement and input

Select an inactive app, zoom in/out, and verify that typing does not edit it. Activate it, type using an IME, select text, scroll, use its menu, open/cancel a save dialog, then return through the host command. Move a frame with members, resize its boundary, move one member out, overlap objects, select behind, tidy a subset, and undo. Enter focus view and return.

**Pass:** input follows §5; no initiating click triggers app content; IME and dialogs remain usable; zoom does not reflow the app; frame resize does not resize members; unselected objects do not move; focus view restores the prior context. No stuck keys, pointer capture, or hidden modal remains.

### E2E-03 — Capture, explain, and paste

Capture a distinguishable region of a real native window, including while another canvas object overlaps its presentation. Add an arrow, a note, and a shape. Copy the composition into a real slide/document/image application. Change the source and repeat capture.

**Pass:** the first crop contains the intended source pixels, not host controls or an unrelated overlay; annotation placement survives transfer; the first capture and pasted result remain unchanged; the new result is a separate revision/capture. Capture is usable without visiting a screenshot directory.

### E2E-04 — Two-way clipboard and native drag

Copy real application text and an image onto the canvas. Edit the text, paste it back into a native app, and verify text remains text. Copy native canvas objects into another canvas region and verify editability. Drag an actual file into an app import target; drag a generated composition as a file into Finder or an equivalent destination. Cancel another drag and reject another drop.

**Pass:** the system clipboard is used; object fidelity and fallback rendering follow §6; native drag works independently of paste; delivered files are valid; failed/canceled transfers do not remove their sources or create misleading completed objects.

### E2E-05 — Copy, reference, live, and external change

Create two references to one real file, a frozen capture, and an explicit live view. Modify the file externally, close its app, remove one canvas reference, then reopen/relink the remaining source as needed.

**Pass:** file references remain references; removing one does not delete the file; the frozen capture remains historical; the live view updates or reports staleness; source access and source bytes are not confused with a preview.

### E2E-06 — Departure, restart, and truthful resume

Arrange an irregular scene across distant regions. Create native canvas edits and captures, save actual app work, and leave one known background task running. Close/reopen the host process and activate a source. Repeat after an app restart and a device restart where practical. Include a changed URL, moved file, unavailable app, and ambiguous window titles.

**Pass:** confirmed durable objects, identities, arrangement, and material return; camera is personal; runtimes reconnect/reopen without duplicate activation; the background task survives ordinary navigation/host departure; each restoration depth is truthful. Reopening never rewrites current external data with historical state.

### E2E-07 — Unsaved work and persistence failure

Create unsaved native work and start a long operation, then pan far away and lower the capture budget. Use controlled storage failure to interrupt a canvas save and an image-asset write. Recover storage and restart the host after confirmed saves.

**Pass:** navigation/capture throttling does not terminate tasks or discard native work; saving failure is visible; a saved object never points to missing asset bytes; pending work has a recovery route; the reopened scene contains exactly the confirmed durable state, without a false success claim.

### E2E-08 — Concurrent native canvas work

Use two independent users/clients. Edit different notes, jointly edit one text object, move the same object, move a frame while membership changes, and undo each user's work. Pan independently, enter follow mode, then navigate to leave it. Disconnect one participant, edit, delete a concurrently edited object, and reconnect.

**Pass:** deterministic shared content/layout, independent cameras, recoverable conflict outcomes, no double-applied frame move, no silent edit loss, no undo of another person's unrelated work, and no involuntary following.

### E2E-09 — Shared ordinary app and handoff

Share a real application window from one host to another participant. Watch live updates, annotate a frozen frame, request/grant control, and edit the real document. Paste controller-local text and import a controller-local file through declared transfer capabilities. Try input from the former controller, reclaim locally, and deliberately move focus outside the granted window family. Disconnect the controller and then the runtime host. Reconnect deliberately.

**Pass:** only the valid controller sends application input; handoff preserves the runtime; delayed old events are rejected; local takeover and focus changes cannot redirect remote input; explicit transfers deliver the intended bytes without global clipboard mirroring; disconnection releases held keys/buttons; viewers retain published material; host-offline state is apparent; reconnect does not grant input silently. No unrelated desktop content is exposed.

### E2E-10 — Browser modes in a mixed scene

Share a reference page and frozen excerpt, open a provider-collaborative document with two authorized accounts, and operate an arbitrary site through one shared browser runtime. Place an ordinary native window and canvas note next to them. Change the reference page, revoke one source's access, and reconnect a client.

**Pass:** each mode follows its declared semantics; a common URL does not imply identical sessions; provider edits use the provider's collaboration; arbitrary-site state has one controller; account data is not silently copied; surrounding canvas work remains usable when source access fails.

### E2E-11 — Sharing, system UI, and recovery

Publish a selected frame containing a note, capture, local file reference, and application surface. Add a new file and new window; open an app sheet and floating palette. Move a published object out of the frame, then into a private frame, and finally explicitly unshare it. Verify a viewer's access before/after publication and revocation, including the absence of private parent metadata. Disconnect a display and revoke capture permission, then exit the host.

**Pass:** native material follows the declared scope; local source bytes/live streams require the declared publication action; unpublished content cannot be fetched by viewers; dialogs stay usable; no private desktop fallback appears; windows remain accessible after exit and the spatial scene is preserved.

### E2E-12 — A continuous deliverable workflow

Research in a browser/PDF and a native data/document app. Capture evidence, compose an explanation, collaborate on a note, hand control of an ordinary app to a colleague, paste material into a real final document, save it, leave, and resume later after an upstream source changes. Open the deliverable outside the workspace and revisit its original evidence inside it.

**Pass:** the deliverable is independently usable; the old evidence remains faithful; current sources and availability are clear; work resumes without manually rebuilding windows, exports, or project pages. This is the principal product acceptance session, not an optional demo after unit tests.

### 16.1 Traceability and evidence

| Invariant | Primary acceptance coverage |
| --- | --- |
| INV-01, INV-02 | E2E-01, E2E-02, E2E-11, E2E-12 |
| INV-03 | E2E-02, E2E-06, E2E-08 |
| INV-04 | E2E-02, E2E-09 |
| INV-05 | E2E-03, E2E-04, E2E-12 |
| INV-06 | E2E-05, E2E-06, E2E-07 |
| INV-07 | E2E-08, E2E-09, E2E-10 |
| INV-08 | E2E-03, E2E-05, E2E-10 |
| INV-09 | E2E-01, E2E-06, E2E-07, E2E-11 |
| INV-10 | E2E-12 plus comparison against the complete spec and gap report |

For each supported capability, record scenario, actual apps/versions, fixture, actions, observed result, evidence location, and remaining limitation. Use videos/screenshots where they substantiate interaction, plus the resulting external file or persisted scene. Automated tests should target meaningful invariants: coordinate mapping, input ownership, object identity, merge/undo behavior, crash-safe writes, permission enforcement, and stale control rejection. Test counts alone do not establish the experience.

## 17. Implementation plan without reducing the product

The following work packages describe dependencies toward one full product. They are not separately redefined products and do not authorize declaring the first working package the completed vision.

| Package | Concrete outcome | Dependencies / evidence |
| --- | --- | --- |
| A. Native feasibility and input | Real application surface can be admitted, manipulated in context, activated, captured, and exited safely | Resolve §7 gates with real apps before committing the host architecture. |
| B. Persistent spatial document | Freeform mixed native canvas objects, stable identities, frames, history, saved scenes | Can proceed alongside A with an explicit adapter boundary; mocks remain labeled. |
| C. Material transfer | Real capture, system clipboard, native file/content drag, source provenance | Integrates A and B; passes E2E-03/04. |
| D. Lifecycle and recovery | Reconnect/reopen/session depth, resource policy, save failures, source changes | Builds on persistent identities and verified native capabilities; passes E2E-05/06/07. |
| E. Shared canvas and publication | Concurrent native editing, asset transfer, independent views, selective sharing | Uses B's stable operations and assets; passes E2E-08 and publication portions of E2E-11. |
| F. Shared runtime | Live surfaces, controller grants, disconnect/reclaim, scoped child UI | Uses A, D, E; passes E2E-09. |
| G. Browser/application modes | Reference workflow, provider document integration, shared browser session, selected deeper adapters | Builds on source and runtime contracts; passes E2E-10. |
| H. Desktop acceptance and refinement | One convincing complete workflow with system UI, multiple displays, measured performance, recovery | Runs all scenarios, especially E2E-12; resolves gaps rather than replacing them with mock behavior. |

### 17.1 First implementation agent actions

1. Read this spec and the accompanying handoff. Inspect the actual destination repository and preserve existing work. Do not assume the earlier HTML interaction study is a production foundation.
2. Produce a short architecture decision recording the selected host, renderer, persistence approach, and why they preserve the invariants. Keep stack choice proportional to the existing code and available tools.
3. Run the native feasibility scene in package A. Record unsupported behaviors and prototype evidence before building large amounts of UI around an unverified native approach.
4. Establish the shared object/source/runtime/asset contracts. Assign implementation ownership so agents do not independently invent incompatible focus, clipboard, persistence, and collaboration models.
5. Implement coherent end-to-end slices through the dependency graph. Keep a capability report with **implemented and verified**, **implemented but unverified**, **simulated**, **unsupported on current host**, and **not implemented** states.
6. Use real workflows to review each slice. Continue toward the full specification; do not silently delete deferred requirements from the completion definition.

Routine reversible engineering choices can proceed under the proposed defaults. Ask the user only when evidence requires a consequential departure: changing the target desktop/platform, requiring remote execution of personal apps, narrowing ordinary native-window support, introducing paid/hosted dependencies, or accepting a defining interaction failure. Present the concrete failed behavior and alternatives, not a speculative permission checklist.

### 17.2 Deliverables expected from implementers

- Source code and a reproducible way to build/run the desktop experience.
- A concise architecture/decision record and current capability/gap report.
- Durable storage and recovery behavior documented at the level needed to operate and debug it.
- Evidence for real app workflows, actual clipboard/drag interoperability, restart/recovery, and two-client collaboration.
- A user-facing guide for essential gestures, source/copy/live semantics, sharing, and host exit/recovery.

Completion means the promised supported profile passes the full continuous workflow with limitations explicitly agreed and recorded. A polished canvas demo, passing unit tests, or a collection of disconnected native experiments is insufficient.

## 18. Unresolved decisions and their decision points

These are the remaining consequential questions. They do not block unrelated work, and they do not reopen already established product requirements.

| Decision | Working default | Resolve using |
| --- | --- | --- |
| Can the macOS public-API approach provide convincing native interaction at a spatial location? | Hybrid preview and real native activation | Package A evidence, especially overlap, transient UI, native drag, multi-display and exit. |
| Exact renderer and persistence stack | Fit the destination repository and native-host requirements | A small proof of integration and measured scene; avoid selecting by a visual mock alone. |
| Exact host gesture mapping | Explicit activation and configurable dedicated host command | Real app shortcut/IME/accessibility tests; retain input ownership invariants. |
| Browser host and first semantic adapters | Use existing provider collaboration and a real shared browser runtime where needed | Demonstrate §10 modes with actual browser behavior; do not require a custom browser engine without evidence. |
| Shared relay/media transport and deployment | Local operation plus the smallest authenticated synchronization/media arrangement needed for two clients | A real collaboration session and documented network constraints; hosted costs need a deliberate decision. |
| App restoration depth | Reconnect first, reopen source second, deeper state only through verified adapters | A per-application recovery matrix covering clean exit, app crash, host crash and device restart. |
| Personal alternate layouts for the same shared objects | Shared layout plus personal cameras/focus only | Add a different layout model only after a concrete workflow justifies its conflict and reference semantics. |

## 19. References and prior artifacts

These sources inform API boundaries and interaction precedents. Reading them does not count as empirical validation of this product.

- [FigJam pan and zoom](https://help.figma.com/hc/en-us/articles/1500004414582-Pan-and-zoom-in-FigJam): familiar canvas navigation and view commands.
- [FigJam selection, movement, and order](https://help.figma.com/hc/en-us/articles/1500004292221-Select-move-and-order-objects-in-FigJam): selection and optional arrangement precedent.
- [Apple ScreenCaptureKit — SCWindow](https://developer.apple.com/documentation/screencapturekit/scwindow): window capture representation; not an arbitrary embedding or restoration API.
- [Apple Accessibility — AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue): capability-dependent accessibility operations and error handling.
- [Apple NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace): application launch and source opening.
- [Apple AppKit state restoration](https://developer.apple.com/documentation/appkit/restoring-your-app-s-state-with-appkit): participating applications encode and restore their state; it is not a universal third-party resume guarantee.
- [Apple NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard): system data transfer representations.
- [Apple file promises](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises): native drag delivery is a separate integration from ordinary clipboard copying.
- [Chrome Page Lifecycle API](https://developer.chrome.com/docs/web-platform/page-lifecycle-api): frozen/discarded browser states differ; lifecycle terminology must not overstate recoverability.

The earlier `spatial-workspace.html` study demonstrates intended free placement, selection, gestures, simplified windows, and some transfer/resume concepts. It does **not** implement real OS windows, system clipboard interoperability, native application restoration, or networked collaboration. The earlier rigid project-dashboard direction was rejected and must not be used as the target design.

This spec deliberately does not prescribe mandatory AI, a universal knowledge graph, a replacement editor for every application, 3D navigation, or a fixed project-management schema. Those additions are unnecessary to realize the stated desktop experience.
