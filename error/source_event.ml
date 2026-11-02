module Feedback = Error
open! Core

module Server = struct
  type status = Starting | Running | Stopped of string | Unavailable of string
  [@@deriving sexp_of, equal]

  type t =
    { source : string
    ; program : string
    ; args : string list
    ; root : string
    ; resources : string list
    ; status : status
    }
  [@@deriving sexp_of, equal]
end

type t =
  | Servers of Server.t list
  | Owned of { resource : string; generation : int; event : t }
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

let rec to_update t ~current_revision : Feedback.update =
  match t with
  | Servers _ -> Noop
  | Owned { event; _ } -> to_update event ~current_revision
  | Diagnostics { source; resource; revision; findings } ->
    Diagnostics_received { source; resource; revision; current_revision; findings }
  | Started { source; root } -> Source_started { source; root }
  | Stopped { source; root; reason } -> Source_stopped { source; root; reason }
  | Unavailable { source; root; reason } -> Source_unavailable { source; root; reason }
;;
