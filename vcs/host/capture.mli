(** Output bookkeeping for one child process, kept pure so it can be tested without
    processes. Internal to [ches_vcs_host]: {!Runner} is the only user.

    - {!Head} keeps the first bytes of a stream (stdout: the start is the answer).
    - {!Tail} keeps the last bytes of a stream (stderr: the end holds the error).
    - {!Lines} splits a stream into {!Ches_vcs.Event.Line.t}s for streaming specs. *)

open! Core
open Ches_vcs

module Head : sig
  type t

  (** Keeps at most [limit] bytes (positive). *)
  val create : limit:int -> t

  (** Returns whether this chunk took the total past [limit] for the first time. *)
  val add : t -> Bytes.t -> pos:int -> len:int -> [ `Within | `Passed_limit | `Beyond ]

  val contents : t -> string

  (** More than [limit] bytes were added. *)
  val truncated : t -> bool
end

module Tail : sig
  type t

  (** Keeps the last [limit] bytes (positive), in amortized linear time. *)
  val create : limit:int -> t

  val add : t -> Bytes.t -> pos:int -> len:int -> unit
  val contents : t -> string

  (** More than [limit] bytes were added, so earlier ones were dropped. *)
  val truncated : t -> bool
end

module Lines : sig
  type t

  (** Lines end at ['\n'] (a line) or ['\r'] (a transient line). A ["\r\n"] pair reports
      the line as transient at the ['\r'] (at once, since the next byte may be long in
      coming) and again, permanent, at the ['\n'], which replaces it. A line longer than
      {!max_line} is reported in pieces of [max_line] bytes. *)
  val create : unit -> t

  (** 4096 bytes. *)
  val max_line : int

  val feed : t -> Bytes.t -> pos:int -> len:int -> f:(Event.Line.t -> unit) -> unit

  (** End of file: reports a final unterminated line, if any. *)
  val finish : t -> f:(Event.Line.t -> unit) -> unit
end
