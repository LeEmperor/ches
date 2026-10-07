module Feedback = Error
open! Core

type t =
  | Diagnostics of
      { source : string
      ; resource : string
      ; revision : int option
      ; findings : Feedback.Diagnostics.Finding.t list
      }
  | Started of { source : string; root : string }
  | Stopped of { source : string; root : string; reason : string }
  | Unavailable of { source : string; root : string; reason : string }
[@@deriving sexp_of]

let to_update t ~current_revision : Feedback.update =
  match t with
  | Diagnostics { source; resource; revision; findings } ->
    Diagnostics_received { source; resource; revision; current_revision; findings }
  | Started { source; root } -> Source_started { source; root }
  | Stopped { source; root; reason } -> Source_stopped { source; root; reason }
  | Unavailable { source; root; reason } -> Source_unavailable { source; root; reason }
;;
