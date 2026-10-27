(** The frontend's runner for the jobs registered views submit (phase 2: the VCS
    view's git commands): one {!Ches_vcs_host.Runner.t} for the whole UI, owned like
    a diagnostic [Ches_source.Source.t]. {!Editor_view} submits what
    [Ches_screen.Ui_state.take_vcs_jobs] hands out after each transition, pumps
    {!next_inputs} into the state machine as one batch of [Ui_state.Input.Vcs]
    inputs at a time (never asking again before the previous batch is determined),
    stops it when the editor exits, and {!shutdown}s it after the terminal closes so
    git can drop its lock files. Job ids are unique among the jobs in flight
    ([Ui_state] guarantees it), so one runner serves every view. Staleness is the
    views' to decide; this module drops nothing. *)

open! Core
open! Async

type t

(** [config] and [inherited] as for {!Ches_vcs_host.Runner.create} (default: the
    runner's defaults and this process's environment). Tests pass the fixture's
    environment ([Ches_vcs_fixture.Fixture_repo.environment]). *)
val create
  :  ?config:Ches_vcs_host.Runner.Config.t
  -> ?inherited:(string * string) list
  -> unit
  -> t

(** Submit jobs, in order. After {!stop}, does nothing. *)
val submit : t -> Ches_vcs.Job.t list -> unit

(** The next batch of the runner's events ({!Ches_vcs_host.Runner.next_batch}), each
    as [Ui_state.Input.Vcs], oldest first, once there is at least one. Not to be
    called again before the previous result is determined; never determined after
    {!stop}, so a pump loop must not hold exit open. *)
val next_inputs : t -> Ches_screen.Ui_state.Input.t list Deferred.t

(** Whether any submitted job is still queued or running. *)
val busy : t -> bool

(** The editor is exiting. Idempotent: queued jobs are dropped, running children
    terminated (SIGTERM to the group, SIGKILL after the grace), and no more events
    are delivered. *)
val stop : t -> unit

(** {!stop}, then wait until every child is reaped, at most [cap] (default 3 s: the
    runner's 2 s termination grace plus reaping). *)
val shutdown : ?cap:Time_ns.Span.t -> t -> [ `Finished | `Timed_out ] Deferred.t
