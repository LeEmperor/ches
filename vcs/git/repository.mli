(** Finding the repository that contains a directory. *)

open! Core
open Ches_vcs

type t =
  { root : string (** Absolute work-tree root ([--show-toplevel]): every command's cwd. *)
  ; git_dir : string
  (** Absolute ([--absolute-git-dir]); in a linked worktree, that worktree's own
      directory (where its [MERGE_HEAD] and [rebase-merge/] live). *)
  }
[@@deriving sexp, equal]

val root : t -> string

(** One step: [Cli.read ~cwd ["rev-parse"; "--show-toplevel"; "--absolute-git-dir"]]. *)
val detect : cwd:string -> Job.Step.t list

(** From [detect]'s report:
    - exit 0 with exactly two non-empty lines: [Found] (a path containing a newline
      cannot be represented: [Failed]);
    - exit 128 with stderr containing ["not a git repository"]: [Not_a_repository];
    - exit 128 with stderr containing ["must be run in a work tree"] (a bare
      repository, or [cwd] inside a [.git] directory): [No_work_tree] with the
      stderr's first line;
    - anything else, including git missing ([Not_started]), a timeout, or "dubious
      ownership": [Failed] with the command line, {!Exec.Result.status_hum} and the
      stderr, e.g. ["git --no-pager ... rev-parse ...: exit 128: fatal: ..."].
    A report that does not have exactly the one [Ran] step is [Failed]. *)
val detected
  :  cwd:string
  -> Job.Step_report.t list
  -> t Ches_vcs.Backend.Detection.t
