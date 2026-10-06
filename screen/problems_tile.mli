(** The problems content adapter: translates shared feedback into a selectable list
    and details, and the shared host's actions back into selected acknowledgement,
    inspection, and validated same-document navigation. This is the only tile module
    that knows [Ches_error]; the host and shared navigation never see a problem.

    View-local state (filter, selection, details) is independent of the feedback it
    presents: filtering, selecting, hiding, or leaving never acknowledges, resolves, or
    removes a problem. *)

open! Core
module Feedback = Ches_error.Error

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

val empty : t

(** Current-document filter, rather than the whole workspace. *)
val current_document : t -> bool

val toggle_filter : t -> t

(** The stored selection; use {!fit} first for one that matches current feedback. *)
val selection : t -> Feedback.Identity.t Ches_tile.Navigation.Selection.t

val details : t -> bool
val detail_top : t -> int
val entries : t -> Feedback.t -> path:string option -> Feedback.Problem.t list

(** Reconcile selection with current feedback in [rows] visible items. When the
    selected identity changes, details close and their scroll resets. *)
val fit : t -> Feedback.t -> path:string option -> rows:int -> t

val selected : t -> Feedback.t -> path:string option -> rows:int -> Feedback.Problem.t option

(** Close details, as when the view stops being focused. *)
val leave : t -> t

type action [@@deriving sexp_of]

(** Shared list motions ([j/k], [gg/G], [Ctrl-d/u]) select, or scroll open details.
    [e] inspects the selected identity and toggles details, [a] acknowledges it, and
    Enter jumps to its location in the current document. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t

(** Escape closes open details. *)
val escape : t -> action option

val hint : string

module Outcome : sig
  type nonrec t =
    { tile : t
    ; controller : Ches_app.Controller.t
    ; notice : [ `Post of string | `Show of string ] option
    (** [`Post] also reports the notice as feedback; [`Show] only displays it. *)
    ; return : bool (** Return focus to the document (after a jump). *)
    }
end

(** [rows] and [width] are the focused view's content viewport. *)
val perform
  :  t
  -> Ches_app.Controller.t
  -> rows:int
  -> width:int
  -> action
  -> Outcome.t
