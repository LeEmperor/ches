(** Requests the editor makes of its environment, and their reported outcomes.

    [ches_core] never performs I/O. {!Editor.dispatch} returns effects; the application
    performs them and reports each [Write_file] with {!Editor.handle_outcome}. The
    application must complete writes in the order they were requested. *)

open! Core

type t =
  | Write_file of
      { path : string
      ; text : Text_buffer.t
      ; revision : int (** The document revision [text] was taken at. *)
      }
  (** Write exactly [text] to [path], then report [Outcome.Write_file_finished] with the
      same fields. *)
  | Exit (** Terminate the editor. *)
[@@deriving sexp_of, equal]

module Outcome : sig
  type t =
    | Write_file_finished of
        { path : string
        ; text : Text_buffer.t
        ; revision : int
        ; result : unit Or_error.t
        }
  [@@deriving sexp_of]
end
