(** The terminal-friendly part of the animated cursor.  It deliberately knows
    nothing about Bonsai, editor state, or terminal rendering. *)

open! Core

type point =
  { x : float
  ; y : float
  }

type t

val create : enabled:bool -> t
val enabled : t -> bool
val active : t -> bool
val set_enabled : t -> bool -> t

(** Retarget the animated quadrilateral after a cursor movement.  Positions are screen
    cells, with [(0, 0)] at the terminal's top left. *)
val retarget : t -> from:(int * int) option -> to_:(int * int) option -> t

(** Advance one animation frame.  [dt] is in seconds. *)
val tick : t -> dt:float -> t

(** Filled terminal cells occupied by the current smear, clipped to the given screen. *)
val cells : t -> width:int -> height:int -> (int * int) list
