(** The logical state of one document being edited, and the transitions on it.

    This module is pure. A frontend calls {!dispatch} with commands, performs the
    returned {!Effect.t}s, and reports their outcomes with {!handle_outcome}.

    {2 Cursor}

    The cursor is a byte offset at a code-point boundary of {!text}.
    - Insert mode: an insertion point; any boundary, including a line's end.
    - Normal mode: on a code point of a nonempty line (never on its LF or past its
      end), or at the start of an empty line, including the empty final line after a
      trailing LF.

    [Move] goes to {!Motion.destination}, which clamps at line and document
    boundaries rather than failing; a move already at its boundary is a no-op. The
    exception is [Matching_delimiter], which can fail: the cursor stays and the
    message is an [Error] such as [No match for (]. Its
    cost does not grow with the count beyond those boundaries. A count outside 1 to
    [Command.max_count], or any count for a motion that does not
    [Motion.takes_count], raises [Invalid_argument]. Moves change no text, revision,
    dirty state, or history (beyond closing an Insert transaction).

    [Up]/[Down] keep a preferred {i display} column (Vim's [curswant]) across shorter
    lines, including the lines a counted move passes over, and land on the code point
    covering it (see {!Cell_layout}), so moves line up on screen around TABs and wide
    characters. Every other command that moves the cursor resets the preference to
    the resulting display column: the cursor's first cell, or a TAB's last cell for
    a cursor on a TAB outside Insert mode, as in Vim. After [Line_end] that is the
    last character's column (unlike Vim, the cursor does not then stick to line
    ends).

    {2 Commands by mode}

    Commands that do not apply in the current mode change nothing (not even the
    message) and return no effects.

    {v
      Command                          Normal  Insert
      Move                             yes     yes (closes the transaction)
      Enter_insert, Open_line_below,
      Open_line_above                  yes     -
      Exit_insert                      -       yes
      Insert_text, Insert_newline,
      Delete_backward, Delete_forward,
      Insert_soft_tab,
      Delete_soft_tab_backward         -       yes (may join or split lines)
       Delete_char, Delete_chars_*      yes     -   (never delete an LF)
        Delete_motion, Delete_lines,
        Yank_motion, Yank_lines, Paste  yes     -
      Undo, Redo, Save, Quit,
      Force_quit                       yes     yes
    v}

    [Exit_insert] steps left one code point when that does not cross a line start.

    {2 Autoindent}

    Indentation is literal and language-independent: the leading spaces and TABs of
    the cursor's line, copied unchanged. [Open_line_below]/[Open_line_above] copy all
    of it; [Insert_newline] copies only the part before the cursor, and leaves the
    text after the cursor (including any blanks) unchanged at the start of the new
    line. Indentation stays when Insert mode is left without typing anything more.
    [Insert_text] never indents, so pastes are literal.

    Soft-tab widths are in display columns, as Vim's ['softtabstop']: a TAB before
    the cursor counts for the cells it occupies. They must be at least 1; otherwise
    the command raises [Invalid_argument].

    {2 Undo}

    Consecutive Insert-mode edits form one transaction, closed by [Exit_insert], [Move],
    [Save], [Undo] or [Redo]. [Open_line_below]/[Open_line_above] start the
    transaction with the new line, so one undo removes it with the text typed after
     it and restores the original cursor. Each completed Normal-mode deletion is its
    own transaction. Each Normal-mode paste is also one transaction, even when
    its count repeats the register.
    Transactions with no net text change are not recorded. Undo/redo restore text and
    cursor; the file association and saved state are untouched.

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

module Selection : sig
  type t =
    { anchor : int
    ; active : int
    ; kind : [ `Characterwise | `Linewise ]
    }
  [@@deriving sexp_of, equal]
end

module Search_case : sig
  type t =
    | Sensitive
    | Insensitive
    | Smart
  [@@deriving sexp_of, equal]
end

(** A Normal-mode editor at the start of [text], which is considered saved. Use
    [Text_buffer.empty] for a file that does not exist yet. [cell_width] must be the
    width function the frontend draws with, so that display columns agree with the
    screen. *)
val create
  :  ?path:string
  -> ?search_case:Search_case.t
  -> cell_width:Cell_layout.Width.t
  -> Text_buffer.t
  -> t

val text : t -> Text_buffer.t
val path : t -> string option
val mode : t -> Mode.t
val revision : t -> int
val is_dirty : t -> bool

(** Byte offset; see the cursor rules above. *)
val cursor : t -> int
val selection : t -> Selection.t option

(** Zero-based line of the cursor. *)
val cursor_line : t -> int

(** Zero-based code-point column of the cursor within its line. *)
val cursor_column : t -> int

(** Feedback from the most recent command or outcome. Cleared by every {!dispatch}
    that applies in the current mode. *)
val message : t -> Message.t option

(** The unnamed internal register. Successful deletes and yanks replace it; history
    does not restore it. *)
val unnamed_register : t -> Register.t option
val search_case : t -> Search_case.t

val search_state : t -> (string * bool * bool * int option) option

val dispatch : t -> Command.t -> t * Effect.t list

(** Record the outcome of an effect. A successful write marks the {i written} text as
    saved, which may be older than the current text. An outcome older than the newest
    successful write is not allowed to roll the saved state back. *)
val handle_outcome : t -> Effect.Outcome.t -> t
