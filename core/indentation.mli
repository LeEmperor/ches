open! Core

(** Language-independent indentation in display columns; TABs use
    {!Cell_layout.tab_stop}, independently of the shift width. *)
module Policy : sig
  type t = { shift_width : int; use_tabs : bool } [@@deriving sexp_of, equal]
  val default : t
  (** Raises [Invalid_argument] unless [shift_width] is positive. *)
  val validate : t -> unit
end

(** Byte length and display width of the leading spaces and TABs. *)
val prefix : string -> int * int

(** Rewrite only the prefix, adding/subtracting [count] widths, clamping left at
    zero. [count] must be in [1, Command.max_count]. Blank lines may be skipped.
    [None] means byte-for-byte unchanged, including noncanonical whitespace at
    zero width. An unrepresentably large right shift raises [Invalid_argument]. *)
val shifted_prefix
  : Policy.t -> right:bool -> count:int -> skip_blank:bool -> string -> string option

(** Boundary in a whitespace prefix covering a display column, clamped to its end.
    A column inside a TAB maps to the boundary before that TAB. *)
val position_at_column : string -> int -> int
