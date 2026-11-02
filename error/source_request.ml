open! Core

type t =
  | Complete of Ches_completion.Model.Request.t
  | Cancel_completion of Ches_completion.Model.Token.t
  | Document_opened of { resource : string; generation : int }
  | Document_closed of { resource : string }
  | Document_changed of
      { resource : string
      ; text : string
      ; revision : int
      }
  | Document_saved of
      { resource : string
      ; revision : int
      }
  | Inspect
  | Restart
  | Kill
[@@deriving sexp_of, equal]
