open! Core

module Scroll = struct
  type t =
    | Line_down
    | Line_up
    | Half_page_down
    | Half_page_up
    | Cursor_middle
    | Cursor_top
    | Cursor_bottom
  [@@deriving sexp_of, equal, enumerate]

  let takes_count = function
    | Line_down | Line_up | Half_page_down | Half_page_up -> true
    | Cursor_middle | Cursor_top | Cursor_bottom -> false
  ;;
end

module Status_position = struct
  type t =
    | Left
    | Right
    | Above
    | Below
  [@@deriving sexp_of, equal]
end

module Buffer_presentation = struct
  type t = Top | Status_rows [@@deriving sexp_of, equal]
end

type t =
  | Toggle_directory
  | Directory_major
  | Directory_side
  | Hide_directory
  | Focus_directory
  | Adjust_directory_size of int
  | Open_directory_entry
  | Directory_parent
  | Refresh_directory
  | Toggle_entry_mark
  | Mark_selection
  | Unmark_selection
  | Clear_directory_marks
  | Open_marked_files
  | Next_tab
  | Previous_tab
  | Present_buffers of Buffer_presentation.t
  | Close_tab
  | Force_close_tab
  | Recreate_missing_file
  | Toggle_centered
  | Shift of int
  | Adjust_width of int
  | Toggle_absolute_numbers
  | Toggle_relative_numbers
  | Toggle_smear
  | Toggle_status
  | Toggle_hotkey_hints
  | Position_status of Status_position.t
  | Adjust_status_size of int
  | Inspect_problems
  | Toggle_problems
  | Toggle_problems_filter
  | Focus_problems
  | Toggle_demo_report
  | Focus_demo_report
  | Toggle_history
  | Focus_history
  | Restart_source
  | Kill_source
  | Toggle_zen
  | Open_palette
  | Open_line_picker
  | Reset
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      }
[@@deriving sexp_of, equal]
