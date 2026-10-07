# Floating tiles: command palette first

Status: phase 1 implemented; phases 2–4 pending. Scoped on 2026-10-06.

## Goal and starting point

Make the command palette a centered floating window above the existing workspace.
Opening it must preserve the document viewport and the allocation of status,
problems, history, and report tiles. Reuse the shared tile host, shell, and palette
adapter for input, decoration, and command execution.

The current checkout is `oxcaml`. At planning time the docked palette implementation
was on `bpurtell/fzf-commands` (inspected at `9233b02`). Phase 1 started from
`a70b35e`, which already includes the palette and latest tile work. The working tree
was clean; no branch reconciliation was needed.

Existing foundations:

- `tile/host.ml`: focus, capture, pending input, paste ownership, and cursor ownership.
- `screen/tile_shell.ml`: rectangle-based borders, padding, title/footer, and content.
- Palette branch: `screen/palette_tile.ml`, text-input host capabilities, cursor
  intent, and execution through `Controller.dispatch`.
- `screen/workspace.ml`: non-overlapping tiled allocation, which remains the base layer.
- `screen/frame.ml`: complete styled screen rows; currently assumes non-overlapping panes.

## Scope and initial behavior

- Support one transient, opaque floating tile at a time, identified by `View_id`.
  Floating is placement; keep the existing major/minor roles and capabilities.
- Center within the terminal. Start with a preferred outer size of 80 columns by
  14 rows, clamped to available space with a one-cell margin where possible.
  Keep the size stable while filtering; result rows scroll inside it.
- Use the existing shell. Require space for its frame, a query row, and at least
  one result row. If that cannot fit, refuse opening with shared feedback; if an
  open float loses that space on resize, close safely and return focus.
- Allow the palette in zen when it fits. Keep the current Normal-mode requirement,
  query keys, paste sanitization, acceptance, and Escape/Tab/Ctrl-c behavior.
- Preserve the current document target and focus-return policy. Closing discards
  the query; accepting closes before dispatching once through the controller.
- No dragging, mouse interaction, shadows, backdrop dimming, multiple floats,
  arbitrary anchors, persistent floating panels, or generic view-registry refactor.

## 1. Add shared floating geometry

Add a small pure module in `screen` for floating placement, independent of palette
content. Given terminal bounds and preferred/minimum sizes, return an optional
outer rectangle. Feed that rectangle through `Tile_shell.layout`; one layout must
drive rendering, the content viewport, and cursor coordinates.

Keep the tiled workspace allocation unchanged. Add a view-layout/availability
query in `Ui_state` that can resolve either a tiled view or the floating view;
reuse `Host` for effective focus and reconciliation. Keep existing tiled callers
working without introducing a registry.

Verify centering, clamping, nonzero origins, tiny/zero dimensions, and deterministic
resize behavior with pure geometry tests.

### Phase 1 implementation and handoff (2026-10-06)

- `screen/floating.ml` adds pure `place` and `layout` operations with explicit
  terminal bounds, preferred outer size, and minimum outer size. Placement preserves
  nonzero origins and centers with an odd spare cell on the right/bottom. A one-cell
  margin is retained independently on each axis when the minimum still fits; the
  margin gives way before the minimum. Negative bounds are empty; minimum sizes are
  normalized to at least one cell, and preferences cannot undercut them.
- `Floating.layout` passes the resulting outer rectangle through `Tile_shell.layout`
  once, producing the shared frame/content/cursor coordinate source. The consumer
  supplies its policy and sufficient outer minima. Tests use the intended 80×14
  preference and a 14×4 minimum with at least 12×2 framed content (padding can give
  way), enough for a query and one result.
- `Ui_state.view_layout` resolves tiled supporting shells or an explicit transient
  `(View_id, layout option)` supplied as `~floating`. An unavailable floating view
  does not fall back to a tiled duplicate. `view_available` gives the same resolution
  to the existing host; the document stays available and retains its own geometry.
  Existing host focus/cursor/reconciliation paths use this shared availability query,
  and existing `minor_layout` callers keep their tiled contract. No registry or
  floating content state was introduced.
