(** The one place colors are defined: a palette of semantic roles, and the attributes
    for every {!Ches_screen.Style.t}. Colors are provisional until the phase 6B visual
    pass. *)

open! Core
open Bonsai_term

module Role : sig
  type t =
    | Background
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
