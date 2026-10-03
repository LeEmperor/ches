(** The logical state of one document being edited, and the transitions on it.

    This module is pure. A frontend calls {!dispatch} with commands, performs the
    returned {!Effect.t}s, and reports their outcomes with {!handle_outcome}.

    {2 Cursor}

    The cursor is a byte offset at a code-point boundary of {!text}.
    - Insert mode: an insertion point; any boundary, including a line's end.
    - Normal mode: on a code point of a nonempty line (never on its LF or past its
      end), or at the start of an empty line, including the empty final line after a
      trailing LF.
    - Visual mode: as Normal mode, except that [Right], [Up], [Down] and [Line_end]
      may also leave it on a line's end (its line break), as in Vim, so that [v$]
      selects the LF. Leaving Visual mode steps back off it.

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
    the resulting display column: the cursor's first cell, except that on a TAB it
    is the TAB's last cell in Normal mode and in Visual mode after the anchor, as in
    Vim. [Line_end] instead makes the cursor stick to line ends: later [Up]/[Down]
    go to the last character of each line until another move resets the
    preference.

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

    In Visual mode only [Move], [Enter_visual], [Exit_visual] and the [Visual_*]
    commands apply. [Enter_visual] switches the selection kind, keeping the anchor.

    {2 Blockwise operators}

    On a blockwise selection, [Visual_yank] and [Visual_delete] put the block in the
    register as rows (see {!Block.contents}), and leave the cursor at the block's
    top-left. [Visual_delete] removes each line's {!Block.rows} range, last line
    first, as one undo step; a TAB or wide glyph cut by an edge leaves a space for
    each of its cells outside the block. [Visual_change] is not supported yet: it
    keeps the selection and reports an [Error].

    [Paste] of a block register puts row {i i} at the same display column on the
    {i i}th line from the cursor: before the cursor's code point for [P], after it for
    [p] (at it on an empty line). A count repeats each row along its line, padding
    every repetition but the last to the block's width, and the last too when text
    follows; padding counts a TAB in a row by its cells where it lands, so text after
    the block lines up (Vim counts every TAB as a full tab stop). Lines shorter than
    the column are padded with spaces, a TAB under the column is split into spaces,
    and a wide glyph under it moves right. Rows beyond the document's last line add
    lines (before a final LF, which stays final). The cursor goes to the first row's
    start; the paste is one undo step.

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
    ; kind : [ `Characterwise | `Linewise | `Blockwise ]
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

(** The rectangle of a blockwise selection, which reaches every line's end after
    [Line_end] until another move resets the preferred column. [None] for other
    selections. *)
val block : t -> Block.t option

(** Zero-based line of the cursor. *)
val cursor_line : t -> int

(** Zero-based code-point column of the cursor within its line. *)
val cursor_column : t -> int

(** Feedback from the most recent command or outcome. Cleared by every {!dispatch}
    that applies in the current mode. *)
val message : t -> Message.t option

(** The unnamed internal register. Successful deletes and yanks replace it, except
    that an empty characterwise yank or a block of empty rows leaves it; history does
    not restore it. *)
val unnamed_register : t -> Register.t option
val search_case : t -> Search_case.t

val search_state : t -> (string * bool * bool * int option) option

val dispatch : t -> Command.t -> t * Effect.t list

(** Record the outcome of an effect. A successful write marks the {i written} text as
    saved, which may be older than the current text. An outcome older than the newest
    successful write is not allowed to roll the saved state back. *)
val handle_outcome : t -> Effect.Outcome.t -> t
