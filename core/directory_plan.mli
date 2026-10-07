open! Core

(** Pure, all-or-nothing proposals. Fresh rows create immediate children;
    existing/copy rows accept lexical destinations with encoded components.
    Copy rows use [@copy[ID]], not duplicated [@ches[ID]]. Missing existing IDs
    request permanent deletion. Filesystem collisions/devices/empty-directory
    policy and normalized destination aliases are checked by the executor. *)
type operation =
  | Create_file of string
  | Create_directory of string
  | Rename of { id : int; source : string; destination : string }
  | Delete of { id : int; source : string; kind : Directory_identity.Kind.t }
  | Copy of { id : int; source : string; destination : string; kind : Directory_identity.Kind.t }
[@@deriving sexp_of, equal]

val plan : Directory_identity.Entry.t list -> Text_buffer.t -> operation list Or_error.t
val summary : operation list -> string
