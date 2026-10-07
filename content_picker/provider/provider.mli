open! Core
open! Async
module Limits : sig
  type t =
    { max_hits : int; max_record_bytes : int; max_text_bytes : int
    ; max_payload_bytes : int; max_output_bytes : int; batch_size : int
    ; timeout : Time_ns.Span.t; debounce : Time_ns.Span.t }
  val default : t
end
type t
type run
(** Async-scheduler API. Reuse one provider per host; at most one child and one
    queued batch. Replacement kills/reaps old child before spawning another.
    Defaults: 150ms debounce, 10s timeout including backpressure, 10k hits,
    64KiB JSON record, 4KiB raw line/path, 8MiB retained strings, 32MiB output,
    batches of 128. Overhead/decoded JSON/transient batches are additional.
    Empty query never launches rg. Whitespace is a literal, not a blank query. *)
val create : ?prog:string -> ?limits:Limits.t -> unit -> t
val start : t -> root:string -> query:string -> run Or_error.t
val request : run -> Ches_content_picker.Model.request
val finished : run -> unit Deferred.t
val cancel : t -> unit
val poll : t -> max_batches:int -> Ches_content_picker.Model.snapshot option
val snapshot : t -> Ches_content_picker.Model.snapshot option
