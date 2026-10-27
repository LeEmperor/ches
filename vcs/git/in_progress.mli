(** Operations in progress (merge, rebase, am, cherry-pick, revert, bisect), detected
    the way git itself and Magit do: by the state files in the git directory. They
    are read as {!Ches_vcs.Job.File_read.t} steps, so no process runs per file. *)

open! Core
open Ches_vcs

type t =
  | Rebase of
      { interactive_backend : bool
      (** [rebase-merge/] (the merge backend, also for [-i]); [false] for
          [rebase-apply/]. *)
      ; branch : string option
      (** From [head-name], without [refs/heads/]; [None] for ["detached HEAD"]. *)
      ; onto : string option (** Full hash from [onto]. *)
      }
  | Apply_mailbox (** [git am]: [rebase-apply/applying] exists. *)
  | Merge of { head : string option } (** First line of [MERGE_HEAD]. *)
  | Cherry_pick of { commit : string option } (** [CHERRY_PICK_HEAD]. *)
  | Revert of { commit : string option } (** [REVERT_HEAD]. *)
  | Bisect (** [BISECT_LOG]. *)
[@@deriving sexp, equal]

(** Reads of [<git_dir>/]: [rebase-merge/head-name], [rebase-merge/onto],
    [rebase-apply/head-name], [rebase-apply/onto], [rebase-apply/applying],
    [MERGE_HEAD], [CHERRY_PICK_HEAD], [REVERT_HEAD], [BISECT_LOG], in that order, each
    with a 4096-byte limit. *)
val reads : git_dir:string -> Job.File_read.t list

(** From the outcomes of exactly {!reads} (paired, in order). Most significant first:
    [Rebase] or [Apply_mailbox] (if [rebase-merge/head-name] or [rebase-apply/head-name]
    exists, or [applying] does), then [Merge], [Cherry_pick], [Revert], [Bisect].
    Contents are stripped of surrounding whitespace; a hash field that is empty after
    stripping is [None]. A [Failed] read, or reads not matching {!reads}, is an
    error. *)
val parse
  :  git_dir:string
  -> (Job.File_read.t * Job.File_read.Result.t) list
  -> t list Or_error.t

(** For the head summary: ["Rebasing main onto 1a2b3c4"] (["Rebasing detached HEAD"],
    or without ["onto ..."] when unknown), ["Applying patches"], ["Merging 1a2b3c4"]
    (or ["Merging"]), ["Cherry-picking 1a2b3c4"], ["Reverting 1a2b3c4"], ["Bisecting"].
    Hashes shortened to 7 characters. *)
val describe : t -> string
