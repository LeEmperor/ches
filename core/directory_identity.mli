(** Pure directory row identity/byte-name codec. Optional scoped serialization
    stores protected IDs in text metadata rather than editable prefixes. *)
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
    | Copy of int
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
val decode_destination : string -> string Or_error.t

(** Existing rows: [@ches[ID]<TAB>ENCODED_NAME], plus [/] only for directories.
    Explicit copies use [@copy[ID]] with a distinct destination. Existing/copy
    destinations accept slash-separated encoded components, including [..].
    Header, kind icons and marks are not part of the editable text. *)
(** With [scope], emit names only and attach protected directory-local anchors.
    Without it, emit legacy exposed tokens for pure codec/backend callers. *)
val text : ?scope:string -> t -> Text_buffer.t

(** Validate the entire snapshot, rejecting malformed/unknown/duplicate tokens,
    noncanonical escaping, invalid destinations, and existing type changes.
    Blank lines are ignored; bare names are fresh creation proposals (no backing
    identity until committed). Missing IDs represent deletions, NOT renames.
    Unsupported entries must remain unchanged and present. No IO occurs. *)
val parse : t -> Text_buffer.t -> Row.t list Or_error.t

(** Baseline IDs absent from existing rows, in baseline order. Copy rows do not
    retain their source: copying and omitting it requests copy plus delete. *)
val missing_ids : t -> Row.t list -> int list
