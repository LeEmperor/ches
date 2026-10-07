(** Messages a diagnostic source sends to Ches: the boundary between the asynchronous
    source library and the synchronous UI state. Plain data; no Async. *)
module Feedback := Error
open! Core

type t =
  | Diagnostics of
      { source : string
      ; resource : string
      ; revision : int option (** The document revision it describes, if versioned. *)
      ; findings : Feedback.Diagnostics.Finding.t list
      }
  | Started of { source : string; root : string }
  | Stopped of { source : string; root : string; reason : string }
  (** A running session ended: it crashed, exited, or failed while starting. *)
  | Unavailable of { source : string; root : string; reason : string }
  (** No session could be started, such as a server missing from PATH. *)
[@@deriving sexp_of]

(** The feedback update, stamping [current_revision] (the editor's revision when
    applied) onto diagnostics. *)
val to_update : t -> current_revision:int -> Feedback.update
