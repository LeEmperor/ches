(** Local branches with their upstreams, from [git for-each-ref]. *)

open! Core
open Ches_vcs

module Tracking : sig
  type t =
    | In_sync
    | Ahead_behind of
        { ahead : int
        ; behind : int
        } (** At least one is non-zero. *)
    | Gone (** Configured, but the remote-tracking branch no longer exists. *)
  [@@deriving sexp, equal]
end

module Upstream : sig
  type t =
    { name : string (** Short, e.g. ["origin/main"]. *)
    ; refname : string (** Full, e.g. ["refs/remotes/origin/main"]. *)
    ; tracking : Tracking.t
    }
  [@@deriving sexp, equal]
end

module Branch : sig
  type t =
    { name : string (** Short, e.g. ["bpurtell/feature"]. *)
    ; oid : string (** Full hash of its tip. *)
    ; current : bool (** HEAD points at it ([%(HEAD)] is ["*"]). *)
    ; upstream : Upstream.t option
    ; subject : string (** Of its tip commit. *)
    ; committer_time : int (** Of its tip commit, Unix seconds. *)
    }
  [@@deriving sexp, equal]
end

(** [Cli.read ~cwd] of [for-each-ref --format=<f> refs/heads], where [<f>] is
    [%(refname:short)], [%(objectname)], [%(HEAD)], [%(upstream)],
    [%(upstream:short)], [%(upstream:track,nobracket)], [%(committerdate:unix)] and
    [%(contents:subject)], each followed by [%00], one branch per line. (for-each-ref
    has no [-z]; ref names cannot contain NUL or newline, and the subject is one
    line.) Git's default order: by refname. With [LC_ALL=C] (see {!Cli.read_env}) the
    track field is [""], ["ahead N"], ["behind N"], ["ahead N, behind M"] or
    ["gone"]. *)
val command : cwd:string -> Exec.Spec.t

(** Parse stdout, in output order. An empty [%(upstream)] means no upstream. A
    malformed line or track field is an error. With [~cut:true], an incomplete final
    line is dropped. *)
val parse : cut:bool -> string -> Branch.t list Or_error.t
