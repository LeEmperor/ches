(** The logical state of one document being edited, and the transitions on it.

    This module is pure. A frontend calls {!dispatch} with commands, performs the
    returned {!Effect.t}s, and reports their outcomes with {!handle_outcome}.

    {2 Cursor}

    The cursor is a byte offset at a code-point boundary of {!text}.
    - Insert mode: an insertion point; any boundary, including a line's end.
    - Normal mode: on a code point of a nonempty line (never on its LF or past its
      end), or at the start of an empty line, including the empty final line after a
      trailing LF.

    [Move Up]/[Move Down] keep a preferred code-point column across shorter lines.
    Every other command that moves the cursor resets the preference to the resulting
    column. Moves past a boundary are no-ops.

    {2 Commands by mode}

    Commands that do not apply in the current mode change nothing (not even the
    message) and return no effects.

    {v
      Command                          Normal  Insert
      Move                             yes     yes (closes the transaction)
      Enter_insert                     yes     -
      Exit_insert                      -       yes
      Insert_text, Delete_backward,
      Delete_forward, Insert_soft_tab,
      Delete_soft_tab_backward         -       yes (may join or split lines)
      Delete_char                      yes     -   (never deletes an LF)
      Undo, Redo, Save, Quit,
      Force_quit                       yes     yes
    v}

    [Exit_insert] steps left one code point when that does not cross a line start.

    Soft-tab widths are in code-point columns, so a TAB before the cursor counts as
    one column. They must be at least 1; otherwise the command raises
    [Invalid_argument].

    {2 Undo}

    Consecutive Insert-mode edits form one transaction, closed by [Exit_insert], [Move],
    [Save], [Undo] or [Redo]. Each [Delete_char] is its own transaction. Transactions
    with no net text change are not recorded. Undo/redo restore text and cursor; the
    file association and saved state are untouched.

    {2 Revision and dirty state}

    {!revision} increases with every text change, including undo and redo. {!is_dirty}
    compares the text with the last successfully written text, so undoing back to the
    saved text makes the document clean again. *)

(* [open! Core] would shadow our [Command] with Core's command-line [Command]. *)
module Editor_command := Command

open! Core
module Command := Editor_command

module Message : sig
  type t =
    | Info of string
    | Error of string
  [@@deriving sexp_of, equal]
end

type t

(** A Normal-mode editor at the start of [text], which is considered saved. Use
    [Text_buffer.empty] for a file that does not exist yet. *)
val create : ?path:string -> Text_buffer.t -> t

val text : t -> Text_buffer.t
val path : t -> string option
val mode : t -> Mode.t
val revision : t -> int
val is_dirty : t -> bool

(** Byte offset; see the cursor rules above. *)
val cursor : t -> int

(** Zero-based line of the cursor. *)
val cursor_line : t -> int

(** Zero-based code-point column of the cursor within its line. *)
val cursor_column : t -> int

(** Feedback from the most recent command or outcome. Cleared by every {!dispatch}
    that applies in the current mode. *)
val message : t -> Message.t option

val dispatch : t -> Command.t -> t * Effect.t list

(** Record the outcome of an effect. A successful write marks the {i written} text as
    saved, which may be older than the current text. An outcome older than the newest
    successful write is not allowed to roll the saved state back. *)
val handle_outcome : t -> Effect.Outcome.t -> t
