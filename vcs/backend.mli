(** What a VCS backend (git now; Mercurial or jj later) provides to the
    backend-agnostic view. A backend is pure: it turns requests into job steps
    ({!Job.Step.t}) and turns the runner's step reports back into values. It never runs
    anything itself, and owns every backend-specific notion: its panels' sections and
    item kinds, its diff targets, its actions (git's stage and unstage live in
    [Ches_vcs_git]) and, from phase 5, its popups.

    Every [parse]-like function below takes the [Job.Report.steps] of a job built
    from exactly the steps the matching request function returned, in the same order.
    The consumer drops cancelled and stale reports ({!Stamps}) before parsing; a
    report with a [Skipped] step parses to an error. *)

open! Core

module Detection : sig
  type 'repository t =
    | Found of 'repository
    | Not_a_repository of { cwd : string }
    (** The view says so plainly (phase 2); not an error. *)
    | No_work_tree of { cwd : string; message : string }
    (** A repository without a work tree here: bare, or [cwd] inside its metadata
        directory. *)
    | Failed of string
    (** Could not tell: the tool is missing, timed out, or refused (git's "dubious
        ownership"). The message carries the command line and stderr. *)
  [@@deriving sexp_of]
end

module Refresh : sig
  (** What a refresh reads, beyond what every refresh reads. *)
  type t =
    { ignored : bool (** Also list ignored files. *)
    ; log_limit : int (** Commits read for the Commits panel. *)
    }
  [@@deriving sexp, equal]

  (** No ignored files, 200 commits. *)
  val default : t
end

module Summary : sig
  (** The head summary above the panels. *)
  module Upstream : sig
    type t =
      { name : string (** e.g. ["origin/main"] *)
      ; ahead : int
      ; behind : int
      ; gone : bool (** Configured, but the remote branch no longer exists. *)
      }
    [@@deriving sexp, equal]
  end

  type t =
    { branch : string option (** [None] when detached. *)
    ; revision : string option
    (** The abbreviated commit HEAD names; [None] before the first commit. *)
    ; upstream : Upstream.t option
    ; operations : string list
    (** Operations in progress, most significant first, as the summary shows them:
        ["Merging"], ["Rebasing main onto 1a2b3c4"], ["Cherry-picking 5d6e7f8"]. *)
    }
  [@@deriving sexp, equal]
end

module Plan : sig
  (** The command plan for one action. The consumer submits [steps] as one job, then
      refreshes, whatever the outcome. *)
  type t =
    { title : string (** For the command log and notices, e.g. ["Stage a.txt"]. *)
    ; steps : Job.Step.t list
    ; rewrites_worktree : bool
    (** It may rewrite work-tree files (discard, checkout, pull): refused while a Ches
        file buffer inside the repository is dirty, and followed by open-buffer
        reconciliation. *)
    }
  [@@deriving sexp_of]

  module Decision : sig
    type plan := t

    type t =
      | Run of plan
      | Confirm of
          { title : string
          ; message : string
          ; plan : plan
          }
      (** Destructive: ask first (default No; phase 0C's confirmation float). *)
      | Refused of string (** Not possible now, e.g. "Nothing staged to commit". *)
    [@@deriving sexp_of]
  end
end

module type S = sig
  (** Short and lowercase, e.g. ["git"]: shown in notices and the command log. *)
  val name : string

  module Repository : sig
    type t [@@deriving sexp_of, equal]

    (** The absolute work-tree root: the cwd of the repository's commands, and what
        file paths in snapshots are relative to. *)
    val root : t -> string
  end

  (** Everything one refresh read. *)
  module Snapshot : sig
    type t [@@deriving sexp_of]
  end

  (** What the panels hold (git: a status entry in its section, a branch, a
      commit). *)
  module Item : sig
    type t [@@deriving sexp_of]
  end

  (** What the diff panel shows for a selection (git: unstaged or staged changes of
      some paths, an untracked file, a conflicted file, a commit). Equal targets
      show the same diff, so the view refetches only when the target changes or
      after a refresh. *)
  module Diff_target : sig
    type t [@@deriving sexp_of, equal]
  end

  (** Everything the user can ask the backend to change. Grows with the phases that
      introduce actions (stage in 3, commit in 5, push in 6). *)
  module Action : sig
    type t [@@deriving sexp_of]
  end

  (** Steps that find the repository containing [cwd] (absolute). *)
  val detect : cwd:string -> Job.Step.t list

  val detected : cwd:string -> Job.Step_report.t list -> Repository.t Detection.t

  (** Steps that read everything the panels and head summary show. Read only. *)
  val refresh : Repository.t -> Refresh.t -> Job.Step.t list

  (** Fails when a step without which nothing can be shown failed (git: status);
      lesser failures degrade the snapshot as the backend documents. *)
  val snapshot
    :  Repository.t
    -> Refresh.t
    -> Job.Step_report.t list
    -> Snapshot.t Or_error.t

  val summary : Snapshot.t -> Summary.t

  (** In display order. Each satisfies {!Panel.validate}. *)
  val panels : Snapshot.t -> Item.t Panel.t list

  (** The diff for a selected row of a panel, if it has one. *)
  val diff_target : Snapshot.t -> Panel.Id.t -> Panel.Position.t -> Diff_target.t option

  (** Steps that read a target's diff. Read only. *)
  val diff : Repository.t -> Diff_target.t -> Job.Step.t list

  val parse_diff
    :  Diff_target.t
    -> Diff.Limits.t
    -> Job.Step_report.t list
    -> Diff.t Or_error.t

  (** The plan for an action against the snapshot it was chosen in. *)
  val plan : Repository.t -> Snapshot.t -> Action.t -> Plan.Decision.t
end
