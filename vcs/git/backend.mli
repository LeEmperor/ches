(** The git backend: {!Ches_vcs.Backend.S} over the parsers of this library.

    Panels, in order:
    - Files (["files"]): sections Conflicted, Untracked, Unstaged, Staged (and Ignored
      when {!Ches_vcs.Backend.Refresh.t} asks for it), empty sections omitted. Item
      keys are paths (a rename's new path). A [Changed] or [Renamed_or_copied] entry
      appears in Staged when its index side changed and in Unstaged when its work-tree
      side changed (both for a partially staged file); [Unmerged] in Conflicted;
      [Untracked] and [Ignored] in theirs. Entries keep git's order.
    - Branches (["branches"]): one section ["local"], keyed by branch name.
    - Commits (["commits"]): one section ["recent"], keyed by full hash.

    Actions arrive with the phases that need them (stage/unstage/discard in 3, line
    staging in 4, commit in 5, push/pull/fetch/checkout in 6); phase 1 has none. *)

open! Core
open Ches_vcs

module Section : sig
  type t =
    | Conflicted
    | Untracked
    | Unstaged
    | Staged
    | Ignored
  [@@deriving sexp, equal, compare, enumerate]

  (** ["conflicted"], ["untracked"], ["unstaged"], ["staged"], ["ignored"]. *)
  val id : t -> Panel.Section_id.t

  val of_id : Panel.Section_id.t -> t option

  (** ["Conflicted"], ["Untracked files"], ["Unstaged changes"], ["Staged changes"],
      ["Ignored files"]. *)
  val title : t -> string
end

(** ["files"], ["branches"], ["commits"]. *)
val files_panel : Panel.Id.t

val branches_panel : Panel.Id.t
val commits_panel : Panel.Id.t

type snapshot =
  { repository : Repository.t
  ; refresh : Ches_vcs.Backend.Refresh.t
  ; status : Status.t
  ; branches : Branch_list.Branch.t list
  ; commits : Log.Commit.t list
  ; operations : In_progress.t list
  ; problems : string list
  (** Lesser failures the view should show (a failed branch list or log, a failed
      state-file read), each with the command line and stderr. *)
  }
[@@deriving sexp_of]

type item =
  | File of
      { section : Section.t
      ; entry : Status.Entry.t
      }
  | Branch of Branch_list.Branch.t
  | Commit of Log.Commit.t
[@@deriving sexp_of]

type diff_target =
  | Unstaged of string list (** Paths; [] = all unstaged changes. *)
  | Staged of string list
  (** Paths; [] = all staged changes. A staged rename gives [[original; path]]. *)
  | Untracked of string
  | Conflicted of string list (** Paths; combined diffs. *)
  | Commit of string (** Full hash. *)
[@@deriving sexp, equal]

(** Empty in phase 1: later phases add constructors with their command plans. *)
type action = | [@@deriving sexp_of]

(** Contract details beyond {!Ches_vcs.Backend.S}:

    - [name] is ["git"]; [Repository] is {!Ches_vcs_git.Repository}.
    - [detect]/[detected]: {!Repository.detect}/{!Repository.detected}.
    - [refresh repo r]: [Run (Status.command ~ignored:r.ignored)],
      [Run Branch_list.command], [Run (Log.command ~limit:r.log_limit)], then
      [Read_file] of every {!In_progress.reads} of [repo.git_dir]; all in
      [repo.root].
    - [snapshot]: Error if the status step did not succeed (or its output does not
      parse), with the command line, status and stderr. A failed branch list or
      in-progress read adds a [problems] entry and gives [[]]. A failed log gives
      [[]], with a [problems] entry unless the status says there is no commit yet
      ([branch.oid (initial)]). Output cut at its limit ({!Exec.Result.cut_at_limit})
      parses with [~cut:true].
    - [summary]: branch and revision (7 characters) from the status headers; upstream
      from [branch.upstream] and [branch.ab], [gone] when the current branch's
      {!Branch_list.Tracking.t} is [Gone] (then ahead and behind are 0);
      [operations] by {!In_progress.describe}.
    - [diff_target]: Files headers: Unstaged -> [Unstaged []], Staged -> [Staged []],
      Conflicted -> [Conflicted] of all its paths, Untracked and Ignored -> [None].
      Files items: Unstaged -> [Unstaged [path]], Staged -> [Staged [path]] (or
      [[original; path]] for a rename or copy), Untracked -> [Untracked path], except
      [None] for a key ending in ["/"] (a nested repository or an untracked
      directory, which [diff --no-index] cannot show), Conflicted -> [Conflicted
      [path]], Ignored -> [None]. Commits items -> [Commit
      hash]; Branches rows and the Commits header -> [None]. Unknown panels or rows ->
      [None].
    - [diff]: one [Run] of {!Diff_output.command}: [Unstaged]/[Conflicted] ->
      [Worktree], [Staged] -> [Index], [Untracked] -> [Untracked], [Commit] ->
      [Commit].
    - [parse_diff]: Error unless the step exited with one of
      {!Diff_output.ok_exits} or was cut at its limit; then {!Diff_output.parse}.
    - [plan]: no actions yet. *)
include
  Ches_vcs.Backend.S
  with type Repository.t = Repository.t
   and type Snapshot.t = snapshot
   and type Item.t = item
   and type Diff_target.t = diff_target
   and type Action.t = action
