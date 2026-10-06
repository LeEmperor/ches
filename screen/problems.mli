open! Core

(** Stable first-occurrence order. Exact resource equality matches the single-file
    controller's identities; unnamed documents have no matching problems. *)
val entries
  : Ches_error.Error.t
  -> current_document:bool
  -> path:string option
  -> Ches_error.Error.Problem.t list

(** Shell content for a [width] by [rows] content viewport: a read-only preview
    titled with filtered/total counts, its overflow counted in the footer; when focused,
    the selectable list or the selected problem's open [details] (read-only text,
    see {!Tile_text.text_view}), with key hints or the
    capture notice/pending prefix in the footer. *)
val render
  : ?focused:bool
  -> ?navigation:Ches_error.Error.Identity.t Ches_tile.Navigation.Selection.t
  -> ?details:Ches_tile.Text_view.t
  -> ?notice:string
  -> ?pending:string
  -> Ches_error.Error.t
  -> current_document:bool
  -> path:string option
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t

(** The canonical one-line description: severity, source, resource and location, and
    text. The list shows it, details show it in full, and copying copies it. *)
val description : Ches_error.Error.Problem.t -> string
