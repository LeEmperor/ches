(** Test-only git fixtures: a repository in a fresh temporary directory, isolated from
    the user's configuration and from any repository around it, optionally with a
    local bare "remote". Never touches the Ches repository and never contacts a
    network. Synchronous (Core_unix), so both pure tests and Async tests can use it;
    an Async test calls it between binds (each call blocks briefly on git).

    Isolation (see {!environment}): [GIT_CONFIG_GLOBAL=/dev/null],
    [GIT_CONFIG_NOSYSTEM=1], the identity [Ches Test <ches-test@example.invalid>] for
    author and committer, fixed author and committer dates (so commit hashes are
    reproducible), [HOME] set to the fixture's directory, [GIT_CEILING_DIRECTORIES]
    at the fixture's directory, [GIT_TERMINAL_PROMPT=0], [LC_ALL=C], and every
    variable that redirects git ([GIT_DIR], [GIT_WORK_TREE], [GIT_INDEX_FILE],
    [GIT_OBJECT_DIRECTORY], ...) removed. *)

open! Core

type t =
  { dir : string (** The temporary directory holding everything below. *)
  ; work : string (** The repository's work tree: [dir/work]. *)
  ; remote : string option (** A bare repository [dir/remote.git], as [origin]. *)
  }
[@@deriving sexp_of]

(** A new repository on branch [main] with no commits, and with [~remote:true] an
    empty bare repository added as remote [origin] (by path). *)
val create : ?remote:bool -> unit -> t

(** Delete [dir] recursively. Idempotent. *)
val remove : t -> unit

(** [create], [f], then [remove] even if [f] raises. *)
val with_repo : ?remote:bool -> (t -> 'a) -> 'a

(** The complete environment fixture children run with: this process's environment,
    minus the variables that redirect git, plus the isolation above. Pass it as the
    inherited environment of a runner under test ([Ches_vcs_host.Runner.create]). *)
val environment : t -> (string * string) list

(** An absolute path inside the work tree. *)
val path : t -> string -> string

(** Write a work-tree file, creating parent directories. *)
val write : t -> string -> string -> unit

(** A new empty directory under [dir] outside the repository, e.g. to detect "not a
    repository" from it. Returns its absolute path. *)
val plain_dir : t -> string -> string

(** Run [git args] in [cwd] (default the work tree) with {!environment}; return
    stdout. Raises with the command line, status and stderr unless it exits 0. *)
val git : ?cwd:string -> t -> string list -> string

(** [git add -A] then [git commit -q -m message]. Returns the new commit's hash. *)
val commit_all : t -> string -> string

(** Run steps synchronously, the way a runner would but without timeouts or
    streaming, for backend tests that need real git output without Async. Commands
    run with {!environment} overlaid with the spec's [env]; stdin is [/dev/null] or
    the spec's data; output limits are applied as {!Ches_vcs.Exec.Spec.t} documents
    (stdout's head, stderr's tail; the child is never stopped early); a program that
    cannot start gives [Not_started]. File reads follow
    {!Ches_vcs.Job.File_read.Result.t}. Every step runs, in order. *)
val run_steps : t -> Ches_vcs.Job.Step.t list -> Ches_vcs.Job.Step_report.t list

(** [run_steps] of one command. *)
val run : t -> Ches_vcs.Exec.Spec.t -> Ches_vcs.Exec.Result.t
