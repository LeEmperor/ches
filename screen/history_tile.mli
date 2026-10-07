(** The notification history content adapter: a chronological, selectable list of
    {!Ches_error.Error.History} entries with read-only details, on the shared host,
    navigation, shell, and text view. It owns no storage: the feedback reducer keeps the
    entries, and nothing this view does (selecting, copying, hiding, leaving) changes
    them or any active problem. Only an explicit clear ([X]) asks the application to
    empty the history.

    Selection is keyed on an entry's [seq]. It follows the newest entry, like a log's
    tail, until the user moves it or opens details; from then until the view is left
    or cleared, it stays on its entry as newer ones arrive. When the selected entry is
    evicted for capacity, the oldest retained entry is selected; an empty history
    selects nothing. *)

open! Core
module Feedback = Ches_error.Error

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

val empty : t

(** The stored selection; use {!fit} first for one that matches the history. *)
val selection : t -> int Ches_tile.Navigation.Selection.t

(** Whether the selected entry's details are open. *)
val details : t -> bool

(** The open details: the selected entry's description as read-only text. *)
val text_view : t -> Ches_tile.Text_view.t option

(** Reconcile the selection and open details with [history] in a [width] by [rows]
    content viewport. Details close when the selected entry changes; when its text
    changes (a merged repeat), they take the new text through
    {!Ches_tile.Text_view.update}. *)
val fit : t -> Feedback.History.t -> rows:int -> width:int -> t

(** Close details and follow the newest entry again, as when the view stops being
    focused. *)
val leave : t -> t

type action [@@deriving sexp_of]

(** [e] or Enter toggles the selected entry's details and [X] clears the history, in the
    list or details. Otherwise, in the list, shared list motions select, [yy]/[Y] copy
    the selected entry's description, and edit keys are rejected; in details, keys go
    to the read-only text. *)
val interpret : t -> Ches_input.Key.t list -> action Ches_tile.Content_key.t

(** Escape ends Visual, then closes details. *)
val escape : t -> action option

val hint : string

module Outcome : sig
  type nonrec t =
    { tile : t
    ; effect : Ches_tile.Text_view.Effect.t option (** A copy or read-only notice. *)
    ; clear : bool (** Apply [Clear_history]. *)
    }
end

(** [rows] and [width] are the focused view's content viewport. *)
val perform
  :  t
  -> Feedback.History.t
  -> rows:int
  -> width:int
  -> action
  -> Outcome.t

(** The canonical one-line description: sequence number, merged count, severity or
    lifecycle, source, resource, and text. The list shows it, details show it in full,
    and copying copies it. *)
val description : Feedback.History.Entry.t -> string

(** Shell content for a [width] by [rows] content viewport. Unfocused, the newest
    entries that fit, oldest first; focused, the selectable list or open details. *)
val render
  :  ?focused:bool
  -> ?notice:string
  -> ?pending:string
  -> t
  -> Feedback.History.t
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t
