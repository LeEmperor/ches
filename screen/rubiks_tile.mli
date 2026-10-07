open! Core

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

(** Twenty random moves for 3x3 practice, not uniform random-state/WCA scrambles. *)
val generate : Random.State.t -> string

type solve = { scramble : string; seconds : float }
type t = private
  { scramble : string
  ; started : Time_ns.t option
  ; now : Time_ns.t
  ; solves : solve list
  }

val create : unit -> t
val running : t -> bool
(** Leaving focus cancels an unfinished solve without recording it. *)
val cancel : t -> t
val tick : t -> Time_ns.t -> t
val elapsed : t -> float
(** Start, or record a solve and generate the next scramble. Keep the latest 100. *)
val space : t -> now:Time_ns.t -> t

type action = Space | Next
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t
val perform : t -> action -> t
val render : t -> focused:bool -> width:int -> rows:int -> Tile_shell.Content.t
