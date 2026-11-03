(** Requests Ches sends to a diagnostic source: the other direction of the boundary in
    {!Source_event}. The synchronous side produces them as data (see
    [Ches_screen.Ui_state.take_source_requests]); the frontend hands them to the
    asynchronous source library. Plain data; no Async. *)
open! Core

type t =
  | Query of Language_query.request
  (** Hover or declaration/definition-first lookup on the exact current snapshot.
      Unsupported or unavailable queries emit a failed Query_result. *)
  | Cancel_query of Ches_completion.Model.Token.t
  (** Exact-token cancellation; edits, close and restart also invalidate queries. *)
  | Complete of Ches_completion.Model.Request.t
  (** Query the attached pooled server against this token's exact document snapshot.
       Requests before initialization or for stale tokens are ignored. *)
  | Resolve_completion of { token : Ches_completion.Model.Token.t; candidate_id : string; revision : int }
  (** Resolve a retained candidate lazily. [revision] guards the current buffer,
      and may differ from token.revision after installing a primary. Results are
      Completion_metadata, with edits in the token's original base coordinates.
      A new resolve supersedes the prior resolve for this document. *)
  | Cancel_completion of Ches_completion.Model.Token.t
  (** Cancel only the matching in-flight token; obsolete cancellation is harmless. *)
  | Document_opened of { resource : string; generation : int }
  (** Allocate a document-owned runtime; generation is the session buffer ID. *)
  | Document_closed of { resource : string }
  (** Actual close, not deactivation. Stop/release its diagnostic runtime. *)
  | Document_changed of
      { resource : string
      ; text : string (** The open document's whole, possibly unsaved, text. *)
      ; revision : int
      }
  (** The open document now has this text. Also sent once for the initial text. *)
  | Document_saved of
      { resource : string
      ; revision : int (** The revision written; its text was sent as changed first. *)
      }
  | Inspect (** Emit the authoritative current [Source_event.Servers] inventory now. *)
  | Restart (** Stop the source if it is running and start it again. *)
  | Kill
  (** Make the source crash, for testing the stopped state by hand. Only the synthetic
      source supports it; a real source ignores it. *)
[@@deriving sexp_of, equal]