- The explicit floating argument is the staging boundary for phases 2–3: compute
  its layout once and share it with rendering, viewport/cursor queries, and host
  availability. The live palette still uses the docked layout until the compositor
  and migration are implemented. Workspace allocation and palette behavior are
  unchanged in this phase.
- Five new headless tests cover expected placements, degenerate dimensions,
  exhaustive containment/centering/margin checks over terminal sizes, deterministic
  resize restoration, shared shell geometry with synthetic content, floating host
  focus/resize reconciliation, and unchanged tiled/document geometry and scroll.
- Automated verification using the `5.2.0+ox` switch: `dune build` and
  `dune runtest screen/test` pass. Full `dune runtest` fails in
  `source/test/test_lsp_client.ml` (project-root expectations) and
  `ui/test/test_editor_view.ml` (snapshots predating default-visible tiles). Both
  failures were reproduced with those suites in an isolated archive of unchanged
  `a70b35e`; no expectations were promoted.
- Terminal smoke verification: the full `scripts/smoke.sh` run passed, including
  the existing docked-palette input/cancel/paste/accept scenario. It ran outside the
  sandbox (private tmux sockets are blocked inside) against a stable executable
  copy at `/tmp/ches-floating-phase1.exe`. Log:
  `/tmp/ches-floating-phase1-smoke-final.log`; terminal captures:
  `/tmp/ches-smoke-screens.JvBI7S`. Human visual acceptance has not been performed;
  a visible floating palette is not part of phase 1.

## 2. Compose the floating layer

Render the existing workspace first, then replace the cells covered by the
floating shell. Add a reusable row-overlay operation rather than passing overlaps
to the current horizontal pane concatenation.

Preserve exactly the terminal width in every row and valid UTF-8 spans. At overlay
edges, replace any exposed fragment of a cut wide glyph with blank cells; keep
combining marks attached to their surviving base glyph. Clip out-of-bounds layers.
Keep the complete-frame contract so the terminal frontend remains a thin drawer.

Only the focused view supplies a cursor. Suppress document smear while the palette
captures input; place its bar cursor using the floating content origin.

Verify overlay coverage, unchanged cells outside it, styled rows, wide/combining
text at both edges, clipping, and cursor/smear ownership. Use synthetic shell
content to prove the compositor does not depend on the palette.

## 3. Move the palette onto the floating surface

Remove the palette from the requested bottom-band minors. Resolve its availability,
viewport fitting, paste delivery, rendering, and cursor through the floating layout.
Remove the zen/bottom-band opening restrictions in favor of the float's minimum
content requirement. Retain palette state and shared execution behavior.

On resize, preserve query and selected command when the float still fits; otherwise
close without execution. A paste whose palette closes before completion must still
be dropped, never delivered to the document.

Verify open/search/accept/cancel, no-match Enter, zen, coexistence with all docked
views, resize, and interrupted paste. Assert opening/closing leaves tiled
rectangles, document text, and document scroll unchanged; accepted commands may
of course change their own intended state.

## 4. Validate and document

Run focused geometry/composition/palette tests, then `dune build`, `dune runtest`,
and the relevant terminal smoke scenario using the README's OxCaml switch. Extend
the palette smoke scenario for floating placement, cancel, paste, and resize.
Update palette documentation to describe floating and tiny-terminal behavior.

Human terminal review checks centering, size, readability, and restoration of the
covered workspace after close. Record automated verification separately from
human visual acceptance.

## Done when

`Space c c` opens a framed floating palette without reallocating the workspace;
typing stays in its query, one cursor belongs to it, and Enter follows existing
command execution. Cancellation restores the underlying screen without document
input leaking through. Resize and Unicode overlap tests preserve frame invariants.
Shared placement/composition code contains no command matching or dispatch logic.
