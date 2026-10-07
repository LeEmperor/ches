(* Phase-0 spike: pure directory row identity/byte-name codec, not an operation
   planner or filesystem executor. Tokens travel in ordinary editor text/undo. *)
open! Core

module Kind : sig
  type t =
    | File
    | Directory
    | Symlink
    | Unsupported
  [@@deriving sexp_of, equal]
end

module Entry : sig
  type t =
    { id : int
    ; name : string
    ; kind : Kind.t
    }
  [@@deriving sexp_of, equal]
end

type t

module Row : sig
  type identity =
    | Existing of int
    | Fresh
  [@@deriving sexp_of, equal]

  type t =
    { line : int
    ; identity : identity
    ; name : string
    ; kind : Kind.t
    }
  [@@deriving sexp_of, equal]
end

(** Baseline names are raw Unix bytes. IDs must be positive and unique within
    this directory baseline. Empty, dot, dot-dot, slash and NUL names are invalid. *)
val create : Entry.t list -> t Or_error.t

(** Printable ASCII with unsafe bytes encoded as uppercase [\xHH]. Includes
    escaping backslash, @, controls, non-ASCII, and leading/trailing spaces.
    All legal Unix child names, including invalid UTF-8, round-trip exactly. *)
val encode_name : string -> string
val decode_name : string -> string Or_error.t

(** Existing rows: [@ches[ID]<TAB>ENCODED_NAME], plus [/] only for directories.
    Header, kind icons and marks are not part of the editable text. *)
val text : t -> Text_buffer.t

(** Validate the entire snapshot, rejecting malformed/unknown/duplicate tokens,
    noncanonical escaping, invalid child names, and existing type changes.
    Blank lines are ignored; bare names are fresh creation proposals (no backing
    identity until committed). Missing IDs represent deletions, NOT renames.
    Unsupported entries must remain unchanged and present. No IO occurs. *)
val parse : t -> Text_buffer.t -> Row.t list Or_error.t

(** Baseline IDs absent from validated rows, in baseline order. Consumers must
    reject unsupported deletion proposals before execution. *)
val missing_ids : t -> Row.t list -> int list
