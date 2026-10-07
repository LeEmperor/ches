open! Core
open! Async
module Model = Ches_file_picker.Model

module Limits : sig
  type t =
    { max_candidates : int
    ; max_path_bytes : int
    ; max_total_path_bytes : int
    ; max_output_bytes : int
    ; batch_size : int
    ; timeout : Time_ns.Span.t
    }

  (** 50,000 candidates, 4 KiB/path, 8 MiB retained candidate string payload
      (root, absolute, relative and escaped display paths), 32 MiB output,
      batches of 128, 30 seconds wall time (including delivery backpressure). *)
  val default : t
end

type t
type run

(** [prog] is an executable, never a shell command; defaults to [rg]. Override
    only for testing or an explicitly configured ripgrep executable. Calls must
    be made on the Async scheduler. One active run and one pending batch per
    provider; hosts should reuse a provider across refreshes. *)
val create : ?prog:string -> ?limits:Limits.t -> unit -> t

(** Cancels the previous run, allocates a fresh identity, and returns immediately
    in Loading state. Absolute roots only, at most 4 KiB. Traversal occurs in the
    subprocess and stream reads are asynchronous. A failed launch is delivered
    as Failed with installation guidance. *)
val start : t -> root:string -> run Or_error.t
val request : run -> Model.Discovery.request

(** Kill/close delivery immediately; [finished] acknowledges descriptor closure
    and child reaping, including cancellation during process creation. *)
val cancel : t -> unit
val finished : run -> unit Deferred.t

(** Consume at most [max_batches] batches, rejecting obsolete run/root deliveries.
    Candidate snapshots are deduplicated and sorted by raw relative path bytes.
    No change returns None. Hosts must poll in bounded turns; there are no worker
    callbacks into editor state. A terminal snapshot may retain partial results.
    Metadata-only changes preserve the candidate list identity, allowing sessions
    to avoid reranking unchanged candidates.
    Truncation must be shown by the future tile, never treated as exhaustive. *)
val poll : t -> max_batches:int -> Model.Discovery.t option
val snapshot : t -> Model.Discovery.t option
