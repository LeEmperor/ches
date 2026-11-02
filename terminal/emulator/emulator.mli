open! Core
open Ches_terminal

type t
val create : rows:int -> cols:int -> t
val resize : t -> rows:int -> cols:int -> unit
(** Feeds child output. The returned bytes are terminal protocol replies to send
    back to the child, never text to write to the application's terminal. *)
val feed : t -> string -> string
val key : t -> Model.key -> string
val paste : t -> string -> string
val snapshot : t -> exited:string option -> Model.snapshot
val close : t -> unit
