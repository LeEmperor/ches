# LSP hover, symbol navigation, and jump history

## Interaction

- `K`: request symbol hover, display readable plain text/Markdown in a scrollable
  floating view. Escape/q closes and returns to the originating document.
- `gd`: declaration first, falling back to definition when unavailable or absent.
- `gD`: definition first, falling back to declaration when unavailable or absent.
- Ctrl-o: jump backward. Ctrl-i: forward, with Tab as an alias only in the Normal
  document because terminals commonly encode Ctrl-i as Tab.
- A single destination jumps immediately; multiple destinations open a searchable
  picker. Failed/stale queries never move the document.

The inspected ocamllsp maps declaration to Merlin MLI lookup and definition to ML
lookup; implementation is unsupported. Slang provides hover/definition only, so
both navigation bindings normally use definition. No language-specific filename
guessing and no active-instance extension are introduced in this phase.

## Architecture

1. Shared plain-data `error/Language_query` request/reply/content/target types and
   exact position conversion. Source handles capabilities, per-session encoding,
   document flush, cancellation, request limits/timeouts, protocol normalization
   and fallback. Responses carry document lifetime/revision/request/cursor identity.
2. Screen owns pending request identity, popup/picker lifetime, safe open-and-reveal
   into retained dirty buffers, and bounded back/forward history. Cursor/focus/mode
   changes invalidate pending requests. Targets are decoded file paths and positions
   in the negotiated encoding, converted against destination text before activation.
3. Pure hover/destination views handle clipping, scroll, Markdown readability, and
   multiple-result search. Host routing retains existing terminal/picker bindings.

Location and LocationLink variants are supported, including zero-width ranges.
Link navigation uses targetSelectionRange. Non-file URIs and invalid positions
report errors, without creating missing target files. History records successful
jump origins and destinations; traversal does not create new entries, and a new
jump truncates the forward branch. Entries retain cursor offsets with a documented
policy for subsequent edits. The history does not keep entire document snapshots.

## Validation

Fake servers: capabilities, synchronization, hover formats, target variants,
fallback, UTF-8/16/32, cancel/restart/stale replies, failure/timeouts. Headless UI:
keys/popup/picker, unsaved targets, zero-width Unicode locations, buffer lifecycle,
history branch/back/forward and Tab scoping. Full build/test suite after review.
Inspect actual installed-server behavior if a lightweight probe is feasible;
source-checkout findings alone do not prove installed capabilities.

## Execution policies

Three implementation agents, six build jobs each, maximum20 aggregate. No staging,
commits, pushes, or personal config edits. Implementation owners are transport,
screen orchestration/bindings, and pure views/history respectively.

## Status

Slang active-instance controls and standard references were subsequently added in
[the instance/reference phase](instances_and_references.md).

Implemented and validated. Shared request/response and coordinate types live in
`error/language_query.mli`. Transport details are in `source/NAVIGATION.md`; pure
view/history contracts are in `screen/HOVER_NAVIGATION.md`.

Source performs static-capability-aware fallback, exact sync/position conversion,
token/session/lifetime validation, cancellation, and bounded work (one query per
document, 32 per connection, ten-second deadline). It supports MarkupContent and
MarkedString hover variants, Location and LocationLink targets, and single-pass
file URI decoding without canonicalizing symlinks. Genuine terminal fallback
errors retain their message rather than becoming empty success.

Screen validates origin cursor/focus/mode/document context and targets before
activation. Navigation reuses retained dirty buffers, uses exact byte positions,
and preserves Normal-mode endpoint normalization. The multiple-result picker
checks retained destination revisions and fingerprints unopened files to reject
external changes. Server-stop events invalidate pending UI queries even if a late
reply arrives in the same batch. Bounded jump history stores no text snapshots;
offsets are not relocated after edits and invalid offsets fail without advancing.

Review fixed masked final fallback errors, valid file URI forms, a capability-test
fixture querying an out-of-range cursor, server-stop response races, stale external
destinations, combining-character cursor drift, and invisible boundary truncation.

Final checks passed: `dune build -j 12 @all`, `dune runtest -j 12`, and
`git diff --check`, with targeted transport and screen/app/core review suites.

## Installed-server smoke probes

Standard JSON-RPC requests against PATH executables in scratch documents confirmed:

- `ocamllsp`: executable version string `NO_VERSION_UTIL`; installed package
  metadata `1.19.0+ox2`. Negotiated UTF-8, advertised hover/declaration/definition,
  returned Markdown `int` and zero-width declaration/definition locations.
- `slang-server`: `0.3.1+a7a2d08`. Negotiated UTF-8, advertised hover/definition but
  not declaration, returned Markdown for `logic flag` and a definition LocationLink.
  A deliberately unadvertised declaration probe received no response in eight
  seconds, confirming why the client must skip unsupported methods.

Both answered shutdown. These probes verify installed protocol behavior on small
fixtures, not an interactive acceptance run in the user's projects. No server
builds/downloads, user-file changes, or Git mutations were performed.
