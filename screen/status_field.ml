open! Core

module Id = struct
  type t =
    | Mode
    | Filename
    | Dirty
    | Pending
    | Position
    | Message
  [@@deriving sexp_of, equal, enumerate]
end

type fit =
  | Whole
  | Cut_left
  | Cut_right
[@@deriving sexp_of]

type side =
  | Left
  | Right
[@@deriving sexp_of]

type t =
  { id : Id.t
  ; spans : Span.t list
  ; priority : int
  ; fit : fit
  ; side : side
  }
[@@deriving sexp_of]
