(** Synchronous file reading and writing for documents.

    Errors are returned, never raised, and carry a short human-readable reason such as
    ["Permission denied"] or ["invalid UTF-8 at byte offset 3"], without the path.

    {2 Limitations}

    - {!write} truncates the file and writes it in place. It is not crash-safe: if the
      process or machine dies mid-write, or the disk fills up, the file can be left
      truncated or partially written. It does not [fsync].
    - Symlinks are followed: reading and writing act on the target, and the link is
      kept. A dangling symlink reads as a missing file, and saving creates its target.
    - The file's permissions are kept when it exists; a new file gets [0o666] less
      the umask.
    - There is no detection of changes made to the file by other programs. *)

open! Core
open Ches_core

module Loaded : sig
  type t =
    | Existing of Text_buffer.t
    | Missing (** Nothing exists at the path: start a new, empty document. *)
  [@@deriving sexp_of]
end

(** Reads a regular file and validates its contents as document text. A missing path
    is [Ok Missing]; any other failure, including a directory, special file, or text
    that {!Text_buffer.of_string} rejects, is an error. *)
val read : string -> Loaded.t Or_error.t

(** Replaces the contents of [path] with exactly the bytes of the text, creating the
    file if needed. Fails if the parent directory does not exist. *)
val write : string -> Text_buffer.t -> unit Or_error.t
