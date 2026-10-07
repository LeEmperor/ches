open! Core

module Shape = struct
  type t =
    | Block
    | Bar
  [@@deriving sexp_of, equal]
end

type t =
  { row : int
  ; column : int
  ; shape : Shape.t
  }
[@@deriving sexp_of, equal]
