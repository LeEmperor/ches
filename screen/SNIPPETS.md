# Screen snippet lifecycle

Completion cycling inserts only the candidate's expanded plain text. Explicit
Enter acceptance starts `Ches_completion.Snippet.Session` after finalizing known
additional edits. The final completion cursor relocates the expansion base, so
imports before the primary edit also relocate every placeholder.

## Resolve limitation

Snippet acceptance does not wait for resolve. Only additional edits already known
at Enter are applied; the completion token is then cancelled and its metadata is
discarded before activating fields. Late resolve replies cannot apply imports
after activation, even when the document has not yet changed. Providers that
require imports should return them with the original completion item or resolve
them before acceptance. Plain completions retain their existing guarded deferred
resolve behavior.

## Editing and cancellation

The active field and its mirrors use the existing document selection overlay.
Ranges and carets are UTF-8 byte offsets; glyph layout handles display widths.
The first typed character replaces the selected default. Subsequent insertion and
character deletion are mirrored in one Controller insert-edit batch and remain
in the current insert undo group. Tab and Shift-Tab select numbered fields; Tab
after the last field places the cursor at `$0` and ends the session.

Keys pass through the insert keymap, preserving its `jk` escape behavior. The
terminal-toggle recognizer still buffers and replays literal prefix keys through
the same path. Field navigation clears pending keymap escape state.

Escape keeps the current text and exits Insert normally. Paste, newline, commands
other than supported field edits, unsafe deletion across a field boundary,
document/buffer replacement, focus changes and external cursor/text changes cancel
the snippet before ordinary handling. Ctrl-n deliberately cancels the snippet and
requests a fresh completion. Automatic completion is suppressed while fields are
active. Cancelled sessions never reactivate through undo, redo or buffer return.
