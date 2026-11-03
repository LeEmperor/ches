# Signature help and companion frontend integration

## Contract and ownership

The frontend uses `Ches_error.Language_query.Signature_help { automatic;
character; retrigger }`, `Signature_result`, `Companion_files`, and `Companions`
as published in `source/SIGNATURES.md`. No language or extension inference occurs
in screen/input/palette/UI. Source decides capability and automatic trigger rules.

`Ui_state.signature` is independent of Normal navigation and completion. Requests
capture document identity, retained-buffer owner, source generation, revision,
cursor, mode, and an exact token. Signature request serials occupy the negative
domain so navigation tokens cannot collide. A response must match all of these
and document focus. Automatic failures and empty help clear silently; manual
failures use the navigation notice channel. Requests use the existing asynchronous
source command queue. Signature/navigation share the source query lane;
completion remains independent.

Actual Insert edits submit automatic intents when enabled. Delayed terminal-toggle
prefixes submit only as their literal keys are flushed. The editor's existing `jk`
escape inserts `j` immediately and rolls it back on `k`: the insertion can request
help, and exit cancels it. Character metadata is the final inserted UTF-8 scalar;
non-character edits send None. Active retrigger intent survives outstanding
updates, without rendering stale signatures. Paste, snippet sessions, block
Insert, terminal and captured popup/picker input suppress signature requests.

Mode/focus/owner/document/generation/cursor/revision changes, paste, Escape,
source restart/stop and module-context changes invalidate pending and displayed
help. Configuration reload invalidates help; successful configuration application
atomically consumes `Settings.signature_help_enabled` with the other fields.
Invalid settings never partially apply. The initial automatic default is true.

## Interaction and rendering

- Ctrl-k in Normal/Insert and palette **Signature help** invoke manual help.
- **Toggle automatic signature help** changes the session setting. Manual help
  works with the automatic setting off.
- While help is visible in Insert, Ctrl-g selects the next overload and Ctrl-b
  the previous, wrapping. Normal Ctrl-b is not intercepted. Tab and Ctrl-e/y
  retain their existing completion/snippet behavior.
- Both automatic and manual help are opaque, non-focusing document overlays.
  The document retains its terminal cursor and editing mode.
- Signature help prefers above the cursor. Completion is placed below while
  signatures are present. At the top edge completion has priority; without
  completion, help falls below. Rendering is clipped to the document viewport.
- `Signature_overlay` uses normalized UTF-8 byte parameter ranges and checks both
  boundaries before splitting. Source converts wire UTF-16 tuple offsets. Active
  argument styling is `Pending`; the selected signature's active parameter
  overrides the payload's parameter. Invalid/unknown ranges remain unhighlighted.
  Documentation snippets, overload count and control hints are bounded and use
  display-cell-safe Span escaping/clipping.

## Companion navigation

Palette **Switch interface/implementation** sends `Companion_files`. Screen validates
the selected path when opening, reuses retained counterparts (including unsaved buffers), and
opens other existing files with `must_exist:true`. It preserves each target's
retained cursor. A single target opens directly; multiple targets use the existing
destination picker titled **Choose counterpart**. Acceptance again requires the
unchanged origin. Every successful switch records origin/destination in jump
history. Missing/empty/failed responses never create files or move the cursor.

## Validation

`screen/test/test_signatures.ml` covers manual/palette/toggle behavior, automatic
intents and delayed literal flushes, Unicode byte highlights, invalid boundaries,
documentation/overload controls, stale cursor/revision/mode/focus/token replies,
stop/context-change cancellation, silent automatic failure, atomic settings,
simultaneous completion, retained dirty counterpart cursors, multiple/missing
counterparts and jump-history traversal. Existing catalog snapshots are updated.
`ui/picker_test/test_signature_frontend.ml` drives the real frontend with a fake
asynchronous source: request counts follow edits, stale replies do not display,
current replies render, and typing/retrigger requests continue with work pending.

Run with six jobs maximum:

```
dune build -j6 @check
dune runtest -j6 screen/test input palette ui/picker_test bin
```

Validation completed: `dune build -j6 @check`, the owned-directory tests above,
and full `dune runtest -j6` passed. Source tests emit their existing
`unsafe_multidomain` environment-mutation alerts; there were no test failures.
