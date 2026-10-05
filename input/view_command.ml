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

type t =
  | Toggle_centered
  | Shift of int
  | Adjust_width of int
  | Toggle_absolute_numbers
  | Toggle_relative_numbers
  | Toggle_smear
  | Toggle_status
  | Position_status of Status_position.t
  | Adjust_status_size of int
  | Inspect_problems
  | Toggle_problems
  | Toggle_problems_filter
  | Focus_problems
  | Toggle_zen
  | Reset
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      }
[@@deriving sexp_of, equal]
