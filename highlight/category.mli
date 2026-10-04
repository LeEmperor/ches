open! Core

(** Provider-independent foreground roles. Plain is the absence of a highlight. *)
type t =
  | Plain | Keyword | String | Escape | Number | Comment | Type | Constructor
  | Module | Function | Variable | Property | Operator | Punctuation | Constant
[@@deriving sexp_of, equal, compare, enumerate]

(** Lower values win equal-length overlaps. *)
val priority : t -> int

(** Recognized dotted capture families; unknown and internal [_] captures are ignored. *)
val of_capture : string -> t option
