open! Core

let max_count = 999_999

module Insert_position = struct
  type t =
    | Before_cursor
    | After_cursor
    | Line_end
    | First_nonblank
  [@@deriving sexp_of, equal]
end

type t =
  | Move of
      { motion : Motion.t
      ; count : int option [@sexp.option]
      }
  | Enter_insert of Insert_position.t
  | Open_line_below
  | Open_line_above
  | Exit_insert
  | Insert_text of string
  | Insert_newline
  | Delete_backward
  | Delete_forward
  | Insert_soft_tab of int
  | Delete_soft_tab_backward of int
  | Delete_char
  | Delete_chars_forward of int
  | Delete_chars_backward of int
  | Delete_motion of { motion : Motion.t; count : int option [@sexp.option] }
  | Delete_lines of int
  | Delete_inner_word
  | Yank_motion of { motion : Motion.t; count : int option [@sexp.option] }
  | Yank_lines of int
  | Paste of { before : bool; count : int }
  | Repeat_find of { opposite : bool; count : int }
  | Delete_repeat_find of { opposite : bool; count : int }
  | Yank_repeat_find of { opposite : bool; count : int }
  | Search of
      { query : string option [@sexp.option]
      ; forward : bool
      ; count : int
      ; whole_word : bool
      }
  | Search_word of { forward : bool }
  | Clear_search_highlight
  | Enter_visual of [ `Characterwise | `Linewise | `Blockwise ]
  | Exit_visual
  | Visual_delete
  | Visual_yank
  | Visual_change
  | Visual_insert of { append : bool; count : int }
  | Reload
  | Undo
  | Redo
  | Save
  | Quit
  | Force_quit
[@@deriving sexp_of, equal]
