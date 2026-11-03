open! Core

(** Bounded metadata-only observation. No file contents are read. This detects
    ordinary edits/replacements, but cannot verify server symbol identity or
    exclude a change racing the observation. Follows symlinks, and returns [None]
    for missing/unreadable paths and nonregular files without opening them. *)
type t [@@deriving equal]
val read : string -> t option
val to_string : t -> string
