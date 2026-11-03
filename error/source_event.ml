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
  | Instance_context_changed of
      { source : string; revision : int; module_name : string option; hier_path : string option }
  | Query_result of Language_query.reply
  | Completion of Ches_completion.Model.Reply.t
  | Completion_metadata of { token : Ches_completion.Model.Token.t; source : string; items : Completion_info.t list }
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
  | Instance_context_changed _ | Query_result _ | Servers _ | Completion _ | Completion_metadata _ -> Noop
  | Owned { event; _ } -> to_update event ~current_revision
  | Diagnostics { source; resource; revision; findings } ->
    Diagnostics_received { source; resource; revision; current_revision; findings }
  | Started { source; root } -> Source_started { source; root }
  | Stopped { source; root; reason } -> Source_stopped { source; root; reason }
  | Unavailable { source; root; reason } -> Source_unavailable { source; root; reason }
;;
