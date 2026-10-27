(** A unit of work submitted to a runner: an identity stamped by the consumer, an
    optional lane, and steps (commands, or reads of small metadata files such as
    git's [MERGE_HEAD]). The runner reports each job once, as a {!Report.t}, with
    every step paired with its outcome in step order.

    How a runner executes a job depends on its {!kind}:
    - A [Read] job's steps are independent: they may run concurrently, and all of
      them run even when one fails. Read jobs may overlap each other and a mutation.
    - A [Mutate] or [Network] job joins the single mutation queue (first in, first
      out, one job at a time). Its steps run in order and stop at the first step that
      does not succeed ({!Step_report.succeeded}); the rest are [Skipped]. It is never
      cancelled implicitly, only by {!Id} or when the runner stops. *)

open! Core

module Id : sig
  (** Issued by the consumer (see {!Stamps}), echoed by the runner. [generation]
      changes when everything earlier becomes stale (the VCS view reopened on another
      repository); [sequence] increases with every job the consumer issues, across
      generations, so ids are unique per consumer. *)
  type t =
    { generation : int
    ; sequence : int
    }
  [@@deriving sexp, equal, compare]

  include Comparable.S_plain with type t := t

  (** ["g<generation>.<sequence>"] *)
  val to_string_hum : t -> string
end

module File_read : sig
  (** Read a small file whole, e.g. git's [<git-dir>/rebase-merge/head-name]. A
      backend uses it to learn state its tool keeps in files rather than reports by
      command, without a process per file. *)
  type t =
    { path : string (** Absolute. *)
    ; limit : int (** Bytes kept, from the start; positive. *)
    }
  [@@deriving sexp, equal]

  module Result : sig
    type t =
      | Missing (** No such file ([ENOENT] or [ENOTDIR]): an answer, not a failure. *)
      | Contents of
          { text : string
          ; truncated : bool (** The file was longer than [limit]. *)
          }
      | Failed of string (** Any other error (permission, a directory, ...). *)
    [@@deriving sexp, equal]
  end
end

module Step : sig
  type t =
    | Run of Exec.Spec.t
    | Read_file of File_read.t
  [@@deriving sexp, equal]

  (** The spec's kind; a file read is [Read]. *)
  val kind : t -> Exec.Kind.t

  module Outcome : sig
    type t =
      | Ran of Exec.Result.t
      | Read of File_read.Result.t
      | Skipped
      (** Not attempted: an earlier step of a mutation failed, or the job was cancelled
          before this step started. *)
    [@@deriving sexp, equal]
  end
end

module Step_report : sig
  type t =
    { step : Step.t
    ; outcome : Step.Outcome.t
    }
  [@@deriving sexp, equal]

  (** A command that {!Exec.Result.succeeded}, or a file read that found the file
      or found it [Missing]. [Skipped] and [Failed] reads do not succeed. *)
  val succeeded : t -> bool
end

type t = private
  { id : Id.t
  ; lane : string option
  (** Read jobs only. At most one job per lane is wanted at a time: submitting a job
      cancels any earlier queued or running job of the same lane (the selection's diff
      while the user moves quickly, a refresh replaced by another). *)
  ; steps : Step.t list
  }
[@@deriving sexp_of]

(** Fails on no steps, an empty lane, a lane on a job whose kind is not [Read], a
    spec whose [cwd] is not absolute or whose limits are not positive, or a file read
    whose path is not absolute or whose limit is not positive. *)
val create : id:Id.t -> ?lane:string -> Step.t list -> t Or_error.t

(** The maximum of its steps' kinds. *)
val kind : t -> Exec.Kind.t

module Report : sig
  type t =
    { id : Id.t
    ; lane : string option
    ; kind : Exec.Kind.t
    ; steps : Step_report.t list (** Every step of the job, in order. *)
    ; cancelled : bool
    (** Cancelled by id, superseded in its lane, or the runner stopped before it
        finished; steps that had not started are [Skipped]. *)
    }
  [@@deriving sexp, equal]

  (** Every step succeeded and the job was not cancelled. *)
  val succeeded : t -> bool

  (** The first step that did not succeed, if any. *)
  val first_failure : t -> Step_report.t option
end

(** The report a runner gives a job it never started (cancelled while queued, or
    submitted after the runner stopped): every step [Skipped], [cancelled = true]. *)
val never_started : t -> Report.t
