# Pure snippets integration contract

`Ches_completion.Snippet.parse : string -> t Or_error.t` and `text : t -> string`
are the source-facing API. A candidate carries `snippet : Snippet.t option`;
its `primary.text` must equal `Snippet.text` when present. Buffer words use `None`.
Malformed/unsupported snippets should be skipped by providers.

`Model.start ?prefer_local_snippets ~token ~text ~cursor ~words ~limit ()`
defaults to preferring local snippets over LSP suggestions. With `false`, LSP
suggestions precede local snippets; both remain available ahead of buffer words.
The preference is retained throughout the model's provider rebuilds.

`snippet.mli` is the authoritative interface. All offsets are UTF-8 **bytes**.
`fields` returns sorted positive field numbers with occurrence ranges relative to
expanded text; `final_cursor` is `$0` or expansion end. Supported syntax is `$1`,
`${1}`, `${1:default}`, `$0`, and escaped `\\`, `\$`, `\}`. Forward mirrors inherit
the first explicit default. Conflicting defaults, nested numbered defaults,
variables, transformations and choices are rejected deliberately. Parser and
session expansion sizes and occurrence counts are bounded: 65,536 input bytes,
1,048,576 expanded bytes, 4,096 explicit occurrences and nine-digit field numbers.
There is no recursive parsing or expansion. Repeated `$0`, defaults on `$0`,
unterminated placeholders and unsupported escapes are errors. Braces outside
placeholders are literal text, so ordinary code bodies need no extra escaping.

## UI session workflow

After explicit acceptance and all additional edits, calculate the expansion's
absolute base and call `Session.start template ~base ~revision ~text` using the
installed document. It validates the expansion. Ranges in the session are absolute.
`selection` initially spans the first occurrence of the lowest numbered field;
`cursor` is its end. `active` includes every mirror. Highlight/application belongs
to the UI, not this module.

Typing calls `Session.insert session ~revision ~text inserted`, which replaces the
initial selection, then inserts at the tracked caret on subsequent calls. For
backspace/delete use `Session.replace` with an explicit absolute range in the
tracked active occurrence (`active_range`). Apply `Session.edits change` as one atomic edit set, place the
caret at `cursor_after change`, then use `Session.applied change ~revision` with
the actual resulting revision. A failed application must not advance the session.
Edits update all linked occurrences, including mirrors before other numbered
fields, and relocate every later field and the final cursor. Each change returns
one replacement spanning the entire expanded snippet region. This keeps empty,
coincident occurrences unambiguous for `Text_edit` and preserves their template
source order (including the affinity of `$0` at the same position).

`Session.set_cursor` tracks caret movement within any occurrence of the active
numbered field, including a later mirror, and clears the default selection. At
shared endpoints it prefers the currently tracked occurrence. `navigate
Next/Previous` selects the first occurrence of a field afresh;
Next after the last field clears selection and places the cursor at `$0`, setting
`finished`. No positive fields means immediately finished. Previous at the first
field reselects it. `matches` checks the exact revision and document snapshot;
external edits should cancel the session. The UI owns escape, undo, buffer/document
lifetime, external movement, and cancellation.
