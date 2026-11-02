(** Messages a diagnostic source sends to Ches: the boundary between the asynchronous
    source library and the synchronous UI state. Plain data; no Async. *)
module Feedback := Error
open! Core

module Server : sig
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
  | Completion of Ches_completion.Model.Reply.t
  (** Plain-text completion results; route immediately, independently of diagnostics. *)
  | Servers of Server.t list
  (** Authoritative current managed LSP inventory, independent of diagnostics.
      Never document-owned. Entries disappear when their last resource closes.
      [source] is the unique pool identity; [resources] are original editor paths. *)
  | Owned of { resource : string; generation : int; event : t }
  (** Event from a document-owned runtime. The UI drops it unless the resource still
      belongs to this session buffer generation, including after close/reopen. *)
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

(** The feedback update, stamping [current_revision] onto diagnostics.
    [Servers] and [Completion] yield [Noop]; consumers route them separately. *)
val to_update : t -> current_revision:int -> Feedback.update
