(** [git status --porcelain=v2 -z --branch]: the branch headers and one entry per
    changed, unmerged, untracked or (on request) ignored path. Format reference:
    git-status(1), "Porcelain Format Version 2". Paths are relative to the work-tree
    root (the command runs there), raw bytes (core.quotepath=false and [-z]: never
    quoted), and may contain spaces, newlines or non-UTF-8 bytes. *)

open! Core
open Ches_vcs

module Change : sig
  (** One side of an [XY] status field. *)
  type t =
    | Unmodified (** ['.'] *)
    | Modified (** ['M'] *)
    | Type_changed (** ['T'] *)
    | Added (** ['A'] *)
    | Deleted (** ['D'] *)
    | Renamed (** ['R'] *)
    | Copied (** ['C'] *)
    | Updated_unmerged (** ['U'] *)
  [@@deriving sexp, equal, compare]

  val of_char : char -> t option
end

module Submodule : sig
  (** The [<sub>] field when it starts with ['S'] (a field starting with ['N'] means
      not a submodule: [None] where it appears). *)
  type t =
    { commit_changed : bool (** ['C'] *)
    ; tracked_changes : bool (** ['M'] *)
    ; untracked_changes : bool (** ['U'] *)
    }
  [@@deriving sexp, equal]
end

module Conflict : sig
  (** The [XY] of an unmerged entry. *)
  type t =
    | Both_deleted (** [DD] *)
    | Added_by_us (** [AU] *)
    | Deleted_by_them (** [UD] *)
    | Added_by_them (** [UA] *)
    | Deleted_by_us (** [DU] *)
    | Both_added (** [AA] *)
    | Both_modified (** [UU] *)
  [@@deriving sexp, equal]

  (** e.g. ["both modified"], as git status says it. *)
  val to_string_hum : t -> string
end

module Entry : sig
  type t =
    | Changed of
        { index : Change.t (** [X]: HEAD to index ("staged"). *)
        ; worktree : Change.t (** [Y]: index to work tree ("unstaged"). *)
        ; submodule : Submodule.t option
        ; head_mode : string (** Octal, e.g. ["100644"]; ["000000"] if absent. *)
        ; index_mode : string
        ; worktree_mode : string
        ; path : string
        } (** A ["1 ..."] record. *)
    | Renamed_or_copied of
        { index : Change.t (** [Renamed] or [Copied]. *)
        ; worktree : Change.t
        ; submodule : Submodule.t option
        ; head_mode : string
        ; index_mode : string
        ; worktree_mode : string
        ; score : int (** Similarity percent, from ["R100"] / ["C75"]. *)
        ; path : string (** The new path. *)
        ; original : string (** The path in HEAD. *)
        } (** A ["2 ..."] record (two NUL-terminated paths). *)
    | Unmerged of
        { conflict : Conflict.t
        ; submodule : Submodule.t option
        ; path : string
        } (** A ["u ..."] record. *)
    | Untracked of string (** ["? path"] *)
    | Ignored of string (** ["! path"]; only with [~ignored:true]. *)
  [@@deriving sexp, equal]

  (** The entry's (new) path. *)
  val path : t -> string
end

module Branch : sig
  (** The [# branch.*] headers. *)
  type t =
    { oid : string option (** [None] for ["(initial)"]: no commit yet. *)
    ; head : string option (** [None] for ["(detached)"]. *)
    ; upstream : string option (** e.g. ["origin/main"]. *)
    ; ahead_behind : (int * int) option
    (** From ["+A -B"]; absent when there is no upstream, or it is gone. *)
    }
  [@@deriving sexp, equal]
end

type t =
  { branch : Branch.t
  ; entries : Entry.t list (** In git's order. *)
  ; truncated : bool
  (** The output was cut at the spec's stdout limit; the incomplete last record was
      dropped. *)
  }
[@@deriving sexp, equal]

(** [Cli.read ~cwd] of [status --porcelain=v2 -z --branch --untracked-files=all
    --find-renames], plus [--ignored=matching] with [~ignored:true] (default false).
    Explicit flags override the user's [status.showUntrackedFiles] and
    [status.renames]. *)
val command : ?ignored:bool -> cwd:string -> unit -> Exec.Spec.t

(** Parse stdout. Unknown [#] headers (e.g. [# stash]) are ignored; a missing
    [branch.oid] or [branch.head] header, an unknown record type, or a malformed
    record is an error, except that with [~cut:true] (the output was cut at its limit,
    {!Exec.Result.cut_at_limit}) an incomplete final record is dropped and
    [truncated] set. *)
val parse : cut:bool -> string -> t Or_error.t
