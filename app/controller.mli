(** The running application for one document: the editor, its keymap, and the execution of
    the editor's effects.

    A frontend opens a file with {!open_file}, then for each normalized input calls
    {!handle_input}, applies the view commands it returns to its own layout state, and
    redraws from {!editor} and {!keymap}. Shared feedback is available through [feedback];
    pending keys and notices remain in [Keymap.pending] / [Keymap.notice]. When
    {!handle_input} returns [Exit], the frontend restores the terminal and ends the
    process.

    Effects run synchronously, in the order the editor requested them: a save has
    finished, and its outcome is reflected in the editor, by the time {!handle_input}
    returns. *)

open! Core
open Ches_core
open Ches_input

module Status : sig
  type t =
    | Running
    | Exit
  [@@deriving sexp_of, equal]
end

type t

(** Loads [path] with {!File_io.read}, or starts a clean, empty document if nothing exists
    there. The error says which path could not be opened, and why. [cell_width] is passed
    to [Editor.create]. *)
val open_file
  :  ?keymap_config:Keymap.Config.t
  -> cell_width:Cell_layout.Width.t
  -> string
  -> t Or_error.t

(** Default [keymap_config] is [Keymap.Config.default]. *)
val create : ?keymap_config:Keymap.Config.t -> Editor.t -> t

val editor : t -> Editor.t
val keymap : t -> Keymap.t

(** Whether the most recent {!handle_input} dispatched at least one editor command. The
    keymap produces none for, e.g., an ignored key or the first key of a sequence. A
    frontend uses this to decide whether [Editor.message] is fresh feedback for that
    input. [false] before any input. *)
val last_input_dispatched : t -> bool

(** The newest text the editor asked to put on the system clipboard (see
    [Effect.Set_clipboard]) since the last take, and the controller with it cleared. The
    controller cannot reach the terminal, so a frontend takes it after {!handle_input} and
    sets the clipboard itself; older requests were superseded. *)
val take_clipboard : t -> t * string option

(** Feeds [input] through the keymap in the editor's current mode, dispatches the
    resulting editor commands, and performs their effects. The view commands are returned,
    in order, for the frontend to apply; they touch no state here. Actions after an editor
    command that requests [Exit] are neither dispatched nor returned. *)
val handle_input : t -> Keymap.Input.t -> t * View_command.t list * Status.t

(** Dispatches [Move { motion; count }] to the editor, for a frontend whose view command
    must bring the cursor along (scrolling the cursor line out of view). Moves request no
    effects. It leaves the keymap and {!last_input_dispatched} alone. *)
val move : t -> Motion.t -> count:int option -> t

val feedback : t -> Ches_error.Error.t
val update_feedback : t -> Ches_error.Error.update -> t
