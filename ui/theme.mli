(** The one place colors are defined: a palette of semantic roles, and the attributes
    for every {!Ches_screen.Style.t}. One dark theme: a near-black neutral gray
    ground, muted gray chrome, and color kept for the mode badge, the dirty marker,
    feedback, and escape forms. Every label is also readable without color. *)

open! Core
open Bonsai_term

module Role : sig
  type t =
    | Backdrop (** Outside the document tile: a shade darker, so the tile stands out. *)
    | Background (** The document tile. *)
    | Foreground
    | Surface (** Status line. *)
    | Muted (** Gutter and secondary text. *)
    | Border
    | Current_line
    | Normal_accent
    | Insert_accent
    | Special (** Escape forms and clip markers. *)
    | Warning
    | Error
  [@@deriving sexp_of, enumerate]

  val color : t -> Attr.Color.t
end

val attrs : Ches_screen.Style.t -> Attr.t list
