# Language query transport contract

`Ches_error.Language_query` is the shared plain-data interface (published in
`error/language_query.mli`). Send `Source_request.Query request` or
`Cancel_query token`; receive `Source_event.Query_result reply`, possibly inside
`Owned`. K uses Hover, gd Declaration, gD Definition. Replies retain the original
kind even after fallback. No implementation request is used.

Tokens identify resource, generation, revision and request; cursor is a byte
offset into the exact current snapshot. Consumers must check the exact token,
cursor, current revision and document lifetime before displaying or navigating.
Cancellation is exact-token and silent. Edits, close and restart invalidate work.
One outstanding query per document, at most 32 per connection, ten-second timeout.
Pending didChange is flushed before a query. Query events are independent of
diagnostics. Unavailable or unsupported requests yield `Failed` rather than hang.

Targets carry decoded absolute file paths, preserving lexical symlink aliases,
and negotiated position encoding. `range` is the full LocationLink target range;
`selection` is targetSelectionRange (for Location both are the same). Positions
are zero-based and ranges end-exclusive; zero-width is valid. Selection must be
contained in range. Use `Language_query.offset encoding ~text position` against
the destination buffer, and reject None before opening/revealing. This helper is
pure and has no Async dependency. Non-file URIs fail explicitly.

Hover contents preserve Plaintext/Markdown and multiline text. MarkedString code
objects become fenced Markdown. Empty/null hover is `Hover_result None`.
Declaration and Definition try the other method when the preferred capability
is absent or the result is null/empty, MethodNotFound, or RequestFailed (-32803).
Other protocol/transport failures are reported. Static bool and object provider
capabilities are recognized. UTF-8 is preferred, with UTF-16/32 supported.

Normalization rejects reversed/negative ranges and out-of-range selections;
destination text validation belongs to the screen. Limits are 256 targets,
16 KiB per URI, 128 hover content entries and 256 KiB total hover text. Oversized
or malformed responses fail explicitly rather than silently dropping targets.
An unsupported primary method is skipped; fallback replies keep the initiating
request kind. Exhausted empty navigation results yield `Locations []`; a protocol
error with no remaining supported fallback yields `Failed`, preserving its message.
Server exit fails outstanding queries; explicit restart cancels them silently.

Transport regression tests live in `source/test/completion/test_navigation.ml`
and use `source/test/fake_lsp/fake_lsp.ml` with OCaml/Slang capability profiles.
Run `dune runtest -j 6 source/test/completion`.
