open! Core

(** One encompassing replacement, relative to the entire previous snapshot.
    Points count LF rows and UTF-8 bytes, not characters or display cells. *)
type point = { row : int; column : int } [@@deriving sexp_of, equal, compare]
type t =
  { start_byte : int
  ; old_end_byte : int
  ; new_end_byte : int
  ; start_point : point
  ; old_end_point : point
  ; new_end_point : point
  }
[@@deriving sexp_of, equal]

(** Valid UTF-8 required (otherwise Invalid_argument). None means identical bytes.
    Common prefix/suffix endpoints are rounded outwards to code-point boundaries.
    O(old bytes + new bytes); disjoint edits intentionally encompass unchanged text. *)
val between : old_source:string -> new_source:string -> t option
