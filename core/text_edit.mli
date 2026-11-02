open! Core

type t = { start : int; stop : int; text : string }
[@@deriving sexp_of, equal]

(** Each batch uses its input snapshot; batches are sequential. Edits must be
    disjoint. Coincident insertions and insertions on replacement endpoints are
    rejected as ambiguous. Invalid ranges/text return Error, never partial edits. *)
val apply : Text_buffer.t -> t list list -> Text_buffer.t Or_error.t

(** Inverse of one validated batch, in output coordinates. *)
val inverse : Text_buffer.t -> t list -> t list Or_error.t
