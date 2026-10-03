open! Core

module Kind = struct
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  | Text of
      { text : string
      ; kind : Kind.t
      }
  | Block of
      { rows : string list
      ; width : int
      }
[@@deriving sexp_of, equal]
