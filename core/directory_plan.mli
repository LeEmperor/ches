open! Core

(** Pure, all-or-nothing proposals for immediate children. No filesystem IO.
    Baseline occupants may be destinations only if they are renamed away;
    swaps/cycles are valid proposals for a future dependency-aware executor. *)
type operation =
  | Create_file of string
  | Create_directory of string
  | Rename of { id : int; source : string; destination : string }
[@@deriving sexp_of, equal]

val plan : Directory_identity.Entry.t list -> Text_buffer.t -> operation list Or_error.t
val summary : operation list -> string
