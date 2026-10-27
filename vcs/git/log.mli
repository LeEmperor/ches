(** Recent history of HEAD for the Commits panel, from a bounded [git log]. *)

open! Core
open Ches_vcs

module Commit : sig
  type t =
    { hash : string (** Full. *)
    ; parents : string list (** Full hashes; [] for a root commit. *)
    ; author_name : string
    ; author_email : string
    ; author_time : int (** Unix seconds. *)
    ; subject : string
    }
  [@@deriving sexp, equal]

  (** The first 7 characters of [hash]. *)
  val short_hash : t -> string
end

(** [Cli.read ~cwd] of [log -z --no-color --no-show-signature --max-count=<limit>
    --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s HEAD --]: six NUL-separated fields
    per commit, each record NUL-terminated ([%P] is empty for a root commit). Raises
    if [limit] is not positive. On an unborn branch git exits 128 (["bad revision
    'HEAD'"]); [Backend.snapshot] reads that as no commits. *)
val command : cwd:string -> limit:int -> Exec.Spec.t

(** Parse stdout, newest first. [""] is no commits. A wrong field count, an empty
    hash, or a non-numeric time is an error, except that with [~cut:true] an
    incomplete final record is dropped. *)
val parse : cut:bool -> string -> Commit.t list Or_error.t
