# Completion transport integration

## Completion and lazy resolve transport

Transport messages:
- `Source_request.Resolve_completion { token; candidate_id; revision }`: lazily
  resolve the selected item, guarded by the **current editor revision** (which
  may be newer than token.revision after Tab installs a primary).
- `Source_event.Completion_metadata { token; source; items }`, where items are
  `Completion_info.t` records: `candidate_id`, `kind : int option`,
  `documentation : string option`, `detail : string option`, `resolvable : bool`,
  `additional : Text_edit.t list option`. Initial metadata has additional=None;
  a resolved result has Some edits, including Some [] when empty.
- Resolved metadata also includes `revision : int option` on each item: None for
  initial metadata, Some requested revision for resolve responses.

The UI routes metadata immediately (like Completion), retains it by exact token
and candidate id, and rejects resolve results unless current revision equals the
item revision, the same session/candidate is still selected, the provider matches,
and a resolve for that candidate/revision is outstanding. Edits are in the
**original completion base coordinates**, never current-buffer coordinates.
Resolved additional edits are used only at acceptance, atomically with the primary
via the model's finalize/rebase mechanism. They are never installed on Tab or
on metadata arrival while the menu is active. Session dismissal sends
Cancel_completion (which releases the raw cache); selecting another LSP candidate
should send a new Resolve_completion, superseding the previous resolve. Selecting
a buffer candidate must ignore the old response via the selection guard. A
resolve response never changes primary edits or the candidate's parsed snippet.
The source retains bounded raw items for 10 seconds, and cancels outstanding
resolve on any document change; a new request after Tab can use retained items.

## Actual UI acceptance implementation

`screen/ui_state.ml` keeps the original text/cursor alongside the completion
model. `resolved_finalize` rebuilds a one-candidate planning model from that base,
substitutes the resolved additional edit list, acknowledges the primary already
installed in the real editor, and asks the model for its normal atomic finalize
plan. The resolved list
**replaces**, rather than appends to, the original additional edits; Some [] clears
them. Finalization is permitted only after a real successful primary installation.
An untouched menu with resolved docs/extras cannot fabricate an installed primary
when ordinary typing or Escape dismisses it. Enter explicitly installs first.

A resolve accepted before Tab stays valid in the session's base coordinates and
can be reused after primary installation/cycling. An unaccepted response captured
before a revision-changing Tab is stale: Tab issues a fresh resolve for the new
revision, and the old response is rejected. Selection changes clear the resolve
marker even when the next item does not need resolution, allowing a revisit to a
same-primary/no-op candidate to query again after a deselected response was dropped.

Known additional edits finalize immediately at acceptance. If none are known and
the selected item has an outstanding resolve for the exact current revision,
acceptance hides the menu and retains a **one-second** guarded continuation;
typing never waits. A successful result within that interval may finish the
additional edits only while buffer owner, controller lifetime, Insert mode,
revision and cursor still match the accepted snapshot. Any later key (including
one held by timed shortcut recognition), terminal key, or paste start cancels the
continuation before processing that input. Lifecycle/snapshot changes also
invalidate it. Source failures, raw-cache expiry and missing replies therefore
leave the accepted primary in place, with no additional edits.

The frontend's existing `toggle_key_pending` / `Toggle_tick` deadline mechanism
also schedules and expires pending completion acceptance independently of
animation, even with no further input. Every source-event arrival checks expiry
again, so a queued response cannot bypass the deadline if it beats the tick.
Unrelated metadata does not extend it. Expiry drops the captured snapshot and
sends exact-token cancellation to release source-side work/cache.

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
Raw completion cache: at most 32 documents/connection, at most 512 retained
candidates/document, expires 10 seconds after the reply. One pending resolve per
document, at most 32/connection, also with a 10-second deadline. Close, restart,
cache expiry/eviction, and exact-token cancellation release raw items and cancel
resolve. Document changes cancel resolve without extending the raw cache expiry.

UTF-8/16/32 conversion requires exact code-point/line boundaries. Primary and
additional edits are normalized and validated against the captured snapshot.
Completion arrays, null results and completion lists are supported; lists preserve
`isIncomplete`. `Character` uses a server-advertised trigger character; otherwise
it becomes an ordinary invocation. `Incomplete` sends the corresponding protocol
trigger. Automatic typing requests can always requery.

InsertReplaceEdit always chooses the replace range explicitly, validating its
same-start/single-line/insert-prefix requirements. CompletionList itemDefaults
supports editRange (including insert/replace), insertTextFormat, insertTextMode
(AsIs only), and opaque data. textEditText is used with a default editRange;
explicit textEdit wins. Defaults are expanded into the raw item sent to resolve,
preserving server data. Initial metadata includes kind/docs/detail; resolve can
enrich docs/detail/additional edits but never changes the primary or ranking.

