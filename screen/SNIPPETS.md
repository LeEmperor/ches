# Screen snippet lifecycle

Completion cycling inserts only the candidate's expanded plain text. Explicit
Enter acceptance starts `Ches_completion.Snippet.Session` after finalizing known
additional edits. The final completion cursor relocates the expansion base, so
imports before the primary edit also relocate every placeholder.

## Development demo command

In a file's Normal mode, press **Space c c**, type **Insert demo snippet**, and
press **Enter** (searching `development.insert-demo-snippet` also works). This
development utility is available in the regular build; it needs no language server
and works with automatic completion disabled. The catalog has no category field;
its description and search keywords identify it as Development.

The command enters Insert at the current Normal-mode cursor, like `i` (before the
current character, without replacing an identifier), and accepts this template
through the same completion planner, insertion and snippet acceptance path:

```text
assign ${1:signal} = ${2:value};
// mirror: $1
$0
```

The `signal` field is immediately active. Typing replaces it and its mirror;
Tab selects `value`, and the next Tab ends the session at the start of the final
line. Shift-Tab returns to the previous field. Escape leaves Insert; one undo
then removes the expansion and its field edits, and redo restores the text without
reactivating fields. No indentation or language-specific adaptation is added.

The action is listed only over the current file, not directory buffers or other
read-only/non-file views. Insert/Visual mode, block insertion and active paste are
not supported. Ordinary snippet cancellation rules below still apply.

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

Choice fields show a compact, nonfocus hint beside the caret with alternatives and
`Ctrl-e/y`: Ctrl-e cycles forward, Ctrl-y backward. Typing replaces the selected
choice with custom text; cycling and edits update all mirrors in the insert undo
group. Rendering takes at most eight alternatives, each byte-bounded before span
decoding. The hint is clipped by display cells with one trailing padding cell and
is hidden whenever a completion menu is present. Cycling still visits every option.

Left/Right and Home/End use ordinary Insert cursor commands (Home/End target the
actual current line). Movement clears the selected default without changing text
or closing the snippet's insert undo group. The snippet survives only when the
destination is inside or at an endpoint of any active occurrence in the same text/revision;
otherwise the ordinary move completes and the snippet is cancelled. Ordinary
Insert movement outside snippets retains its normal undo boundaries.

Keys pass through the insert keymap, preserving its `jk` escape behavior. The
terminal-toggle recognizer still buffers and replays literal prefix keys through
the same path. Field navigation clears pending keymap escape state.

Escape keeps the current text and exits Insert normally. Paste, newline, commands
other than supported field edits, unsafe deletion across a field boundary,
document/buffer replacement, focus changes and external cursor/text changes cancel
the snippet before ordinary handling. Ctrl-n deliberately cancels the snippet and
requests a fresh completion. Automatic completion is suppressed while fields are
active. Cancelled sessions never reactivate through undo, redo or buffer return.
