(** The workspace's focus and input-capture boundary. It owns which view is focused,
    the pending capture prefix, the capture notice, and a bracketed paste's starting
    owner. It decides how a key typed into a captured (non-primary) view is handled
    and returns that decision. It never interprets content actions or touches a
    document, source, or feedback.

    Focus is a request: it is effective only while the view is available (allocated),
    and otherwise the primary view is focused. {!reconcile} makes the request match. *)

open! Core
open Ches_input

type t [@@deriving sexp_of]

(** [primary] (the editor) must be among [views]; it is initially focused. Key
    sequences beginning with [leader] are workspace commands. *)
val create : leader:Key.t -> primary:View_id.t -> Spec.t list -> t

val primary : t -> View_id.t

(** Raises for a view not given to {!create}. *)
val spec : t -> View_id.t -> Spec.t

(** The effective focus. *)
val focused : t -> available:(View_id.t -> bool) -> View_id.t

(** The effective focus when it is not the primary view. *)
val capturing : t -> available:(View_id.t -> bool) -> View_id.t option

(** The effective focus, when its view owns the terminal cursor. *)
val cursor_owner : t -> available:(View_id.t -> bool) -> View_id.t option

(** Request focus on a focusable view, clearing the prefix and notice. A
    non-focusable view is ignored. *)
val focus : t -> View_id.t -> t

(** Focus the primary view, clearing the prefix and notice. *)
val return : t -> t

(** Return to the primary view if the requested focus is unavailable. *)
val reconcile : t -> available:(View_id.t -> bool) -> t * [ `Kept | `Returned of View_id.t ]

val pending : t -> Key.t list
val notice : t -> string option

(** Sets the capture notice and cancels any pending prefix. *)
val with_notice : t -> string -> t

module Decision : sig
  type 'action t =
    | Handled (** Only the host's prefix or notice changed. *)
    | Workspace of View_command.t (** A configured workspace binding to run. *)
    | Content of 'action (** For the focused view's adapter. *)
    | Return (** Back to the primary view. *)
    | Notice of string (** Rejected; the prefix is already cancelled. *)
  [@@deriving sexp_of]
end

(** A key typed into the captured view, with this precedence:

    - Escape cancels a pending prefix; otherwise it takes [escape] (the content's
      own back action, e.g. closing details) if given; otherwise it returns.
    - Ctrl-c gives a notice; Tab returns.
    - A sequence starting with the leader is looked up in [lookup] (the configured
      keymap). View commands run, except document scrolling. Editor commands and
      unbound sequences are rejected. In a view that accepts text
      ({!Spec.t.accepts_text}) the leader is text like any other key: Escape returns
      first, and the leader then works from the primary view.
    - Other keys go to [content]. An unbound key gives [hint], or cancels a pending
      content prefix.

    A decision other than [Handled] for a pending prefix clears it; a content
    action also clears the notice. *)
val key
  :  t
  -> Key.t
  -> lookup:(Key.t list -> Bindings.lookup)
  -> content:(Key.t list -> 'action Content_key.t)
  -> escape:'action option
  -> hint:string
  -> t * 'action Decision.t

(** Whether a bracketed paste is being collected. *)
val pasting : t -> bool

(** Keep collecting an interrupted paste, but reject its completion even if a new
    instance of the same view opens. Never redirect it to the new capture/document. *)
val invalidate_paste : t -> View_id.t -> t

(** Start collecting a paste owned by the effective focus. Ignored while collecting. *)
val paste_start : t -> available:(View_id.t -> bool) -> t

(** Add a key's text ({!Key.text}) to the paste being collected; keys without text are
    dropped. *)
val paste_key : t -> Key.t -> t

(** Finish the paste. It goes to its starting owner, even if focus changed since:
    [`Deliver] if that view accepts paste, otherwise [`Reject] with a notice. *)
val paste_end
  :  t
  -> t
     * [ `Deliver of View_id.t * string | `Reject of View_id.t * string | `Not_pasting ]
