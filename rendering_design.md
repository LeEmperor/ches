# Ches layout and visual design

## Purpose and scope

This is the rendering companion to [the architecture brief](ches_editor_prototype_brief.md)
and [the MVP0 phase plan](mvp0_plan.md). The phase plan determines implementation
order; this document records visual intent, concrete layout behavior, and future
directions. The MVP0 requirements below belong to phase 6, not a restart of
phases 1–4. No commits, pushes, or Git initialization by implementation agents.

## Visual intent

The owner likes btop's rich colors, fine borders, and well-arranged tiles.
Ches should feel similarly deliberate while keeping document text prominent.
Comfortable placement matters: the owner sometimes has difficulty turning their
neck and wants to position text comfortably on both a laptop and large monitors.

MVP0 uses one document tile:

- A cohesive dark palette with rich, selective accents.
- Thin, single-cell borders; filename in the top border when space permits.
- Muted line-number gutter and a subtle current-line background.
- Clear mode badge, dirty indicator, position, and predictable feedback area.
- Block cursor in Normal and bar cursor in Insert where supported.
- No special icon font requirement. Labels remain understandable without color.

Use semantic theme roles (background, foreground, surface, muted, border,
current-line, Normal accent, Insert accent, warning, error). Keep colors in one
UI-side definition rather than scattering RGB literals through components.
One theme is sufficient; a theme engine and user theme files are deferred.

## MVP0 centered layout

Center the editing **rectangle**, not each line or its non-whitespace content.
Indentation is preserved. Placement must not change merely because the cursor
moves to a longer or shorter line.

Maintain session-local UI preferences:

| Preference | Initial default | Meaning |
| --- | --- | --- |
| Layout mode | Centered | Centered document tile or full-width tile |
| Preferred text width | 100 cells | Text viewport width, excluding gutter/borders |
| Horizontal offset | 0 cells | Negative shifts left; positive shifts right |

These defaults are initial implementation choices and may be tuned in the visual
review. User preference is adjustable placement, not a particular magic width.
Use terminal display cells, not document bytes, for every layout measurement.

For centered mode:

1. Reserve any application-level rows needed by the design.
2. Compute gutter/border overhead and cap the text viewport to available width.
3. Compute tile width as text width plus the actual overhead.
4. Place its left edge at `floor((available_width - tile_width) / 2) + offset`.
5. Clamp placement to keep the tile within the available rectangle.

Full-width mode uses the available width and ignores the offset for placement,
but retains the centered preferences for the next toggle.

Store requested preferences separately from effective geometry. On a narrow
terminal, margins/offset may not be realizable; retain the requested values so
the layout returns when the terminal becomes wider. A nudge updates the requested
offset even if clamping makes its immediate effect invisible; feedback should
make this clear. Never accumulate unbounded dimensions or allocate based on a
requested width before clamping it to the terminal.

Vertical centering is not required: editing starts at the top of the tile.

### Normal-mode layout commands

Use `Space v` as the view/layout prefix. Proposed MVP0 defaults:

| Keys | Action |
| --- | --- |
| `Space v c` | Toggle centered/full-width layout |
| `Space v h` | Shift requested placement left by 2 display cells |
| `Space v l` | Shift requested placement right by 2 display cells |
| `Space v H` | Shift left by 10 cells |
| `Space v L` | Shift right by 10 cells |
| `Space v -` | Reduce preferred text width by 10 cells, minimum 20 |
| `Space v +` | Increase preferred text width by 10 cells |
| `Space v r` | Restore centered layout, width 100, offset 0 |

Nudge/width commands select centered mode, so their purpose is visible even when
invoked from full-width mode. Escape cancels a pending prefix. Unknown
continuations cancel with the existing notice behavior. Show `Space v` while
pending and brief width/offset feedback after an adjustment. Insert-mode text,
including Space and these letters, keeps its existing meaning.

These commands change UI preferences only: no edits, cursor movement, revision
increments, dirty changes, or undo entries. Configuration persistence and CLI
layout flags are optional later work, not additional MVP0 requirements.

## Geometry, scrolling, and responsiveness

Have one geometry calculation produce the tile, content, gutter, and status
rectangles. Rendering, clipping, cursor placement, and scrolling must use these
same effective rectangles. In particular, cursor screen coordinates include
tile position, border, and gutter offsets.

Keep document placement separate from scroll position. A long line scrolls
inside the text viewport; it does not move the tile. Soft wrapping is deferred.
After layout adjustment or resize, recompute scroll bounds and keep the cursor
visible without changing its document position.

On narrow/short terminals, reduce margins automatically and omit decorative
borders/gutter or optional status fields as needed. Prioritize a usable text cell
and essential mode/error feedback; tolerate even zero available content cells
without exceptions or off-screen cursor requests. Do not require minimum terminal
dimensions to launch.

Use dimensions, not machine identity, for adaptation. An ample terminal offers
breathing room; a laptop terminal uses its space efficiently. Wider terminals
must not automatically summon additional panels.

## Integration with existing implementation

The existing `input/keymap.mli` (at the time of this addition) returns
`Ches_core.Command.t list`. Extend this boundary narrowly in phase 6 to support
tagged outputs such as `Editor_command of Command.t | View_command of ...`.
The application routes editor commands to core dispatch and view commands to UI
layout state. The view-command vocabulary can be terminal-independent and live
beside the keymap; it must not introduce a Bonsai dependency into core/input.

Preserve the existing single key-sequence interpreter, cancellation behavior,
paste handling, configurable Tab behavior, and configurable `jk` Insert escape.
Update affected callers/tests for the output type; do not implement a second
leader parser in the UI or put layout actions into core editor commands.

Completed text storage, cursor semantics, transactions, and file effects do not
need redesign. Existing code takes precedence for naming/style; illustrative
types here describe the intended boundary rather than demand exact names.

## Reference examples and verification

Local references in `~/devel/jane/bonsai_term_examples/`:

- `text_editor/src/bonsai_term_text_editor_example.ml`: palette, mode badges,
  status composition, backdrop, and mode-dependent terminal cursor.
- `with_colors/src/bonsai_term_with_colors_example.ml`: RGB attributes.
- `typography/src/bonsai_term_typography_example.ml`: borders/padding/composition.
- `pomodoro_timer/test/test_pomodoro_timer.ml`: UI handles, dimensions, key events,
  and textual expect snapshots.

Treat these as read-only references. Read applicable workspace instructions and
verify APIs against installed packages: checkout and installed versions can
differ. Borrow presentation patterns without replacing `ches_core` with the
example's editor component.

Before integrating the whole editor, do a bounded visual pass with representative
Normal, Insert, dirty, pending-prefix, and error states. Review at approximately
80×24 and 160×48 cells, plus pathological tiny dimensions for robustness.

Test layout geometry, clamp/restore behavior on resize, nudge/reset/toggle,
width changes, cursor translation, and scrolling with tabs/wide characters.
Verify view commands leave core state/history untouched. Textual expect tests
check layout and content; actual terminal inspection is needed for palette,
contrast, borders, cursor behavior, and flicker. Record any unavailable manual
checks rather than declaring visual quality verified from text snapshots.

## Later direction — not phase 6 requirements

- Supporting tiles for actual search/help/diagnostic content, using the same
  border/palette language; no empty decorative dashboards.
- User-controlled visibility and placement of supporting panels. Opening panels
  should respect preferred document placement rather than blindly recenter it.
- Persistent layout/theme preferences and optional named profiles.
- Light themes, richer theme selection, wrapping, and additional focus modes.
- Multiple document panes when workspace support exists.

These directions must not expand the MVP0 visual pass into a panel framework.
