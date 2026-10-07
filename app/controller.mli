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

(** A successful write of the document. *)
module Saved : sig
  type t =
    { path : string
    ; revision : int (** The editor revision whose text was written. *)
    }
  [@@deriving sexp_of, equal]
end

type t
module Kind : sig
  type t = File | Directory [@@deriving sexp_of, equal]
end
val kind : t -> Kind.t
val is_missing : t -> bool
val mark_missing : t -> t
val recreate : t -> t Or_error.t
val save_as : t -> string -> t Or_error.t

(** Runtime identity, distinct even for independently opened documents with the
    same path/text/revision. Preserved by ordinary transitions; successful reload
    starts a new identity. *)
module Document_id : sig
  type t
  val equal : t -> t -> bool
end

val document_id : t -> Document_id.t

(** Loads [path] with {!File_io.read}, or starts a clean, empty document if nothing exists
    there. IO uses lexical absolute normalization against the current working directory;
    the original spelling is retained for display. The error says which path could not be opened, and why. [cell_width] is passed
    to [Editor.create]. *)
val open_file
  :  ?must_exist:bool
  -> ?keymap_config:Keymap.Config.t
  -> cell_width:Cell_layout.Width.t
  -> string
  -> t Or_error.t

(** Default [keymap_config] is [Keymap.Config.default]. *)
val create : ?keymap_config:Keymap.Config.t -> ?kind:Kind.t -> Editor.t -> t

val editor : t -> Editor.t
val reassociate : t -> string -> t
val rebase_text : t -> saved:Text_buffer.t -> text:Text_buffer.t -> t
(** Original user-facing spelling; normalized IO identity is [Editor.path]. *)
val display_path : t -> string option
val keymap : t -> Keymap.t

(** Immutable current highlight key/snapshot, updated only at document transitions.
    Unsupported paths have an empty current snapshot. No parsing on access. *)
val highlights : t -> Ches_highlight.Snapshot.Key.t * Ches_highlight.Snapshot.t

(** None for plain-text files; failures are cached silently, without altering editor
    feedback. A changed key or successful reload retries a failed provider. *)
val highlight_status : t -> Ches_highlight_tree_sitter.Provider.Status.t option

(** Cumulative actual parse attempts for this document's shared runtime; diagnostic
    only, not a snapshot/history counter. Reading it does no provider work. *)
val highlight_parse_count : t -> int

(** Idempotent release of provider references. Exit closes automatically; frontends
    should also close on normal shutdown/error. Do not keep using a closed runtime. *)
val close : t -> unit

(** Whether the most recent {!handle_input} or {!dispatch} ran at least one editor
    command. The keymap produces none for, e.g., an ignored key or the first key of a
    sequence. A frontend uses this to decide whether [Editor.message] is fresh feedback
    for that input. [false] before any input. *)
val last_input_dispatched : t -> bool

(** The newest text the editor asked to put on the system clipboard (see
    [Effect.Set_clipboard]) since the last take, and the controller with it cleared. The
    controller cannot reach the terminal, so a frontend takes it after {!handle_input} and
    sets the clipboard itself; older requests were superseded. *)
val take_clipboard : t -> t * string option

(** The newest successful write since the last take, and the controller with it
    cleared. A frontend tells diagnostic sources about saves with it; a save at an
    unchanged revision still counts. *)
val take_saved : t -> t * Saved.t option

(** Feeds [input] through the keymap in the editor's current mode, dispatches the
    resulting editor commands, and performs their effects. The view commands are returned,
    in order, for the frontend to apply; they touch no state here. Actions after an editor
    command that requests [Exit] are neither dispatched nor returned. *)
val handle_input : t -> Keymap.Input.t -> t * View_command.t list * Status.t

(** Dispatches [actions] exactly as {!handle_input} would had the keymap produced them,
    for a frontend that already holds a typed action, such as the command palette. Editor
    commands, effects, feedback, highlighting, and the [Exit] cutoff are shared with
    {!handle_input}; the view commands are returned in the same way. The keymap is left
    alone, so a pending sequence survives (cancel it first with {!cancel_pending} where
    that matters), and no problem is acknowledged: that belongs to an idle Escape key.
    {!last_input_dispatched} afterwards reports whether [actions] ran an editor command. *)
val dispatch : t -> Keymap.Action.t list -> t * View_command.t list * Status.t

(** Dispatches [Move { motion; count }] to the editor, for a frontend whose view command
    must bring the cursor along (scrolling the cursor line out of view). Moves request no
    effects. It leaves the keymap and {!last_input_dispatched} alone. *)
val move : t -> Motion.t -> count:int option -> t

(** Copy text from a read-only view to both destinations an editor yank reaches: the
    editor's unnamed register (so [p] pastes it) and the system clipboard (see
    {!take_clipboard}). No editor command runs: the document, cursor, history, dirty
    state, keymap, and feedback are unchanged. *)
val yank : t -> Register.t -> t

val feedback : t -> Ches_error.Error.t
val update_feedback : t -> Ches_error.Error.update -> t

val cancel_pending : t -> t
val with_feedback : t -> Ches_error.Error.t -> t
val with_path : t -> string -> t
val with_register : t -> Register.t option -> t
(** Feed without executing effects, for session-owned quit decisions. *)
val feed_input : t -> Keymap.Input.t -> t * Keymap.Action.t list

(** Validated current-document navigation only. No IO, edits, or feedback resolution. *)
val jump : t -> line:int -> column:int -> t Or_error.t

module For_testing : sig
  val has_live_highlight_provider : t -> bool
  val with_highlight_language : t -> Ches_highlight.Language.t -> t
  val fail_next_highlight : t -> unit
  val highlight_incremental_count : t -> int
end
