open! Core

type t =
  | Write_file of
      { path : string
      ; text : Text_buffer.t
      ; revision : int
       }
  | Read_file of { path : string }
  | Set_clipboard of string
  | Exit
[@@deriving sexp_of, equal]

module Outcome = struct
  type t =
    | Write_file_finished of
        { path : string
        ; text : Text_buffer.t
        ; revision : int
        ; result : unit Or_error.t
        }
    | Read_file_finished of { path : string; result : Text_buffer.t Or_error.t }
  [@@deriving sexp_of]
end
