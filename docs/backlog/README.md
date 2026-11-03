# Backlog

## Language-aware editing

- [Symbol rename](symbol_rename.md): deferred ticket for LSP-driven rename,
  reviewed multi-file edits, unsaved-buffer application, and an explicit undo policy.

## Snippet catalog and organization

- [Snippet collections and hardware-development catalog](snippet_collections.md):
  proposed ticket backlog for SV design/verification, Xilinx register terminology,
  core/testing/Jane Street OCaml, Signal-first Hardcaml design/verification, and
  collection discovery and activation.

## Deferred workspace work

Work deferred from the workspace-tiles feature set ([`workspace_tiles_design.md`](../workspace_tiles_design.md),
phases 1–10, all human-accepted). On 2026-10-06 the owner chose to close that feature
set and push the following to a later milestone. Each item still needs a concrete
assignment (scope, owner decisions, acceptance) before implementation.

| File | What |
| --- | --- |
| [external_views.md](external_views.md) | Externally computed views: producers supplying data or cell frames to tiles, transport, freshness, protocol |
| [major_minor_tiles.md](major_minor_tiles.md) | Generalizing the tile system: a minor-view registry instead of per-tile wiring, the shell's library boundary, specialized major tiles, open 7B comfort questions |

## Other open decisions (from the design doc's "Remaining decisions")

- Whether status follows the focused pane or also retains a pinned document summary.
- Which workspace/session/layout settings should persist across launches.
