# Ches layout and visual design

## Purpose and scope

This is the rendering companion to [the architecture brief](../ches_editor_prototype_brief.md)
and the MVP0 phase plan (removed; see git history). The phase plan determines implementation
order; this document records visual intent, concrete layout behavior, and future
directions. The MVP0 requirements below belong to phase 6, not a restart of
phases 1–4. No commits, pushes, or other Git state changes by implementation agents.

## Visual intent

The owner likes btop's rich colors, fine borders, and well-arranged tiles.
Ches should feel similarly deliberate while keeping document text prominent.
Comfortable placement matters: the owner sometimes has difficulty turning their
neck and wants to position text comfortably on both a laptop and large monitors.

MVP0 uses one document tile:

- A cohesive dark palette with rich, selective accents.
- Thin, single-cell borders; filename in the top border when space permits.
- Muted line-number gutter and a subtle current-line background. Since MVP1
  phase 4A the gutter has four styles (off by default, absolute, relative,
  hybrid); see [`feature_expansion.md`](archive/feature_expansion.md).
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
| `Space v =` | Same as `Space v +`, without needing Shift |
| `Space v n` | Toggle absolute line numbers (MVP1 phase 4A) |
| `Space v N` | Toggle relative line numbers (MVP1 phase 4A) |
| `Space v r` | Restore centered layout, width 100, offset 0, no line numbers |

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

## Settled phase 6 decisions

These were settled in review before phase 6 started. Where they are more
specific than the rest of this document, follow them.

### UI state and event handling

Keep all UI-side state in one model updated by one `Bonsai.state_machine` (or
`state_machine_with_input`, with the terminal dimensions as input). The model
holds the `Controller.t`, layout preferences, scroll position, the
bracketed-paste collection buffer, and the status message. Do not use
`Bonsai.state` with a handler that captures the last rendered value. If two
events arrive before a redraw, the second is applied to stale state and the
first keystroke is lost. `apply_action` always receives the current model.

Write the model and its transition function without Bonsai types, so headless
tests can drive them. One input is: adapt the event, update the model, and
report whether to exit. The Bonsai component only adapts terminal events, runs
the transition, renders, sets the cursor, and schedules `exit` when the
controller reports `Exit`. Saving runs synchronously inside the transition
(through the controller). That is acceptable for MVP0.

### Keymap and controller boundary

- `ches_input` gains a terminal-independent view-command type, along the lines
  of:

  ```ocaml
  type t =
    | Toggle_centered
    | Shift of int        (* signed display cells: ±2 or ±10 *)
    | Adjust_width of int (* signed display cells: ±10 *)
    | Reset
  ```

- `Keymap.feed` returns a list of actions, `Editor of Ches_core.Command.t |
  View of View_command.t`. Their `sexp_of` prints editor commands untagged and
  view commands as `(View ...)`, so existing keymap expectations stay valid.
- `Controller.handle_input` dispatches editor actions as before and also
  returns the view actions, in order, for the UI to apply:
  `t -> Keymap.Input.t -> t * View_command.t list * Status.t` (or an
  equivalent record). Editor and view actions touch disjoint state, so their
  relative order within one input does not matter. This is a deliberate change
  to the phase 5 controller contract.
- Ctrl-C produces no command in either mode. It cancels any pending sequence,
  ends a `j k` sequence, and sets the notice `To quit, use Space q in Normal
  mode`. Raw mode turns Ctrl-C into an ordinary key, and silently ignoring it
  would leave a stuck user without a hint.

### Status line and feedback

The status line shows the mode badge, filename, dirty indicator, position
`line:column`, pending keys, and one message slot. Line and column are
one-based, and the column is the code-point column (`Editor.cursor_column + 1`),
not the display column. While a sequence is pending, its keys (e.g. `Space v`)
appear in their own field, independent of the message slot.

Phase 5 of `workspace_tiles_design.md` replaces the disposable message slot with
shared controller feedback. Editor commands clear transient notifications before
posting their new feedback. Keymap notices and layout actions post structured
transient notifications; prefixes, ignored keys, resize, and animation do not clear
feedback. Unacknowledged save/reload problems take display precedence over routine
notifications and persist until matching recovery or acknowledgement. Acknowledgement
retains an unresolved count, and `Space v e` cycles retained details. Idle Normal
Escape acknowledges the presented problem and clears search highlighting; mode exits
and pending cancellation take precedence. All status presentations query this state.

When the status line is too narrow, drop fields from lowest priority first:
routine message without active problems, filename (truncate from the left first, marked with `<`),
position, dirty indicator, pending keys, error message. The mode badge is the
last field kept.

### One cell model for drawing and cursor math

A single function maps each code point to its screen cells. Rendering,
clipping, cursor placement, and scrolling all use that same function. Never
pass document text, filenames, or error text to `View.text` unmapped.
`View.text` escapes control characters itself, writing ESC as the four
characters `\027` and TAB as `\t`, so its widths would disagree with ours.
Hand it only text that it passes through unchanged.

