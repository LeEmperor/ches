(** Requests Ches sends to a diagnostic source: the other direction of the boundary in
    {!Source_event}. The synchronous side produces them as data (see
    [Ches_screen.Ui_state.take_source_requests]); the frontend hands them to the
    asynchronous source library. Plain data; no Async. *)
open! Core

type t =
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
  | Restart (** Stop the source if it is running and start it again. *)
  | Kill
  (** Make the source crash, for testing the stopped state by hand. Only the synthetic
      source supports it; a real source ignores it. *)
[@@deriving sexp_of, equal]
