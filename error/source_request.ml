open! Core

type t =
  | Document_changed of
      { resource : string
      ; text : string
      ; revision : int
      }
  | Document_saved of
      { resource : string
      ; revision : int
      }
  | Restart
  | Kill
[@@deriving sexp_of, equal]
