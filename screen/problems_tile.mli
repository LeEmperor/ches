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
val selection : t -> Problems.Key.t Ches_tile.Navigation.Selection.t

(** Whether the selected row's details are open, and their first visible row. *)
val details : t -> bool

val detail_top : t -> int

(** The open details: the selected row's description as read-only text. *)
val text_view : t -> Ches_tile.Text_view.t option

(** Record that [source]'s list for the open document was applied against [text]. *)
val applied : t -> source:string -> resource:string -> text:Ches_core.Text_buffer.t -> t
val forget_resource : t -> string -> t

(** The open document as this view matches findings in it. *)
val document : t -> Ches_core.Editor.t -> Problems.Document.t

val entries : t -> Feedback.t -> document:Problems.Document.t -> Problems.Row.t list

(** Reconcile selection with current feedback in a [width] by [rows] content viewport.
    When the selected key changes, details close. When its description changes,
    open details take the new text through {!Ches_tile.Text_view.update}, which ends
    any Visual selection rather than retargeting it. *)
val fit : t -> Feedback.t -> document:Problems.Document.t -> rows:int -> width:int -> t

val selected
  :  t
  -> Feedback.t
  -> document:Problems.Document.t
  -> rows:int
  -> Problems.Row.t option

(** Close details, as when the view stops being focused. *)
val leave : t -> t

type action [@@deriving sexp_of]

(** [e] toggles the selected row's details (inspecting a problem), [a] acknowledges a
    problem (findings are never acknowledged), and Enter jumps to its location in the
    current document, in the list or details.
    Otherwise, in the list, shared list motions ([j/k], [gg/G], [Ctrl-d/u]) select,
    [yy]/[Y] copy the selected problem's description, and edit keys are rejected; in
    details, keys go to the read-only text ({!Ches_tile.Text_view}: movement, Visual
    selection, yank). Copying never inspects, acknowledges, or jumps. *)
val interpret : t -> Ches_input.Key.t list -> action Ches_tile.Content_key.t

(** Escape ends Visual, then closes open details. *)
val escape : t -> action option

val hint : string

module Outcome : sig
  type nonrec t =
    { tile : t
    ; controller : Ches_app.Controller.t
    ; notice : [ `Post of string | `Show of string ] option
    (** [`Post] also reports the notice as feedback; [`Show] only displays it. *)
    ; effect : Ches_tile.Text_view.Effect.t option (** A copy or read-only notice. *)
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
