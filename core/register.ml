open! Core

module Kind = struct
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  { text : string
  ; kind : Kind.t
  }
[@@deriving sexp_of, equal]
