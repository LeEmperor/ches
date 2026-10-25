(** The tab strip's order and its active view tab. File tabs are the session's
    ({!Ches_app.Session}: identity, open order, activation and closing policy); view
    tabs are the registered views placed [Tab] ({!View_registry}). This module only
    interleaves them and remembers which view tab, if any, is active over the
    session's active file tab. It owns no view or buffer state. *)

open! Core

module Entry : sig
  type t =
    | File of Ches_app.Buffer_id.t
    | View of Ches_tile.View_id.t
  [@@deriving sexp_of, equal]
end

(** What the strip and the status rows draw for one entry. *)
module Item : sig
  type t =
    { label : string
    ; active : bool
    ; modified : bool
    ; missing : bool
    }
  [@@deriving sexp_of]

  val of_file : Ches_app.Open_buffers.t -> t
end

type t [@@deriving sexp_of]

(** No view tabs. *)
val empty : t

(** The strip's entries: [files] (the session's, in its order) and [views] (the
    tab-placed views) where they were added. Entries no longer in [files] or [views]
    are left out; files not yet seen follow at the end, in their order. *)
val entries
  :  t
  -> files:Ches_app.Buffer_id.t list
  -> views:Ches_tile.View_id.t list
  -> Entry.t list

(** The active view tab, if one was activated and not deactivated since. Callers
    check that it is still placed [Tab]. *)
val active : t -> Ches_tile.View_id.t option

(** Insert [view] right after [after] (at the end when [after] is absent), out of any
    earlier position, and make it active. [files] and [views] are as for {!entries}. *)
val add
  :  t
  -> files:Ches_app.Buffer_id.t list
  -> views:Ches_tile.View_id.t list
  -> Ches_tile.View_id.t
  -> after:Entry.t option
  -> t

(** Activate a view tab, or [None] to show the session's active file tab. *)
val activate : t -> Ches_tile.View_id.t option -> t
