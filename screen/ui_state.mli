(** All UI-side state, and the transition for one input. No Bonsai types appear here,
    so tests drive it headlessly, exactly as the terminal frontend does.

    The model holds the {!Ches_app.Controller.t} (editor and keymap), the layout
    preferences, the scroll position, a bracketed paste being collected, and the
    status line's message slot. *)

open! Core
open Ches_input

module Message : sig
  type kind =
    | Info
    | Warning (** Keymap notices. *)
    | Error
  [@@deriving sexp_of, equal]

  type t =
    { kind : kind
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

(** Normalized terminal events. The frontend converts what its terminal reports. *)
module Input : sig
  type t =
    | Key of Key.t
    | Paste_start
    | Paste_end
  [@@deriving sexp_of]
end

type t

val create : ?prefs:Geometry.Prefs.t -> Ches_app.Controller.t -> t
val controller : t -> Ches_app.Controller.t
val prefs : t -> Geometry.Prefs.t
val scroll : t -> Scroll.t
val message : t -> Message.t option

(** Whether a bracketed paste is being collected. *)
val pasting : t -> bool

(** Whether an input has returned [Exit]. From then on, {!apply} ignores its input and
    returns [Exit] again, so keys that arrive before the frontend has shut down (say,
    [Space w] typed right after [Space Q]) never run. *)
val exited : t -> bool

(** Applies one input on a [width] x [height] screen.

    Keys between [Paste_start] and [Paste_end] are collected with [Key.text] and
    delivered as one paste at the end; keys without text are dropped. Everything else
    goes to the controller, with its effects (such as saving) performed before this
    returns.

    The message slot shows the feedback of the most recent input that produced any:
    the keymap's notice if it set one, otherwise the editor's message if the input
    dispatched an editor command (which may clear the slot). Other inputs, such as the
    first key of a sequence, leave it unchanged.

    The scroll is then fitted to keep the cursor visible. Once an input returns
    [Exit], no later input is applied (see {!exited}). *)
val apply
  :  t
  -> width:int
  -> height:int
  -> Input.t
  -> t * Ches_app.Controller.Status.t

(** [apply] for each input in order, stopping at [Exit]. *)
val apply_all
  :  t
  -> width:int
  -> height:int
  -> Input.t list
  -> t * Ches_app.Controller.Status.t

(** The geometry of a [width] x [height] screen for this state. *)
val geometry : t -> width:int -> height:int -> Geometry.t

(** {!scroll} fitted to a [width] x [height] screen, so a resize keeps the cursor
    visible before the next input arrives. *)
val fitted_scroll : t -> width:int -> height:int -> Scroll.t
