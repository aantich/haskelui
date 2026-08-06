# Visual Haskell workspace persistence

Status: accepted for the first Visual Haskell editor slice.

## Goals

Visual Haskell remembers the portable editor state associated with an opened
folder. Opening that folder again, whether explicitly or as the last workspace
at application startup, reconstructs the same project view and document tabs.

The design keeps filesystem work outside the pure editor update model. Reads
and atomic writes are represented as explicit runtime effects; parsing,
validation, snapshot construction, and restoration are pure functions.

## Files

Every folder opened as a workspace gets one hidden file at its root:

```text
<workspace>/.vihs
```

The filename is deliberately short, recognizable, and specific to Visual
Haskell. A separate per-user state entry named `last-workspace` contains only
the absolute path of the last opened workspace. A second user-owned file,
`trusted-workspaces.json`, is the authority for compiler-tooling trust. On
Unix-like systems both live under the platform XDG state directory for
`visual-haskell`; Windows will map the same application-state concept to its
standard per-user state location.

The last-workspace entry is only a locator. Portable editor preferences remain
in `.vihs`; security authority remains outside project-controlled files.

## Version 2 format

`.vihs` is UTF-8 JSON so it is inspectable, diffable, and extensible:

```json
{
  "format": "visual-haskell-workspace",
  "version": 2,
  "openFiles": ["src/Main.hs", "README.md"],
  "activeFile": "src/Main.hs",
  "expandedFolders": [".", "src", "packages/haskelui-core"],
  "selectedExplorerEntry": "src/Main.hs",
  "panes": {
    "navigator": { "visibility": "visible", "extent": 230 },
    "inspector": { "visibility": "visible", "extent": 270 }
  },
  "analysisTrusted": true
}
```

All paths are relative to the workspace root and use `/` as the stored
separator. `.` denotes the root. Absolute paths, empty components, and `..`
components are rejected. This makes the file relocatable and prevents a
malicious workspace file from requesting reads outside its own root.

`openFiles` is ordered and therefore also records tab order. `activeFile` is
optional and is ignored if it is not present in `openFiles`. Files opened from
outside the workspace are intentionally not persisted in that workspace.

The pane entries record the state currently represented by the surface API.
Future versions may add window geometry, editor selections, scroll positions,
or multiple tab groups through another explicitly versioned migration.

Document contents are not stored in `.vihs`. Saved files are re-read from
disk. Unsaved-buffer recovery is a separate feature that will require a
private recovery store, explicit retention limits, and crash-recovery policy.

`analysisTrusted` means “restore my previous trusted-mode preference”; it can
never grant trust by itself. Visual Haskell enables compiler tooling only when
the normalized workspace root is also present in the user-owned trust
registry. This two-key rule lets the editor restore the requested state while
preventing a cloned repository from declaring itself trusted. Version 1 files
remain readable and default this field to `false`.

## Lifecycle

Opening a folder performs these operations in order:

1. Reject the switch if a current document has unsaved changes.
2. Establish the new root and read its top-level directory.
3. Read `.vihs` as an optional file.
4. If valid, read expanded directories from shallowest to deepest and then
   read open documents in saved tab order.
5. Select the saved active document and restore pane/explorer state.
6. Restore compiler trust only when `.vihs` requests it and the user registry
   independently authorizes the workspace path.
7. If `.vihs` was absent, atomically create a version 2 snapshot.
8. Update the per-user `last-workspace` locator.

Relevant state changes atomically replace `.vihs` immediately: tab open,
close, selection or ordering; folder expansion or explorer selection; and
pane visibility or extent. Because the persisted state is always current,
normal termination requires no special last-second write.

Invoking **Trust Workspace for Haskell Analysis** atomically requests trust in
`.vihs` and adds the normalized root to the user-owned registry. The model
changes immediately; compiler workspace loading does not wait for either disk
write to complete. On restart, the two files reconstruct the same trusted
state.

An unreadable, malformed, unsupported, or unsafe `.vihs` never blocks opening
the folder itself. Visual Haskell reports the problem and disables writes to
that workspace file for the session, preserving it for inspection rather than
silently replacing it.

## Failure and compatibility rules

- A missing `.vihs` means a fresh workspace and is not an error.
- Missing open files are skipped while the remaining snapshot is restored.
- Unknown JSON fields are ignored for forward-compatible additive changes.
- A format-name or version mismatch is reported and never guessed.
- Writes use a temporary sibling followed by replacement, so interruption
  cannot leave a partially written `.vihs`.
- Native backends do not interpret this format. The editor model and runtime
  own it, making the behavior identical for future AppKit, WinUI, or custom
  rendering backends.
