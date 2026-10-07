open! Core
open Ches_core

(** Session-retained buffer, independent of placement or target editor group.
    Identity text is the actual editor text; headers/kind hints are decorations. *)
type fingerprint = int * int * Core_unix.file_kind * int64 * float * float
val fingerprint : string -> fingerprint
type t =
  { id : Buffer_id.t
  ; path : string
  ; entries : Directory_identity.Entry.t list
  ; baseline : Directory_identity.t
  ; controller : Controller.t
  ; next_entry : int
  ; fingerprints : fingerprint String.Map.t
  ; parent_identity : int * int
  ; marks : Int.Set.t
  }
val is_directory : string -> bool
val load : ?previous:t -> id:Buffer_id.t -> path:string -> cell_width:Cell_layout.Width.t -> keymap_config:Ches_input.Keymap.Config.t -> unit -> t Or_error.t
val select : t -> string -> t
(** Current validated row resolved to its baseline backing entry, never the
    proposed destination. Invalid snapshots/fresh/blank rows resolve to None. *)
val selected : t -> Directory_identity.Entry.t option
val is_dirty : t -> bool
val rows : t -> Directory_identity.Row.t list Or_error.t
(** All-or-nothing pure plan. Deletion/copy proposals are unsupported. *)
val plan : t -> Directory_plan.operation list Or_error.t
val row_at : t -> int -> Directory_identity.Row.t option
val selected_row : t -> Directory_identity.Row.t option
val selection_rows : t -> Directory_identity.Row.t list
val backing_entry : t -> Directory_identity.Row.t -> Directory_identity.Entry.t option
(** All intersected logical entry rows, in listing order, for every Visual kind;
    outside Visual this resolves the cursor entry. Decorations are never entries. *)
val selection_entries : t -> Directory_identity.Entry.t list
val marked_entries : t -> Directory_identity.Entry.t list
(** Marks on omitted rows stay dormant until undo; no text/history mutation. *)
val mark_selection : t -> marked:bool -> t
val toggle_mark : t -> t
val allows : Command.t -> bool
