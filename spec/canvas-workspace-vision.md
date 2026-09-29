# Canvas Workspace

## A complete desktop on a persistent, shared plane

Canvas Workspace turns the desktop into a freely arranged two-dimensional space. Native application windows, files, notes, drawings, and captured material occupy the same surface. The screen is a movable viewport onto that space. People can spread work out, move between activities, collaborate, leave, and return to the place where they stopped.

This document describes the complete product vision. It does not define an MVP, delivery sequence, technical architecture, or verified implementation. **Established requirements** reflect the user's stated direction. **Proposed behavior** makes that direction concrete for discussion. **Open questions** identify choices that remain unsettled. Platform, operating-system integration, hosting, and a local-first strategy remain open; earlier suggestions do not establish those decisions.

## Established requirements

The workspace is the desktop environment itself. It accommodates arbitrary native application windows and files alongside FigJam-style sticky notes, shapes, text, frames, and connectors. Objects can be positioned, resized, grouped, and overlapped freely. Organization does not require opening successive pages or fitting content into rigid tiles.

Zooming, reduced detail, screenshots, icons, and the distinction between manipulating a frame and operating its contents should borrow established canvas conventions. Tidy and alignment tools are available when wanted; arranging everything is never a prerequisite for working.

Material must move naturally in both directions. Users can capture a window or selection onto the canvas, then copy or drag canvas content into a real application. The experience should minimize the feeling of crossing separate systems.

Workspaces persist beyond the lifetime of their running applications. Returning should recover the working context and offer the best available continuation. Collaboration can vary by object: native canvas content supports joint editing, selected applications gain deeper integration, and ordinary windows can have one operator while others see their screen or results.

## Proposed behavior: inhabiting the desktop

A spreadsheet window can sit beside a PDF, a handwritten calculation, and a file awaiting review. Another activity can remain farther across the surface. Moving there changes the view without dismantling the first arrangement. Frames give areas names and boundaries without becoming mandatory folders or separate pages.

At a distance, a window can become a recognizable thumbnail or application icon with a short title. At closer scales, its contents become readable. Notes and drawings use comparable levels of detail. Overview, search, and named destinations help users return to a location without requiring them to remember coordinates.

The canvas preserves deliberate arrangements. Optional tidy commands operate on a selection or frame and can be undone. They do not continuously rearrange objects as their contents change. A user can leave an untidy but meaningful working scene intact.

A maximized working view can temporarily emphasize one application while retaining its location in the surrounding workspace. Returning to the wider view reveals the same neighbors. The precise behavior across multiple physical displays remains a design choice.

## Proposed behavior: looking and operating

**Display scale and input focus are separate.** Zoom determines how an object is presented. Focus determines where keyboard, pointer, scrolling, and drag input go. Making a window larger does not itself grant control to it.

In canvas mode, users select and arrange objects. Entering a native window gives the application its ordinary interaction behavior. A visible but restrained focus treatment identifies the recipient of input. A consistent escape gesture returns control to the surrounding canvas. The analogy is entering and leaving an embedded or virtualized environment, without implying that every application runs in a virtual machine.

The outer frame remains a handle for moving the whole window; dragging inside an active application retains the application's meaning. Canvas navigation also needs a dependable gesture that works while a window has focus. Exact activation gestures, modifier keys, and shortcut conflicts are open questions to test through interaction design. The guiding behavior is predictable input ownership using familiar canvas conventions.

## Proposed behavior: moving material across boundaries

A capture gesture can take an entire window or a selected region and place it directly on the canvas. The captured object can be annotated, grouped, connected, duplicated, or pasted elsewhere. Where available, its source and capture time remain inspectable, making it possible to revisit the originating application or file.

Copying a canvas selection prepares useful clipboard representations. Text can remain text, an image can remain an image, and a mixed annotated composition can paste as a coherent visual. A destination that supports richer content can receive editable elements. Unsupported structure should flatten predictably, with the result understandable before an important paste. Dragging a file into an application follows the destination's ordinary behavior.

Three forms of material coexist:

| Form | Meaning | Expected behavior |
| --- | --- | --- |
| Copy | Independent material taken at a moment in time | Later source changes do not alter it. |
| Reference | A connection to an existing object or source | It retains a route back; following the reference may reopen the source. |
| Live content | A view that follows a current source | It updates while the source and connection are available. |

A screenshot is ordinarily a copy. A link to its source can accompany it without making the image live. A live view can be frozen into a copy. Creating a reference does not automatically authorize edits to the source. These distinctions should be evident without presenting a configuration form for every capture or paste.

## Proposed behavior: persistence and continuation

A persistent workspace object has an identity and position independent of its current runtime. Closing an application does not erase its place in the workspace. A window object can retain a recent visual record, its source file or address, and any supported restoration information. Multiple views of the same file can retain different viewing positions while still referring to that file.

Running instances are acquired when needed. A distant or inactive object may display a stored representation; entering it can reconnect to an existing instance or open the source again. Resource management should preserve the user's arrangement and make a transition visible when continued operation requires loading.

