(** Runs {!Ches_vcs.Job.t}s as child processes and reports {!Ches_vcs.Event.t}s, for
    one consumer. Owned by the frontend (phase 2: [ches_ui]), like a diagnostic
    [Ches_source.Source.t]: the UI transition hands jobs out as data, the frontend
    {!submit}s them, and pumps {!next_batch} into [Ui_state] inputs. The runner never
    touches UI state and never decides staleness: it echoes job ids, and the consumer
    drops what {!Ches_vcs.Stamps} says is stale.

    Scheduling:
    - [Read] jobs start at once. Their steps are independent and run concurrently, at
      most [max_concurrent_reads] child processes across all read jobs (file reads
      need no slot). Reads overlap a running mutation: git reads run with
      [GIT_OPTIONAL_LOCKS=0] and the consumer refreshes after every mutation, so a
      read that saw a half-done mutation is superseded. Serializing reads behind a
      push would freeze the view for the length of the push.
    - Submitting a job with a lane cancels every earlier queued or running job of that
      lane (each reported [Finished] with [cancelled = true]).
    - [Mutate] and [Network] jobs form one queue: first in, first out, one job at a
      time, steps in order, stopping at the first step that does not succeed (the rest
      [Skipped]). They are never cancelled except by {!cancel} or {!stop}.

    Each command step:
    - runs [spec.prog] with [spec.args] (no shell) in [spec.cwd], in a new process
      group, with environment {!Auth.environment} over [inherited] overlaid with
      [spec.env];
    - stdin per {!Ches_vcs.Exec.Stdin.t}: a pipe that is closed at once ([Null]) or
      after writing the data, never the terminal;
    - keeps the first [stdout_limit] bytes of stdout and the last [stderr_limit] of
      stderr; a [Read] child whose stdout passes its limit is terminated, other kinds
      are drained to the end;
    - with [spec.stream], reports each stdout and stderr line as it arrives
      ({!Ches_vcs.Event.Output}): lines end at ['\n'] or ['\r'] (the latter
      [transient]); a final unterminated line is reported at end of file; a line over
      4 KiB is reported in 4 KiB pieces. A transient line may be dropped when a later
      line of the same step and stream is already pending;
    - is terminated at [spec.timeout] ([timed_out]) or on cancellation
      ([cancelled]).
    A [Network] step first runs the [core.sshCommand] probe
    ({!Auth.ssh_command_probe}, in [spec.cwd], like a read, with no events of its
    own); its [Started] is reported after the probe, just before the child starts. A
    job cancelled during the probe reports no [Started] for that step, which is
    [Skipped].

    Terminating a child means SIGTERM to its process group (git removes its lock files
    on SIGTERM; SIGKILL would leave [index.lock] behind), then SIGKILL to the group
    after [termination_grace] if it has not exited. A [Not_started] child (missing
    program, missing cwd) is reported like any other result, after its [Started]
    event.

    Failures of any kind are reported in results, never raised: no exception escapes
    to the caller or to the Async monitor. *)

open! Core
open! Async
open Ches_vcs

module Config : sig
  type t =
    { max_concurrent_reads : int (** Positive. Default 4. *)
    ; termination_grace : Time_ns.Span.t (** Non-negative. Default 2 seconds. *)
    ; max_batch : int (** Events per {!next_batch}; positive. Default 64. *)
    }
  [@@deriving sexp_of]

  val default : t
end

type t

(** [inherited] is the base environment of every child; default this process's
    environment when [create] is called. Tests pass the fixture's
    ([Ches_vcs_fixture.Fixture_repo.environment]). Raises on an invalid config. *)
val create : ?config:Config.t -> ?inherited:(string * string) list -> unit -> t

(** Queue or start a job, per the scheduling rules above. A job whose id was submitted
    before is reported at once as {!Ches_vcs.Job.never_started}. After {!stop}, does
    nothing. *)
val submit : t -> Job.t -> unit

(** Cancel a queued or running job: queued, it is reported as never started; running,
    its child is terminated and its remaining steps are [Skipped], then it is reported
    with [cancelled = true]. Unknown or finished ids are ignored. *)
val cancel : t -> Job.Id.t -> unit

(** The pending events, at most [max_batch] and oldest first, once there is at least
    one. Not to be called again before the previous result is determined. Never
    determined after {!stop}. *)
val next_batch : t -> Event.t list Deferred.t

(** The pending events now (at most [max_batch]), without waiting. *)
val poll : t -> Event.t list

(** Whether any job is queued or running. *)
val busy : t -> bool

(** Ches is quitting. Idempotent. Every queued job is dropped and every running child
    terminated, with no further events: pending events are discarded and
    {!next_batch} is never determined again. *)
val stop : t -> unit

(** Determined once {!stop} was called and every child has been reaped. *)
val finished : t -> unit Deferred.t
