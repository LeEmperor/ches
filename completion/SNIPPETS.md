# Pure snippets integration contract

`Ches_completion.Snippet.parse : string -> t Or_error.t` and `text : t -> string`
are the source-facing API. A candidate carries `snippet : Snippet.t option`;
its `primary.text` must equal `Snippet.text` when present. Buffer words use `None`.
Malformed/unsupported snippets should be skipped by providers.

## Rich syntax API (provider and interaction integration)

`Snippet.resolve : t -> path:string option -> t Or_error.t` resolves supported
filename variables after parsing, before indentation or installation. Parsing
retains unresolved variables, so catalog validation needs no document path.
Providers must resolve with the current document's raw editor path (no filesystem
I/O or absolute-path conversion). Local providers resolve before `indent`.

`Session.choices : t -> string list option` returns the active field's choices.
`Session.cycle_choice : t -> direction -> revision:int -> text:Text_buffer.t ->
change Or_error.t` uses the same edits/cursor_after/applied protocol as insert.
Next/Previous wrap; after custom text they choose the first/last option. Cycling
updates mirrors and keeps the tracked occurrence fully selected, so typing
replaces the chosen value. Choice metadata survives edits and field navigation.

Choices use `${1|posedge,negedge|}`; the first option is the default. Within a
choice, comma, pipe and backslash are escaped as `\,`, `\|`, `\\`.
Variables are `$TM_FILENAME`, `${TM_FILENAME_BASE}`, `${TM_DIRECTORY:literal}`,
and `TM_FILEPATH` in the same forms. Unknown variables are errors. Missing or
unnamed paths use the literal fallback or empty text. Filename base removes only
the final extension. Numbered defaults may combine literal text and these variable
forms: `${1:${TM_FILENAME_BASE}}`, `${1:prefix_${TM_FILENAME_BASE:untitled}}`,
or `${1:$TM_FILENAME}`. The parsed default retains its structure. Resolution
populates every occurrence (including forward mirrors) before installation and
selection, leaving the whole default editable as one linked numbered field.
Repeated explicit definitions must have equal parsed structure, even if distinct
definitions would render the same value for a particular path. Literal defaults
and first choice options retain their existing equality/conflict behavior.

`Model.start ?prefer_local_snippets ~token ~text ~cursor ~words ~limit ()`
defaults to preferring local snippets over LSP suggestions. With `false`, LSP
suggestions precede local snippets; both remain available ahead of buffer words.
The preference is retained throughout the model's provider rebuilds.

`snippet.mli` is the authoritative interface. All offsets are UTF-8 **bytes**.
`fields` returns sorted positive field numbers with occurrence ranges relative to
expanded text; `final_cursor` is `$0` or expansion end. Supported syntax is `$1`,
`${1}`, `${1:default}`, `${1|one,two|}`, `$0`, supported filename variables,
and escaped `\\`, `\$`, `\}`. Forward mirrors inherit the first explicit default
or choice list. Conflicting defaults/choice lists, nested numbered fields and
transformations are rejected deliberately. Parser and
session expansion sizes and occurrence counts are bounded: 65,536 input bytes,
1,048,576 expanded bytes, 4,096 explicit occurrences and nine-digit field numbers.
Nesting is bounded to a numbered default containing a filename variable (two
placeholder levels); a variable's optional fallback is literal text only. Nested
numbered fields, choices, variable fallbacks containing variables, and transforms
are rejected. There is no recursive expansion. Repeated `$0`, defaults on `$0`,
unterminated placeholders and unsupported escapes are errors. Braces outside
placeholders are literal text, so ordinary code bodies need no extra escaping.

`parse` initially renders filename variables with their fallback or empty text;
the unresolved structure remains available for repeated `resolve` calls with
different paths. `TM_FILEPATH` preserves the supplied path verbatim;
`TM_DIRECTORY` is its lexical dirname (`.` for a bare filename), `TM_FILENAME`
is its basename, and `TM_FILENAME_BASE` strips the final dot-extension only.
An empty path is unnamed. Variable values are inserted literally, with no
recursive parsing, I/O, URI decoding, or expansion of snippets embedded in paths.
Literal variable defaults use the normal `\\`, `\$`, `\}` escapes. A choice can
contain empty or multiline options; choice text is literal and only `\,`, `\|`,
and `\\` are recognized as escapes inside it. Indentation adds the prefix after
each newline in every option, not just in the initial expanded choice. Expansion
and retained choice text each have a 1 MiB budget, checked before allocation.
Indentation is applied to resolved default segments exactly once; resolving an
already indented template gives the same text and ranges as indenting after
resolution, including newlines in filenames and fallback values.

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