Restoration has different depths. A visual record restores what was seen. A file or address enables reopening. Saved application state can recover a more specific session. A surviving runtime can continue its current operations. Unsaved edits, transient dialogs, remote sessions, and externally changed files cannot be assumed recoverable merely because a screenshot exists.

The ideal is to preserve as much continuity as possible and show what is actually available. “Resume” should return the user to a truthful working state. Historical captures remain distinguishable from current results. Restoring a previous workspace view also needs a separate, deliberate meaning from reverting the contents of its source files.

## Proposed behavior: collaboration by capability

Participants share a workspace while keeping independent viewports. One person's pan or zoom does not move everyone else. Following a collaborator is an explicit action. Shared selection, pointing, and annotations can support discussion around any visible object.

Canvas-native notes, shapes, and text support simultaneous editing. An application-specific integration can share deeper state where its meaning is understood. A browser integration, for example, might coordinate navigation and shared material while allowing independent views; editing inside a website still depends on the capabilities provided for that content.

An ordinary application window can remain under one operator's control. Others can watch a live image, receive occasional snapshots, or inspect its latest published state. They can discuss and annotate around it even when they cannot edit its internal contents. Requesting control and handing it over should be explicit.


Seeing a shared object, operating its live instance, and opening the same source in another instance are distinct actions. A visible screenshot does not imply that every participant possesses the source file or can restore the application. An operator going offline should leave a meaningful record of the work that was shared.

## Complete working scenes

### 1. From an application detail to a presentation

A researcher has a native spreadsheet, a PDF, and a slide editor arranged nearby. They capture a chart region onto the canvas, place an excerpt beside it, and draw an arrow explaining the comparison. They select the composition and paste it into the slide editor. The result uses the richest representation that the destination supports. The original applications remain available in place for checking the numbers. The composition records the evidence used for that slide; a later spreadsheet edit does not silently rewrite the captured argument.

### 2. A design discussion alongside the real editor

A designer keeps a native editing application open inside a shared frame. They capture the current design beside it. A colleague draws over that capture and adds a note while the designer changes the real document. Everyone can compare the preserved starting point with the current window. A useful image or text suggestion moves from the canvas into the editor through ordinary drag or paste. When the designer leaves, the frame retains the discussion and latest shared result; continued editing depends on access to the source and a usable application instance.

### 3. Leaving a complicated activity and returning

A user is planning a move with browser windows, a floor-plan file, a budget, and informal notes spread across one area. They leave without collecting everything into a summary document. On return, the arrangement and captured material are immediately recognizable. Entering the budget resumes the available session or reopens its file. A browser view reconnects or reloads with its status apparent. An old captured quotation remains an old quotation, while the current website can show a new price. The user continues from the unfinished comparison beside the floor plan.

### 4. Crossing from a shared discussion into individual work

Two colleagues discuss a proposal around several documents and canvas sketches. Each moves their own view to inspect supporting material. One operates an ordinary native application while the other marks up a captured result. A passage drafted on the canvas is copied into the document editor. A file is dragged from its workspace position into an application's import target. They leave the discussion area with its evidence and decisions intact, while the actual deliverable remains a real document that can be used outside the workspace.

### 5. Turning something observed into something usable

A user pauses a native video player, captures a small visual detail, and places it beside reference images and a freehand sketch. They enlarge the capture, annotate it, and copy a selected part into an image editor. Later they return an edited result to the canvas and paste a concise composition into a message. The sequence does not require opening a separate whiteboard site, manually finding a screenshot file, or rebuilding the composition in each destination. Its usefulness comes from immediate movement between seeing, thinking, and acting.

## Open design questions and review criteria

The following questions guide evaluation of the complete experience. They do not define a delivery order.

- **Input handoff:** Can users always identify the recipient of typing, scrolling, and dragging? Can they return to the canvas without fighting an application's shortcuts?
- **Content meaning:** Are copies, references, and live views understandable in ordinary use? Which gestures choose between them without slowing down capture and paste?
- **Restoration:** What should the user see when a source changed, a runtime ended, or only a visual record survived? Can they distinguish recovered context from recovered application state?
- **Shared control:** How do participants request control, follow a view, and continue after the operator leaves? When is a separate instance preferable to handing over one instance?
- **Spatial ownership:** Which arrangements are shared, and which personal viewing preferences remain independent? How can collaborators reorganize without disrupting one another?
- **Desktop completeness:** How should menus, dialogs, full-screen media, transient windows, and multiple displays inhabit the same space while remaining familiar?
- **Platform and access:** Which environments can host native windows with the required continuity? Where do files, snapshots, and runtimes live, and how does selective sharing work? macOS, local-first operation, and remote execution are possibilities requiring their own decisions.

The central review is a continuous working session: enter an application, bring material onto the canvas, discuss or transform it, move it into another application, leave, and return. The vision succeeds when these actions feel like work on one persistent desktop and retain clear control over what is current, copied, shared, and recoverable.