### Snippet insertion subset

The client advertises `snippetSupport=true`. For effective `insertTextFormat=2`,
normalization parses the primary insertion with `Ches_completion.Snippet.parse`
and resolves filename variables against the request's raw lexical resource path.
The candidate carries `snippet=Some parsed` and `primary.text=Snippet.text parsed`;
plain-format candidates carry `snippet=None`. Format defaults and item overrides
apply before parsing. The insertion comes from explicit textEdit.newText (including
InsertReplaceEdit), inherited editRange with textEditText/insertText/label, or the
ordinary insertText/label fallback. Additional edits always remain literal text.
Cycling places the cursor at the **end of the expanded text**, independently of
the first numbered field or `$0`; field activation belongs to explicit acceptance
in the host.

Supported syntax: `$1`, `${1}`, `${1:default}`, linked occurrences of the same
number, escaped `\$`, `\}`, `\\`, and a single `$0`/`${0}` final cursor marker.
Defaults support literal text (including Unicode) and filename variables:
`$TM_FILENAME`, `${TM_FILENAME_BASE}`, `${TM_DIRECTORY:literal}` and `TM_FILEPATH`
in the same forms. `${1:prefix_${TM_FILENAME_BASE:untitled}}` resolves before
installation; the resolved value is selected/editable and mirrors stay linked.
A later default also populates earlier mirrors. Variable fallbacks are literal,
and path values are never reparsed. Choices `${1|one,two|}` use their first option
as the default and retain linked cycling metadata. Without `$0`, the final cursor
defaults to the expansion's end.
Malformed syntax, unknown variables, transforms, nested numbered fields/choices,
recursive variable fallbacks, conflicting linked defaults, multiple final markers
and defaults on `$0` are deliberately
rejected: the entire item is skipped, never inserted as raw snippet syntax.
The parser bounds input to 65,536 bytes, expansion to 1,048,576 bytes and occurrences
to 4,096; tabstop numbers have at most nine digits. Invalid buffer text is rejected.
All parsed offsets and candidate cursor offsets are UTF-8 bytes.

Resolve sends the retained original snippet syntax and inherited opaque data to
the server. Resolved insertion/format fields are ignored: the already presented
expanded primary and parsed snippet remain authoritative. Resolved extras are
still checked in the original snapshot against that original primary, including
exact Unicode boundaries, edit bounds and overlap checks. Commands remain rejected.

Deliberate limitations: no commands, indentation adjustment,
commit-character acceptance, or dynamic capability registration. Unsupported items are
skipped. Servers with an unknown position encoding are not queried. Requests
before initialization are ignored, as are requests whose current snapshot cannot
be synchronized with the server's declared change support. Failures/timeouts do
not emit a completion reply; buffer-word candidates remain available.

Independent protocol verification: `dune runtest -j 6 source/test/completion`.
It covers Unicode conversion, flush ordering, plain/fallback/additional edits,
unsupported items, late replies after cancellation/revision/supersession/reopen,
capability checks, pooled request bounds, restart, and event queue isolation.
Snippet cases additionally cover inherited format2/textEditText/insert-replace,
explicit textEdit precedence, plain overrides, linked Unicode defaults, escapes,
malformed/unsupported syntax, literal extras, expanded-text cycling cursor,
resolve after primary installation with hostile replacement insertion fields,
and invalid/overlapping resolved extras.
Next-phase cases cover default inheritance/item overrides, UTF16 insert/replace
normalization, textEditText, opaque default data round-trip, lazy resolve after
primary installation, stale resolve after change/cancel/supersession/close/restart,
overlapping resolved edits, and primary-only Tab followed by additional-edit
finalization. Resolve errors/invalid results/timeouts emit no metadata; the UI's
one-second continuation bounds the wait and prevents late edits.

End-to-end wire/UI verification:
`dune runtest -j 6 source/test/completion_screen screen/test`.
The fake server exercises resolve before/after Tab, immediate/deferred acceptance,
late responses after typing or the UI deadline (even without a frontend tick),
and real raw-item expiry (including ignored retry).
`screen/test/test_completion_resolve.ml` covers uninstalled-primary safety,
resolved-extra replacement/clearing, deadline cancellation without typing, held
shortcut keys, paste, and same-primary selection races. The existing completion
tests also cover stale pre-Tab metadata, ownership changes and undo grouping.
