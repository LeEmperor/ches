(** The history the Commits panel lists (phase 2; scopes, refs and the log popup in
    phase 8), from a bounded [git log]. *)

open! Core
open Ches_vcs

module Commit : sig
  type t =
    { hash : string (** Full. *)
    ; parents : string list (** Full hashes; [] for a root commit. *)
    ; author_name : string
    ; author_email : string
    ; author_time : int (** Unix seconds. *)
    ; refs : string list
    (** The refs pointing at it, as git decorates them ([%D], split on [", "]):
        e.g. [["HEAD -> main"; "origin/main"; "tag: v1"]]; [] for none. *)
    ; subject : string
    }
  [@@deriving sexp, equal]

  (** The first 7 characters of [hash]. *)
  val short_hash : t -> string
end

(** [Cli.read ~cwd] of [--literal-pathspecs log -z --no-color --no-show-signature
    --decorate=short --max-count=<limit> <order> <filters>
    --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s --end-of-options <revisions> --
    <path>]: seven NUL-separated fields per commit, each record NUL-terminated ([%P]
    and [%D] may be empty). [%D] needs no decorate flag (it is filled even with
    [log.decorate=no]), but follows [log.decorate=full] (full ref names) unless
    [--decorate=short] pins it. From [scope]:
    - [<order>]: [--topo-order] when {!Log_scope.graph_shown}; else nothing.
    - [<filters>]: [--no-merges] unless [merges]; [--first-parent] when
      [first_parent]; [--follow] with a [path].
    - [<revisions>]: [Head] [HEAD]; [Branch b] [refs/heads/<b>]; [All] [HEAD], with
      [--branches --remotes] added to [<filters>] (before [--end-of-options], which
      would make them revisions).
    - [-- <path>] with a path; [--] alone otherwise.
    [--follow] (checked on git 2.43) combines with [--first-parent] (a merge is then
    listed when its diff against its first parent changes the file) and with
    [--no-merges]. It follows one name for the whole walk, switching to the old name
    at the rename: when the rename was made on one side of a merge, edits under the
    old name on the other side are missing (without [--first-parent]).
    Raises if [scope.limit] is not positive. On an unborn branch git exits 128
    (["bad revision 'HEAD'"]); [Backend.snapshot] reads that as no commits. *)
val command : cwd:string -> Log_scope.t -> Exec.Spec.t

(** Parse stdout, newest first. [""] is no commits. A wrong field count, an empty
    hash, or a non-numeric time is an error, except that with [~cut:true] an
    incomplete final record is dropped. *)
val parse : cut:bool -> string -> Commit.t list Or_error.t

(** {2 The log popup (phase 8)} *)

(** Which log a popup action asks for. *)
module Target : sig
  type t =
    | Head (** [l] *)
    | Branch of string option (** [b]: the Branches panel's selected branch. *)
    | All (** [a] *)
    | File of string option (** [f]: a path relative to the root. *)
  [@@deriving sexp, equal]
end

module Choice : sig
  type t =
    { target : Target.t
    ; flags : string list (** The enabled switches' flags, in {!flags} order. *)
    }
  [@@deriving sexp, equal]
end

(** The popup [l] opens, for [branch] (the Branches panel's selected branch, if any)
    and [file] (the file the view offers, if any). Title ["Log"]. Switches, in order,
    no groups: [-g] ["--graph"] ["Show the graph"], [-m] ["--no-merges"] ["Omit
    merges"], [-p] ["--first-parent"] ["First parent only"]. Actions, in order: [l]
    ["Log HEAD"]; [b] ["Log <branch>"] (["Log a branch (select one in Branches
    first)"] with [None]); [a] ["Log all branches"]; [f] ["History of <file>"]
    (["History of a file (select one first)"] with [None]). Raw names. *)
val popup : branch:string option -> file:string option -> Choice.t Popup.t

(** {!popup}'s flags, in its order. *)
val flags : string list

(** The popup's flags that [scope] has on, in {!flags} order (what the popup opens
    with): ["--graph"] when [graph], ["--no-merges"] unless [merges],
    ["--first-parent"] when [first_parent]. *)
val enabled : Log_scope.t -> string list

(** The scope a choice asks for, with {!Log_scope.default_limit}: [Head] [Range.Head],
    [Branch (Some b)] [Range.Branch b], [All] [Range.All], [File (Some p)] [Range.Head]
    with [path = Some p]; [graph], [merges] and [first_parent] from [flags] (so
    [enabled (scope c) = c.flags] wherever the result is [Ok]). Errors, the
    refusal notice: [Branch None] ["Select a branch in Branches first"]; [File None]
    ["Select a file first: a Files item, or a file in the diff"]. *)
val scope : Choice.t -> (Log_scope.t, string) Result.t
