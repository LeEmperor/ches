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

module Placement = struct
  type t =
    | Hidden
    | Band
    | Tab
    | Split
  [@@deriving sexp_of, equal]
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
  | Toggle_problems_filter
  | Toggle_view of View_id.t
  | Focus_view of View_id.t
  | Place_view of
      { view : View_id.t option
      ; placement : Placement.t
      }
  | Focus_other_pane
  | Swap_split
  | Adjust_split of int
  | Close_split
  | Run_view_command of
      { view : View_id.t
      ; command : string
      }
  | Request_view of
      { view : View_id.t
      ; request : string
      }
  | Restart_source
  | Kill_source
  | Toggle_zen
  | Open_palette
  | Open_line_picker
  | Open_file_picker
  | Open_content_picker
  | Reset
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      }
[@@deriving sexp_of, equal]

let scale t ~count =
  match t with
  | Shift cells -> Some (Shift (cells * count))
  | Adjust_width cells -> Some (Adjust_width (cells * count))
  | Adjust_split points -> Some (Adjust_split (points * count))
  | Adjust_status_size cells -> Some (Adjust_status_size (cells * count))
  | Adjust_directory_size cells -> Some (Adjust_directory_size (cells * count))
  | Toggle_directory
  | Directory_major
  | Directory_side
  | Hide_directory
  | Focus_directory
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
  | Present_buffers _
  | Close_tab
  | Force_close_tab
  | Recreate_missing_file
  | Toggle_centered
  | Toggle_absolute_numbers
  | Toggle_relative_numbers
  | Toggle_smear
  | Toggle_status
  | Toggle_hotkey_hints
  | Position_status _
  | Inspect_problems
  | Toggle_problems_filter
  | Toggle_view _
  | Focus_view _
  | Place_view _
  | Focus_other_pane
  | Swap_split
  | Close_split
  | Run_view_command _
  | Request_view _
  | Restart_source
  | Kill_source
  | Toggle_zen
  | Open_palette
  | Open_line_picker
  | Open_file_picker
  | Open_content_picker
  | Reset
  | Scroll _ -> None
;;
