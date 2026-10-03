(** Pure conversion from a motion to a validated half-open deletion range. *)

open! Core

type t =
  { start : int
  ; stop : int
  ; kind : Register.Kind.t
  }
[@@deriving sexp_of, equal]

val linewise : Text_buffer.t -> cursor:int -> destination:int -> t

(** Resolve an operator motion.  A successful result may be empty at a clamped
    boundary.  [%] and unmatched delimiter failures are passed through unchanged. *)
val resolve
  :  Text_buffer.t
  -> Motion.t
  -> cell_width:Cell_layout.Width.t
  -> cursor:int
  -> preferred_column:int
  -> count:int option
  -> (t, Motion.Failure.t) Result.t

val resolve_destination : Text_buffer.t -> Motion.Find.t -> cursor:int -> destination:int -> t

(** The small word under [cursor], or the next one when the cursor is on blanks.
    It is a characterwise range for the supported [diw] text object. *)
val inner_word : Text_buffer.t -> cursor:int -> t option