| Code point | Shown as | Cells |
| --- | --- | --- |
| TAB | Spaces to the next multiple of the tab stop (8) | 1–8 |
| C0 controls other than TAB/LF, and DEL | `^A` … `^_`, `^?` (ESC is `^[`) | 2 |
| C1 controls U+0080–U+009F | `<80>` … `<9f>` | 4 |
| Bidi controls U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069, and U+FEFF | `<202e>` (lowercase hex) | 6 |
| Any other code point whose `View.uchar_tty_width` is negative | `<hex>` | 4+ |
| Other, width 1 or 2 | Itself | 1 or 2 |
| Other, width 0 (combining marks etc.) | Itself, attached to the preceding cell | 0 |

Draw the `^X` and `<hex>` forms in a distinct muted/special role, so they can't
be mistaken for literal text. The buffer already rejects NUL and CR. LF ends a
line and is not drawn. Apply the same mapping to the filename and messages in
the border and status line.

Notty measures width per grapheme cluster, so for complex clusters, such as
emoji ZWJ sequences, its width can differ from the sum of the code points'
widths. Force each rendered line segment to exactly its computed width, cropping
or padding as needed, so the gutter, border, and tile never shift. The text in
such a line may look wrong, but the layout stays intact. Record this as a known
limitation until grapheme support arrives.

**Cursor cell.** The cursor sits on the first cell of the code point at its
offset. At a line's end it sits on the cell after the last code point. This
holds for a TAB, a wide character, and an escape form too. (Vim puts the Normal
cursor on the last cell of a TAB; one rule is simpler here.) A zero-width code
point puts the cursor on the first cell of the nearest preceding nonzero-width
code point, or on cell 0.

**Clipping at the text viewport's left and right edges** is exact to the cell:

- a partly visible TAB shows its visible cells as spaces;
- a partly visible escape form shows its visible ASCII characters;
- a partly visible wide character shows `<` (left edge) or `>` (right edge) in
  the muted role.

### Scrolling

Scroll state is the first visible line and the first visible display cell. It
is UI state, not core state. The cursor span is the cells of the code point
under the cursor. For an insertion point, an empty line, a line's end, or a
zero-width code point, the span is the single cursor cell.

One pure fit function computes the new scroll from the previous scroll, the
cursor line and span, the text viewport size, and the line count:

- **Vertical:** move as little as possible to make the cursor line visible.
  After a resize only (when the text rows differ from those of the last input),
  also lower the first visible line if needed, so the viewport isn't partly
  empty while earlier lines are hidden. Otherwise a view scrolled past the end
  stays put while the cursor is visible, as in Vim, so `Ctrl-e` can scroll until
  the last line is at the top (MVP1 phase 4B; MVP0 applied this rule after every
  input).
- **Horizontal:** start at cell 0 whenever the span fits there. Otherwise move
  as little as possible to make the whole span visible. If the span is wider
  than the viewport, show its first cell.
- No scroll margin (scrolloff). MVP1 phase 4B adds explicit scroll commands
  (`Ctrl-e/y/d/u`, `zz/zt/zb`); see [`feature_expansion.md`](archive/feature_expansion.md)
  and `Ui_state`.
- With zero text rows or columns, keep the scroll unchanged and show no cursor
  (`set_cursor None`).

Apply the fit after every input. Apply it again at render time with the current
dimensions, so a resize keeps the cursor visible before the next input arrives.

### Geometry limits and layout feedback

- The gutter uses `max(3, digits(line_count))` digit cells plus one separator
  cell, so the tile only shifts when a file passes 999 lines.
- Requested preferences are clamped when changed: width to 20–500 and offset to
  −500..+500.
- Feedback shows the requested value, followed by the effective value when it
  differs, e.g. `Width 110 (76 fit)` and `Offset +40 (+12 fit)`. Toggle and
  reset report `Centered`, `Full width`, or `Layout reset`.

### Cursor shape and exit

Normal mode uses a non-blinking `Block` cursor and Insert mode a non-blinking
`Bar`. When it releases the terminal, the installed Notty (`notty-community
0.2.4+ox2`) shows the cursor and emits `ESC [ 0 q`. That resets the shape to the
terminal's configured default, so ordinary exit needs no extra code. Acceptance
still checks the shell's cursor after quitting a session that used Insert mode
and after an error exit.

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

Do a bounded visual pass in checkpoint 6B, after 6A has the real editor
working, with representative Normal, Insert, dirty, pending-prefix, and error
states. Review at approximately 80×24 and 160×48 cells, plus pathological tiny
dimensions for robustness. The phase 6 smoke script (`scripts/smoke.sh`; see
[the README](../README.md#terminal-smoke-test)) saves these screens with
colors for review.

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
