# Backlog

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
