# Canvas Workspace Guide

## Moving around

| Action | Gesture |
| --- | --- |
| Pan | Two-finger scroll, Space-drag, middle-button drag, or the Hand tool (H) |
| Zoom | Pinch, or ⌘-scroll; zoom follows the pointer |
| Fit everything / fit selection | ⇧1 / ⇧2 |
| Go back to the previous view | ⌥⌘[ or Workspace → Back |
| Find objects, file names, app titles, text, places | ⌘F |
| Name the current place | Workspace → Name this place… |

Zooming never gives an application keyboard input. Only activation does.

## Creating and arranging

Pick a tool from the bottom strip, then click or drag on the canvas: Select (V), Text (T),
Sticky (S), Rectangle (R), Ellipse (O), Line (L), Arrow (A), Connector (C), Pen (P),
Highlighter (M), Eraser (E), Frame (F). Double-click empty canvas to type text.

- Click selects, ⇧-click adds, drag on empty canvas selects a region.
- Drag to move. Dropping into a frame shows the frame highlighted and adds the object on release.
  Hold ⌥ while dropping to move without changing frame membership.
- Frames move their members. Resizing a frame never resizes its members.
- Right-click for Arrange (front/back, align, distribute, Tidy…), Select behind, Group, Inspect.
- ⌘Z undoes your own changes. If someone else changed the same thing later, undo keeps their
  change and tells you.
- Tab and ⇧Tab move the selection through objects in reading order; Return activates or edits.
- In notes and text objects, ⌘B and ⌘I format text and ⌘K adds a link.
- Workspace → History… previews an earlier arrangement; Restore applies it as one undoable step.
  Application actions, websites, and external files are not part of this history.
- Workspace → Workspaces switches between separate canvases or creates a new one.

## Applications and files

- **Bring in a window**: toolbar window button or ⇧⌘N. The window stays a real window of its app.
- **Activate**: double-click the surface or press Return. The view zooms to 1:1, the real window
  moves to the surface's place, and the app owns the keyboard, menus, and clipboard.
- **Return to the canvas**: ⌃⌥Space, the "Return to canvas" button, or click the canvas.
- **Capture**: right-click → Capture window, or Capture region… and drag the area. ⌃⌥C captures
  the active application, or the frontmost window of another app. The capture appears next to the
  source, selected, ready to annotate or copy.
- **Files** are references to the real file. Removing one from the canvas never deletes the file.
  "Duplicate file on disk…" makes a real copy; "Import a managed copy" stores a copy in the workspace.
- Removing an application surface from the canvas leaves the app running.

## Copy, reference, live

| Form | What it is | When the source changes |
| --- | --- | --- |
| Capture (frozen) | An image taken at a moment | Never changes. Capture again for a new revision. |
| File reference | A route to the existing file | Shows the current file; captures of it stay as they were. |
| Live view | Follows a surface while it is available | Updates, or says the source is unavailable. "Freeze as capture" makes a new frozen image. |

## Moving material between apps and the canvas

- ⌘C / ⌘V use the system clipboard. Text stays text; a mixed selection pastes as one image into
  image-capable apps. Right-click offers Copy as image, Copy text, Copy link.
- Drag the small arrow grip next to a selected object to drag its content into another app or to
  Finder (compositions arrive as PNG files). Hold the drag over an application surface for half a
  second and its real window comes forward to receive the drop. Dragging the object itself only
  moves it on the canvas.
- Drop files, images, text, or links onto the canvas to place them.

## Sharing

- Right-click a frame → Share frame… shows what becomes visible before anything is shared.
  File bytes stay on your Mac; app surfaces share their last captured image until you share them live.
- Others join with the invite code (Collaboration panel, ⇧⌘K). Everyone has their own view.
- A collaborator can ask for control of a shared application. You grant it explicitly; using the
  app yourself, the Reclaim button, or ⌃⌥⌘R takes control back immediately.
- The host can make a member view-only or let them edit again from the Collaboration panel.
- Stopping sharing prevents future updates; it cannot recall copies someone already made.

## Leaving

- **Exit to desktop** (⌘Q) saves everything and puts admitted windows back where they were.
  Applications keep running.
- **Hide canvas** leaves the canvas running in the background.
- If windows ever end up out of reach (for example after unplugging a display), use
  Window → Bring Managed Windows onto a Display.

## Shortcuts you can change

The global shortcuts are read from user defaults; for example:

```sh
defaults write io.github.pengw0048.canvasworkspace hostCommand "ctrl+opt+space"
defaults write io.github.pengw0048.canvasworkspace captureCommand "ctrl+opt+c"
defaults write io.github.pengw0048.canvasworkspace reclaimCommand "ctrl+opt+cmd+r"
```

If another app already owns a shortcut, the host records it in Workspace → Export diagnostics….
