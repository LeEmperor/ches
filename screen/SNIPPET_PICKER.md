# Snippet discovery integration API

`Ches_completion.User_snippets` now publishes:

```ocaml
type origin = Bundled | Legacy_json | Ocaml [@@deriving sexp, equal]
type item = { declaration : declaration; origin : origin }
[@@deriving sexp, equal]
val available : t -> path:string option -> item list
val instantiate : t -> id:string -> path:string option
  -> text:Ches_core.Text_buffer.t -> cursor:int
  -> Model.Candidate.t Or_error.t
```

`available` filters effective entries by path scope (only globals for `None`),
sorting by lexical prefix then declaration ID. Original bodies are retained.
Provenance follows the effective declaration: inherited entries retain their
source, JSON replacements are `Legacy_json`, typed `apply` additions are `Ocaml`.

`instantiate` takes the **declaration ID** (e.g. `sv.mod`, not the candidate ID
`user-snippet:sv.mod`). It validates ID, scope and UTF-8 cursor boundary in the
supplied immutable catalog. It resolves filename variables and current-line
indentation. Its primary edit has `start = stop = cursor`; preceding text is
never consumed. The returned candidate carries the resolved snippet and normal
relative final cursor, suitable for the existing snippet activation path.
The existing `candidates` API still replaces the identifier prefix.

`Ches_screen.Snippet_picker_tile` publishes:

```ocaml
type t [@@deriving sexp_of]
val id : Ches_tile.View_id.t (* "snippet-picker" *)
val spec : Ches_tile.Spec.t (* result_picker, title "Insert snippet" *)
val create : Ches_completion.User_snippets.item list -> t
val selected : t -> Ches_completion.User_snippets.item option
val query : t -> string
val fit : t -> rows:int -> t
val interpret : Ches_input.Key.t list -> Palette_tile.action Ches_tile.Content_key.t
val update : t -> rows:int -> Ches_palette.Palette.Event.t -> t
val cursor : t -> width:int -> Ches_tile.Cursor.t
val render : ?hotkey_hints:bool -> ?notice:string -> t
  -> width:int -> rows:int -> Tile_shell.Content.t
```

Create with `User_snippets.available catalog ~path`. Selection is tracked by
declaration ID. Queries fuzzy-rank prefix, description and ID, retaining input
order on ties. Empty results yield `selected = None`. `fit`/`render` bound the
visible list; at eight content rows a preview shows ID, scope, origin and raw
body. Text uses shared Unicode-safe span clipping. `interpret` delegates to
`Palette_tile.interpret`: navigation and query events, `Accept` on Enter;
Escape/Ctrl-c remain host cancellation keys. No operation executes an insertion.

The host owns captured document identity/revision/cursor, catalog lifetime and
reload closure/refresh. Validate those before accepting `selected`, call
`instantiate` on that catalog and declaration ID, then use the existing insertion
and placeholder-session path. Cancellation simply discards the picker state.
