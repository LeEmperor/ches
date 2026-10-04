(** Editor actions, independent of the keys that trigger them. {!Editor.dispatch}
    documents which commands apply in which mode. *)

open! Core

(** The largest count a counted command accepts: 999,999. *)
val max_count : int

(** Where [Enter_insert] places the insertion point, relative to the Normal-mode
    cursor's line. *)
module Insert_position : sig
  type t =
    | Before_cursor (** [i]: at the cursor. *)
    | After_cursor
    (** [a]: after the character under the cursor; on an empty line, at the cursor. *)
    | Line_end (** [A]: at the end of the line, before its LF. *)
    | First_nonblank
    (** [I]: before the first character other than space or TAB, or at the end of a
        blank line. *)
  [@@deriving sexp_of, equal]
end

type t =
  | Move of
      { motion : Motion.t
      ; count : int option [@sexp.option]
      (** From 1 to {!max_count}, or [None] when none was given: bare [G] and [1G]
          differ. Only motions that [Motion.takes_count] accept one. *)
      }
  | Enter_insert of Insert_position.t
  | Open_line_below
  (** Insert a line after the cursor's line, indented like it, and enter Insert mode
      at its end. *)
  | Open_line_above (** Like [Open_line_below], before the cursor's line. *)
  | Exit_insert
  | Insert_text of string
  (** Literal text, including LF for a new line, with no autoindent (e.g. a paste). *)
  | Insert_newline
  (** Split the line at the cursor, copying the line's leading spaces and TABs that
      come before the cursor to the start of the new line. *)
  | Delete_backward (** Remove the code point before the cursor. *)
  | Delete_forward (** Remove the code point after the cursor. *)
  | Insert_soft_tab of int
  (** Insert spaces up to the next column that is a multiple of the width. *)
  | Delete_soft_tab_backward of int
  (** Remove the spaces before the cursor back to the previous column that is a
      multiple of the width, stopping at anything other than a space. Without a space
      before the cursor, the same as [Delete_backward]. *)
  | Delete_char (** Remove the code point under the Normal-mode cursor. *)
  | Delete_chars_forward of int (** [x], deleting up to this many code points. *)
  | Delete_chars_backward of int (** [X], deleting up to this many code points. *)
  | Delete_motion of
      { motion : Motion.t
      ; count : int option
      (** The already-multiplied operator/motion count. *)
      }
  | Delete_lines of int (** [dd], deleting this many logical lines. *)
  | Delete_inner_word (** [diw], the small word under the cursor. *)
  | Yank_motion of
      { motion : Motion.t
      ; count : int option
      (** The already-multiplied operator/motion count. *)
      }
  | Yank_lines of int (** [yy], yanking this many logical lines. *)
  | Paste of { before : bool; count : int }
   (** Insert the unnamed register [count] times: [before] is [P], otherwise [p]. *)
  | Repeat_find of { opposite : bool; count : int }
  | Delete_repeat_find of { opposite : bool; count : int }
  | Yank_repeat_find of { opposite : bool; count : int }
  | Search of { query : string option; forward : bool; count : int; whole_word : bool }
  | Search_word of { forward : bool }
  | Clear_search_highlight
  | Enter_visual of [ `Characterwise | `Linewise | `Blockwise ]
  | Exit_visual
  | Visual_delete
  | Visual_yank
  | Visual_change
  | Visual_insert of { append : bool; count : int }
  (** Block insert: [I] before the block, or [A] ([append]) after it, on every line;
      the text typed is inserted [count] times. Blockwise selections only. *)
  | Reload (** [:e!], discarding buffer changes and reading the associated path. *)
  | Undo
  | Redo
  | Save
  | Quit (** Exit unless there are unsaved changes. *)
  | Force_quit (** Exit, discarding unsaved changes. *)
[@@deriving sexp_of, equal]
