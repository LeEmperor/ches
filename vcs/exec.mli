(** One external command a backend wants run, and what a runner hands back. A spec is
    data: an argument vector (never a shell string), extra environment, a working
    directory, and how the runner must treat it. Backends build specs; a runner
    ([Ches_vcs_host.Runner]) executes them; backends parse the results. *)

open! Core

module Kind : sig
  (** Ordered by consequence ([Read < Mutate < Network]), so a job's kind is the
      maximum of its steps' kinds.

      - [Read] never changes repository state the user can see. Reads may run
        concurrently with each other and with a mutation, and may be cancelled or
        superseded freely. Git reads also run with [GIT_OPTIONAL_LOCKS=0].
      - [Mutate] changes local state (index, work tree, refs, config). Mutations run
        one at a time, in submission order, and are never cancelled implicitly.
      - [Network] talks to a remote. Serialized with mutations (it may update refs and
        the work tree) and run with the runner's non-interactive authentication
        environment; see [Ches_vcs_host.Auth]. *)
  type t =
    | Read
    | Mutate
    | Network
  [@@deriving sexp, equal, compare, enumerate]

  (** The default timeout for [Spec.create]: [Read] 30 seconds, [Mutate] and [Network]
      10 minutes. *)
  val default_timeout : t -> Time_ns.Span.t
end

module Stdin : sig
  (** The child's standard input. Never the terminal: Ches owns it.

      - [Null]: end of file at once (the runner closes the pipe immediately), as if
        from [/dev/null].
      - [Data text]: [text] is written, then the pipe is closed (e.g. a patch for
        [git apply --cached] in phase 3). *)
  type t =
    | Null
    | Data of string
  [@@deriving sexp, equal]
end

module Stream : sig
  type t =
    | Stdout
    | Stderr
  [@@deriving sexp, equal, compare]
end

module Spec : sig
  type t =
    { prog : string (** Looked up on [PATH] unless it contains a ['/']. *)
    ; args : string list (** Arguments after [prog], passed verbatim. *)
    ; cwd : string (** Absolute working directory. *)
    ; env : (string * string) list
    (** Set over the inherited environment, later entries winning. The runner may
        still add or force entries for the kind (authentication); see
        [Ches_vcs_host.Auth]. *)
    ; kind : Kind.t
    ; stdin : Stdin.t
    ; timeout : Time_ns.Span.t option
    (** From the child's start. On expiry the runner terminates it (and its process
        group) and reports [timed_out]. [None] waits until it exits or is cancelled. *)
    ; stdout_limit : int
    (** Bytes of stdout kept: the first [stdout_limit]. Beyond it a [Read] child is
        terminated (its prefix is still the answer; see {!Result.t}); other kinds keep
        running and the excess is discarded. *)
    ; stderr_limit : int
    (** Bytes of stderr kept: the last [stderr_limit] (the end holds the error). *)
    ; stream : bool
    (** Also report output while the child runs, line by line, as
        {!Event.Output} (progress of long or network commands). The collected
        result is the same either way. *)
    }
  [@@deriving sexp, equal]

  val default_stdout_limit : int (** 32 MiB *)

  val default_stderr_limit : int (** 64 KiB *)

  (** [create ~kind ~cwd prog args] with the defaults: no extra environment, [Null]
      stdin, {!Kind.default_timeout}, the default limits, and no streaming. *)
  val create
    :  ?env:(string * string) list
    -> ?stdin:Stdin.t
    -> ?timeout:Time_ns.Span.t option
    -> ?stdout_limit:int
    -> ?stderr_limit:int
    -> ?stream:bool
    -> kind:Kind.t
    -> cwd:string
    -> string
    -> string list
    -> t

  (** [prog :: args]. *)
  val argv : t -> string list

  (** The command line for the command log and notices, e.g.
      [git --no-pager status --porcelain=v2 -z]. Arguments that are empty or contain
      anything outside [[A-Za-z0-9_@%+=:,./-]] are single-quoted shell-style
      (embedded quotes as ['\'']); control bytes are shown as [\xNN]. For display only:
      runners never pass it to a shell. Environment and cwd are not shown. *)
  val to_string_hum : t -> string
end

module Status : sig
  (** How the child ended, as far as the runner knows. *)
  type t =
    | Exited of int
    | Signaled of string (** The signal's name, e.g. ["sigterm"]. *)
    | Not_started of string
    (** It never ran: the program was not found, [cwd] is missing, fork failed. The
        message names the cause. *)
  [@@deriving sexp, equal]
end

module Result : sig
  type t =
    { status : Status.t
    ; stdout : string
    ; stdout_truncated : bool (** More stdout than [stdout_limit] was produced. *)
    ; stderr : string
    ; stderr_truncated : bool (** Earlier stderr was dropped to keep the tail. *)
    ; timed_out : bool (** The runner terminated it at its timeout. *)
    ; cancelled : bool
    (** The runner terminated it on request (job cancelled, superseded, or runner
        stopped). *)
    ; elapsed : Time_ns.Span.t (** From start to exit (zero if [Not_started]). *)
    }
  [@@deriving sexp, equal]

  (** [Exited 0] and neither timed out nor cancelled. *)
  val succeeded : t -> bool

  (** Whether [status] is [Exited] with one of [codes], and neither timed out nor
      cancelled; e.g. [git diff --no-index] reports differences as exit 1. *)
  val exited_with : t -> int list -> bool

  (** For a [Read] spec whose stdout reached its limit: the runner stopped the child,
      so [status] is usually [Signaled], but [stdout] is a valid prefix the parser may
      use (marking its answer truncated). [stdout_truncated] and not timed out or
      cancelled. *)
  val cut_at_limit : t -> bool

  (** One line for notices and the command log: ["exit 1"], ["killed by sigterm"],
      ["timed out after 30s"], ["cancelled"], ["could not start: ..."]. *)
  val status_hum : t -> string
end
