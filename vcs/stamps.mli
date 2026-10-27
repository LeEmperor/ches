(** The consumer's side of generation stamps: issuing {!Job.Id.t}s and deciding
    whether a runner's report (or a [Started]/[Output] event) is still wanted. The
    runner only echoes ids; dropping stale results is the consumer's job, as
    [Ui_state] rejects stale file-picker turns.

    A result is current when it belongs to the current generation and, for a job with
    a lane, it is the latest job issued in that lane. So a refresh that was overtaken
    by a later refresh (or by {!invalidate}, e.g. the view moved to another
    repository) is dropped even if its runner did not cancel it in time.

    Mutation reports should still be logged when stale (the command did run); only
    their effects on the view are dropped. Immutable. *)

open! Core

type t [@@deriving sexp_of, equal]

(** Generation 0, nothing issued. *)
val create : unit -> t

val generation : t -> int

(** A new generation: every id issued so far becomes stale. Sequences keep
    increasing, so ids stay unique. *)
val invalidate : t -> t

(** The next id, in the current generation. With [lane], it becomes that lane's
    latest, so earlier jobs of the lane are no longer current. Pass the same lane to
    {!Job.create}. *)
val issue : ?lane:string -> t -> t * Job.Id.t

(** The lane's latest id in the current generation. *)
val latest : t -> lane:string -> Job.Id.t option

(** Whether a result for [id], submitted with [lane], is still wanted. *)
val is_current : t -> ?lane:string -> Job.Id.t -> bool

(** [is_current] on a report's id and lane. *)
val accepts : t -> Job.Report.t -> bool
