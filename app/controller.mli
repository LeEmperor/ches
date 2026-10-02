(** The running application for one document: the editor, its keymap, and the
    execution of the editor's effects.

    A frontend opens a file with {!open_file}, then for each normalized input calls
    {!handle_input}, applies the view commands it returns to its own layout state, and
    redraws from {!editor} and {!keymap}. All feedback is in
    [Editor.message] (including save results and errors) and [Keymap.pending] /
    [Keymap.notice]. When {!handle_input} returns [Exit], the frontend restores the
    terminal and ends the process.

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

(** Loads [path] with {!File_io.read}, or starts a clean, empty document if nothing
    exists there. The error says which path could not be opened, and why. *)
val open_file : ?keymap_config:Keymap.Config.t -> string -> t Or_error.t

(** Default [keymap_config] is [Keymap.Config.default]. *)
val create : ?keymap_config:Keymap.Config.t -> Editor.t -> t

val editor : t -> Editor.t
val keymap : t -> Keymap.t

(** Whether the most recent {!handle_input} dispatched at least one editor command.
    The keymap produces none for, e.g., an ignored key or the first key of a sequence.
    A frontend uses this to decide whether [Editor.message] is fresh feedback for that
    input. [false] before any input. *)
val last_input_dispatched : t -> bool

(** Feeds [input] through the keymap in the editor's current mode, dispatches the
    resulting editor commands, and performs their effects. The view commands are
    returned, in order, for the frontend to apply; they touch no state here. Actions
    after an editor command that requests [Exit] are neither dispatched nor
    returned. *)
val handle_input : t -> Keymap.Input.t -> t * View_command.t list * Status.t
