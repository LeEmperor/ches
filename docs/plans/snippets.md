# Snippet completion

## Interaction and scope

Tab/Shift-Tab continues cycling completion candidates, inserting expanded plain
text without activating fields. Enter accepts the selected candidate and activates
its snippet fields. Tab/Shift-Tab then visits numbered fields; typing replaces the
initial selected default and updates linked occurrences. `$0` is the final cursor
position. Escape ends the snippet session, retains text, and follows normal mode
handling. Ordinary typing to accept a cycling candidate does not activate snippets.

Initial syntax: numbered tabstops, default placeholders, linked occurrences,
escaped literals, and final cursor placement. Unsupported transformations or
variables must be rejected deliberately rather than inserting raw snippet syntax.

## Architecture

- `completion/Snippet`: pure bounded parser, expanded text/ranges, and pure session
  operations for field replacement and navigation. All offsets are UTF-8 bytes.
- Completion candidates carry optional parsed snippet data. Primary text is always
  expanded plain text, so cycling and undo retain their current atomic edit path.
- LSP normalization parses snippet-formatted items and advertises support only for
  the implemented functionality. Malformed/unsupported items are skipped.
- The screen owns snippet lifecycle and highlights, isolates document lifetime,
  and applies linked changes atomically through the Controller edit boundary.
- Explicit acceptance relocates ranges after additional edits; late resolve must
  never invalidate active fields. Undo/movement/buffer changes/paste must either
  update the session safely or cancel it before normal processing.

## Validation

Pure parser/session tests, realistic fake-server snippet replies, headless
completion-to-placeholder key sequences, linked Unicode edits, additional edits,
undo/redo and lifecycle regressions. Full build and suite after integration.

## Execution

Three implementation workers maximum, six build jobs each, total at most 20.
No staging, commits, or pushes. Snippet transforms, user-defined template catalogs,
and asynchronous initial word indexing remain follow-up work.

## Status

Implemented and validated. Parser/session APIs live in
[`completion/snippet.mli`](../../completion/snippet.mli), with integration notes in
[`completion/SNIPPETS.md`](../../completion/SNIPPETS.md) and
[`screen/SNIPPETS.md`](../../screen/SNIPPETS.md).

Supported syntax includes numbered tabstops, defaults, forward-reference mirrors,
final cursor, and escaped literals. Nested defaults, variables, choices,
transformations, conflicting defaults, and repeated/defaulted `$0` are rejected.
Bounds are 64 KiB input, 1 MiB expansion, and 4096 occurrences. LSP snippet support
is advertised; unsupported items are skipped rather than inserted as raw syntax.

Tab cycling uses expanded plain text. Enter applies known additional edits and
activates fields only after successful acceptance. Pending snippet resolve is
cancelled before activation: late extras cannot shift live placeholder ranges.
The active field and mirrors use the selection style. Edits update linked Unicode
occurrences atomically and join the Insert undo group. Paste, newline, unsupported
movement/commands, lifecycle changes and unsafe deletion end the session before
normal input handling; Ctrl-n ends it and requests completion.

Review fixed activation after failed additional-edit finalization and restored
normal soft-tab-stop Backspace behavior within fields. Regression tests cover both,
including undo/redo and empty resolved extras. Other coverage includes malformed
syntax/bounds, coincident fields, mirror relocation, imports before the expansion,
stale resolve, rendered highlights, delayed `jk`, and terminal/paste routing.

Validation passed: full build and suite with `-j 12`, followed by completion,
screen, and source-completion regression suites after review fixes (six jobs in
an isolated build directory). Final default-directory `dune build -j 12 @all`,
`dune runtest -j 12 completion screen source/test/completion`, and
`git diff --check` passed. Interactive snippet behavior has not yet been manually
evaluated.
