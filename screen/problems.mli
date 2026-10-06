open! Core

(** Stable first-occurrence order. Exact resource equality matches the single-file
    controller's identities; unnamed documents have no matching problems. *)
val entries
  : Ches_error.Error.t
  -> current_document:bool
  -> path:string option
  -> Ches_error.Error.Problem.t list

(** Read-only, cell-clipped preview with filtered/total and overflow counts; when
    focused, the selectable list or the selected problem's details. *)
val render
  : ?focused:bool
  -> ?navigation:Ches_error.Error.Identity.t Ches_tile.Navigation.Selection.t
  -> ?details:bool
  -> ?detail_top:int
  -> ?notice:string
  -> ?pending:string
  -> Ches_error.Error.t
  -> current_document:bool
  -> path:string option
  -> rect:Geometry.Rect.t
  -> Span.t list list

(** Sanitized full description, wrapped by display cells. *)
val detail_rows : Ches_error.Error.Problem.t -> width:int -> Span.t list list
