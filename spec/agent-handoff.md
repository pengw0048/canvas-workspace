# Canvas Workspace — Implementation Agent Handoff

Start with [the full specification](canvas-workspace-spec.md). The [vision document](canvas-workspace-vision.md) provides background; the specification supplies the concrete behavior and proposed defaults. These Markdown files are portable and do not depend on access to this chat.

## Copyable implementation brief

> Build Canvas Workspace according to the attached `canvas-workspace-spec.md`.
>
> The intended product is a persistent, freely arranged, collaborative 2D desktop canvas containing real application windows and files alongside native notes, text, shapes, ink, frames, images, and connectors. It should support ordinary computer work in one spatial environment: activate a real app, capture material, annotate it, paste or drag it into another real app, collaborate, leave, and resume.
>
> Preserve all product invariants in §2. Do not substitute a webpage with application-shaped cards, a rigid dashboard, a tiling manager, or a whiteboard containing screenshots. Do not silently reduce the destination to an MVP. Build incrementally toward the complete specification, and explicitly track what remains unsupported or unimplemented.
>
> Communicate with the user in Chinese. Write code, comments, commit messages, implementation documentation, and shared technical artifacts in English unless instructed otherwise. Read the destination repository's instructions and preserve concurrent work. Make the smallest coherent changes that advance the specified outcome; do not add unrelated infrastructure.
>
> Treat macOS-first hosting, local durable storage, shared object layout with independent cameras, and the documented gesture mappings as proposed working defaults. They allow implementation to proceed; they are not historical claims of user approval. Routine reversible implementation choices do not need repeated confirmation. Present a concrete tradeoff if evidence requires a defining product or platform departure.
>
> Begin by inspecting the repository and selecting a suitable native host approach. Resolve the native feasibility questions in §7 with actual applications before committing to a large UI architecture. Per-window capture does not prove arbitrary native embedding, transformed input, or exact restoration. Test activation, overlap, input methods, app menus, dialogs, drag/drop, display changes, and safe host exit. A hybrid preview-to-real-window transition is a candidate to evaluate, not a capability to assume.
>
> Keep persistent objects, source identity, runtime bindings, visual presentation, input focus, publication, and controller authority separate. Implement real system clipboard and native drag/drop independently. Preserve unsaved work and background tasks; do not terminate them because they are offscreen. Resume must state whether it reconnects a runtime, restores adapter state, reopens a source, or only shows a historical image.
>
> Build the dependency packages in §17 as coherent end-to-end slices. Parallelize independent work only after agreeing on the shared object/source/runtime/asset and input contracts. Use §16's real workflows as acceptance, especially the continuous research-to-deliverable-to-resume session. Continue implementation after feasibility work; a design note or successful native experiment alone is not completion.
>
> Maintain a capability report distinguishing implemented-and-verified, implemented-but-unverified, simulated, unsupported-on-current-host, and not-implemented behavior. Report actual evidence and remaining gaps. If the chosen native strategy fails, document the exact failure and alternatives, continue unaffected work, and seek a decision only for the consequential change. Never relabel a screenshot as a live app or a visual record as recovered unsaved state.
>
> Deliver runnable source, build/run instructions, concise architecture decisions, the capability/gap report, and real acceptance evidence. The external document/file produced by the workflow must remain usable outside the workspace. Do not claim the full product is complete until its supported profile satisfies the specification and any defining limitations have been explicitly resolved.

## Suggested ownership boundaries

The lead agent owns the integration and acceptance, not just task dispatch. Suggested parallel responsibilities:

| Owner | Responsibility | Agreement needed first |
| --- | --- | --- |
| Native host / runtime | Native admission, capture, focus, child UI, activation, lifecycle, exit/recovery | Capability interface and input ownership. |
| Canvas / durable document | Native primitives, selection, coordinates, frames, assets, history, resume scene | Persistent object/source/asset identities and transform semantics. |
| Material transfer | Capture placement, actual pasteboard formats, native drag, file promises, provenance | Content representations and source/copy/live semantics. |
| Collaboration | Shared document edits, assets, scopes, presence, live media, controller handoff | Published-state boundary, operation semantics, control grants. |

Use fewer owners if that reduces integration overhead. A module owner must test their feature in the continuous workflow; a standalone mock is not sufficient integration evidence.

## What to verify before reporting completion

- Real arbitrary-app integration works for the declared supported profile, with transparent limitations for unsupported surfaces.
- Native objects and real applications coexist in freely arranged, persistent spatial scenes.
- Window/region capture, ordinary system copy/paste, and native drag work in both directions.
- Frozen copies, references, and live content behave differently and predictably after upstream changes.
- Real departure/reopen, app loss, storage failure, and runtime-host disconnection preserve the promised work and give truthful recovery choices.
- Two independent participants can edit native canvas content, keep separate viewports, and explicitly hand control of an ordinary real app over without stale input.
- Browser collaboration uses the declared mode; identical URLs and copied account sessions do not stand in for synchronization.
- The user can leave the host and recover conventional native windows without losing work.

The earlier visual study is optional reference material, not a prerequisite or proof of these capabilities. The full specification and its acceptance scenarios are the handoff's source of truth.
