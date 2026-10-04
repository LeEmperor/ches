open! Core
open Ches_core
open Ches_highlight

(** Controller-owned runtime and immutable highlight cache. Runtime handles are
    shared by successive controller states, never editor history; operations must
    be serialized. Snapshots/keys/statuses remain immutable across updates. *)
type t

val create : Editor.t -> t
val update : t -> Editor.t -> reset:bool -> t
val snapshot : t -> Snapshot.Key.t * Snapshot.t
val status : t -> Ches_highlight_ocaml.Provider.Status.t option
val parse_count : t -> int
val close : t -> unit

module For_testing : sig
  (** Simulate a changed language association without adding editing commands. *)
  val with_language : t -> Editor.t -> Language.t -> t
  val fail_next_parse : t -> unit
end
