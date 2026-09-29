# Storage and Recovery

## Location

`~/Library/Application Support/CanvasWorkspace/<profile>/` (override with `CANVAS_DATA_DIR`).

| Path | Contents |
| --- | --- |
| `workspace.sqlite` | SQLite database in WAL mode with `synchronous=FULL`. |
| `assets/<sha256>` | Content-addressed image bytes (captures, previews, pasted images). |
| `staging/` | Asset writes in progress; emptied at startup. |
| `identity.json` | This profile's user ID and display name. |
| `received/`, `managed/` | Files received from drag promises; managed file copies. |

## Tables

| Table | Contents |
| --- | --- |
| `chunks(seq, scope, full, bytes)` | Automerge changes per scope document. The newest `full=1` row plus later rows reconstruct a scope. Compacted when a scope exceeds 200 rows at startup. |
| `assets(id, mime, width, height, size, created)` | Committed assets. A row exists only after the bytes are durable. |
| `records(kind, id, json)` | Local, restricted records: `source` (file bookmarks, window hints, document paths), `capture` (provenance), `view` (personal cameras), `share` (hosted/joined scopes, members). Never synchronized. |
| `meta(key, value)` | Workspace ID, last listen port. |

## Write protocol

1. Asset bytes are written to `staging/`, `fsync`ed, renamed to `assets/<sha256>`, and the directory
   is `fsync`ed.
2. One SQLite transaction inserts the asset rows and the document changes that reference them.
3. The UI shows "Saved on this device" only after that transaction commits.

If step 2 fails, the changes stay in memory as pending, the status shows "Not saved — …", and the
host retries every 5 seconds. Workspace → Export workspace… writes all scope documents and assets,
including pending changes held in memory. Orphan asset files (bytes without a committed row) are
removed at startup.

## Testing failures

- `CANVAS_FAIL_STORAGE=chunks` or `=assets` at launch, or Debug → Simulate Storage Failure /
  Simulate Asset Write Failure, makes the corresponding writes fail until turned off.
- `--automation` opens a local Unix socket (path printed to the log) that accepts commands such as
  `state`, `fail chunks`, `snapshot <path>`; see `Sources/CanvasHost/Automation.swift`.
