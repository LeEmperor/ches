(** The rows of the problems view: active problems (events such as a failed save or a
    stopped checker) first, in stable first-occurrence order, then diagnostic findings
    (standing state) sorted by file, severity, and position, as Trouble does. *)

open! Core
module Feedback = Ches_error.Error

(** What the view knows about the open document: which resource it is, its revision
    (for dimming findings that are behind), and its lines (for matching findings). *)
module Document : sig
  type t

  (** [anchor_text source] is the document text [source]'s current list was applied
      against, for reading its flagged lines; by default, the current text. Line numbers
      refer to that text, so reading them from text edited since would change a
      finding's key while its list is unchanged. *)
  val of_editor
    :  ?anchor_text:(string -> Ches_core.Text_buffer.t option)
    -> Ches_core.Editor.t
    -> t

  (** A document with no text, at revision 0. *)
  val of_path : string option -> t

  val path : t -> string option
end

(** A row's identity across refreshes. A problem is its {!Feedback.Identity.t}. A
    finding has no producer-assigned identity, so it is matched by content: source,
    severity, message, and the text of its flagged line in the open document (the line
    number elsewhere), with identical findings paired in order by [nth]. Moving a
    finding by inserting lines above it keeps its key; editing its line does not. *)
module Key : sig
  type anchor =
    [ `Text of string
    | `Line of int
    | `Nowhere
    ]
  [@@deriving sexp_of, equal]

  type t =
    | Problem of Feedback.Identity.t
    | Finding of
        { source : string
        ; severity : Feedback.Severity.t
        ; message : string
        ; anchor : anchor
        ; nth : int
        }
  [@@deriving sexp_of, equal]

  val identity : t -> Feedback.Identity.t option
end

module Row : sig
  type kind =
    | Problem of Feedback.Problem.t
    | Finding of
        { stale : bool
        (** Behind the open document's revision, or from a checker session that has
            ended: shown dimmed. *)
        ; stopped : bool (** Its source is stopped: marked in the row. *)
        }
  [@@deriving sexp_of]

  type t =
    { key : Key.t
    ; severity : Feedback.Severity.t
    ; source : string
    ; resource : string
    ; location : Feedback.Problem.Location.t option
    ; text : string
    ; kind : kind
    }
  [@@deriving sexp_of]
end

(** Exact resource equality with the open document's path selects the current
    document; unnamed documents match nothing. *)
val entries : Feedback.t -> current_document:bool -> document:Document.t -> Row.t list

(** Active problems plus diagnostic findings, unfiltered. *)
val count : Feedback.t -> int

(** Shell content for a [width] by [rows] content viewport: a read-only preview
    titled with filtered/total counts, its overflow counted in the footer; when focused,
    the selectable list or the selected row's open [details] (read-only text,
    see {!Tile_text.text_view}), with key hints or the
    capture notice/pending prefix in the footer.
    Hotkey hints are hidden unless [hotkey_hints] is [true]. Counts and
    capture notices/pending prefixes remain visible. *)
val render
  :  ?hotkey_hints:bool
  -> ?focused:bool
  -> ?navigation:Key.t Ches_tile.Navigation.Selection.t
  -> ?details:Ches_tile.Text_view.t
  -> ?notice:string
  -> ?pending:string
  -> Feedback.t
  -> current_document:bool
  -> document:Document.t
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t

(** The canonical one-line description: severity, source (with [stopped] when its
    checker is stopped), resource and location, and text. The list shows it, details
    show it in full, and copying copies it. *)
val description : Row.t -> string
