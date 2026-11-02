# Completion transport integration

Shared variants (available in `error/`):

- `Source_request.Complete of Ches_completion.Model.Request.t`
- `Source_request.Cancel_completion of Ches_completion.Model.Token.t`
- `Source_event.Completion of Ches_completion.Model.Reply.t`

Send `Document_opened` with the buffer generation and `Document_changed` with the
current revision/text before `Complete`. The token must match that resource,
generation and revision. Requests use the existing pooled server. Replies are
direct `Completion` events, with the resource and ownership in `reply.token` and
the pool identity in `reply.source`; they need no `Owned` wrapper. Consumers must
route these immediately, outside Insert-mode diagnostic deferral, and pass them to
the matching completion model. `Source_event.to_update` returns `Noop` for them.
The source event queue preserves each completion rather than diagnostic-coalescing
it. The generic single-document workspace adapter can still wrap events in `Owned`.

The host flushes pending didChange before completion and rejects stale lifetime,
session, revision and request identity. Changes, closes and restart cancel pending
requests. Cancellation is token-exact. Limits: one pending request per document,
32 per connection, 10-second expiry, first 512 response items, 128 additional edits
per candidate. Eviction cancels a pending request when the connection is full.

UTF-8/16/32 conversion requires exact code-point/line boundaries. Primary and
additional edits are normalized and validated against the captured snapshot.
Completion arrays, null results and completion lists are supported; lists preserve
`isIncomplete`. `Character` uses a server-advertised trigger character; otherwise
it becomes an ordinary invocation. `Incomplete` sends the corresponding protocol
trigger. Automatic typing requests can always requery.

Deliberate limitations: no snippets, commands, resolve, insert/replace edits,
dynamic capability registration, or list item defaults. Unsupported items are
skipped. Servers with an unknown position encoding are not queried. Requests
before initialization are ignored, as are requests whose current snapshot cannot
be synchronized with the server's declared change support. Failures/timeouts do
not emit a completion reply; buffer-word candidates remain available.

Independent protocol verification: `dune runtest -j 6 source/test/completion`.
It covers Unicode conversion, flush ordering, plain/fallback/additional edits,
unsupported items, late replies after cancellation/revision/supersession/reopen,
capability checks, pooled request bounds, restart, and event queue isolation.
