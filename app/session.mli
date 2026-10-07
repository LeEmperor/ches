open! Core
open Ches_core
open Ches_input
type t
type placement = Major | Side
type directory_presentation =
  { buffer : Buffer_id.t; placement : placement; target_group : Group_id.t; return_target : Buffer_id.t option }
val directory_presentation : t -> directory_presentation option
val create : ?cwd:string -> ?keymap_config:Keymap.Config.t -> ?directory_config:Directory_buffer.Config.t -> cell_width:Cell_layout.Width.t -> Controller.t -> t
val buffers : t -> (Buffer_id.t * Controller.t) list
(** Active file tab underneath any major directory presentation. *)
val active_id : t -> Buffer_id.t option
(** Visible input owner, not necessarily the active file tab. *)
val context_id : t -> Buffer_id.t option
val has_buffer : t -> Buffer_id.t -> bool
(** Presented browser, including an unfocused side browser. *)
val directory_buffer : t -> Directory_buffer.t option
(** Directory adapter only when it owns modal input. *)
val input_directory : t -> Directory_buffer.t option
(** Cancel prefixes on both owners; preserve directory selection and text state. *)
val focus_directory : t -> bool -> t
val set_directory_placement : t -> placement -> t
val hide_directory : t -> t
(** Read-only snapshot for drawing either retained surface; do not adopt it. *)
val surface : t -> directory:bool -> t
val show_directory : ?select:string -> t -> string -> t Or_error.t
val group_id : t -> Group_id.t
val startup_directory : t -> string
val normalize : t -> string -> string
val find : t -> Buffer_id.t -> Controller.t option
val source_generation : t -> Buffer_id.t -> int option
val find_resource : t -> string -> (Buffer_id.t * Controller.t) option
type resource_buffer = File_buffer of Buffer_id.t * Controller.t | Directory_buffer of Directory_buffer.t
val find_resource_buffer : t -> string -> resource_buffer option
val active_controller : t -> Controller.t option
(** Collect document-local effects and synchronize session feedback/register.
     The replacement must belong to the same active buffer; resource reassociation
     is session-owned, not arbitrary controller replacement. *)
val replace_active : t -> Controller.t -> t
(** [must_exist] rejects missing new resources. Already retained buffers are
     activated without rereading disk, including dirty or missing buffers.
     Validation runs before activation/registration. Returned errors or exceptions
     preserve session state and close a newly loaded controller. *)
val open_or_activate : ?must_exist:bool -> ?validate:(Controller.t -> unit Or_error.t)
  -> t -> string -> (t * Buffer_id.t) Or_error.t
val activate : t -> Buffer_id.t -> t Or_error.t
val close_buffer : t -> Buffer_id.t -> force:bool -> t * bool
val close_current : t -> force:bool -> t * bool
(** Directory save explicitly applies validated create/rename/copy/permanent-delete proposals; never
    writes listing text. Partial failures retain reconciled unresolved intent. *)
val save_current : t -> t
val recreate_current : t -> t
(** Exclusive save-as; refuses existing destinations, reindexes the same buffer. *)
val save_as : t -> Buffer_id.t -> string -> t Or_error.t
(** Dirty file and retained directory buffers in ID order; continue on error. *)
val save_all : t -> t * (Buffer_id.t * bool) list
val quit : t -> force:bool -> t * Controller.Status.t
val dispatch : t -> Keymap.Action.t list -> t * View_command.t list * Controller.Status.t
val handle_input : t -> Keymap.Input.t -> t * View_command.t list * Controller.Status.t
val feedback : t -> Ches_error.Error.t
val take_clipboard : t -> t * string option
val take_saved : t -> t * Controller.Saved.t list
val take_closed : t -> t * string list
val exited : t -> bool
val dispose : t -> unit
module For_testing : sig
  (** Fault injection for isolated filesystem fixtures only. *)
  val save_directory : t -> Buffer_id.t -> before_mutation:(int -> unit) -> t
end
