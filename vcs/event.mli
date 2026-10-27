(** What a runner reports to its consumer, in order. Plain data with no Async, so the
    UI state can name it (phase 2 adds a [Ui_state.Input] case carrying it, as
    [Ches_error.Source_event] is carried for diagnostic sources).

    Per job: for each [Run] step that starts, one [Started], then its [Output] lines
    (only if the spec streams), then, after the last step, exactly one [Finished].
    Jobs interleave freely. A job cancelled before any step started gets only its
    [Finished]. After the runner stops, nothing more is reported. *)

open! Core

module Line : sig
  type t =
    { text : string (** Without its terminator. Raw bytes, not sanitized. *)
    ; transient : bool
    (** Ended by a carriage return rather than a newline: a progress update (git's
        "Receiving objects: 45%") that the next line on the same stream replaces. A
        runner may drop a transient line that a later one already replaces. *)
    }
  [@@deriving sexp, equal]
end

type t =
  | Started of
      { job : Job.Id.t
      ; step : int (** Index into the job's steps, from 0. *)
      ; spec : Exec.Spec.t
      }
  | Output of
      { job : Job.Id.t
      ; step : int
      ; stream : Exec.Stream.t
      ; line : Line.t
      }
  | Finished of Job.Report.t
[@@deriving sexp, equal]

val job : t -> Job.Id.t
