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

type t =
  | Toggle_centered
  | Shift of int
  | Adjust_width of int
  | Toggle_absolute_numbers
  | Toggle_relative_numbers
  | Reset
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      }
[@@deriving sexp_of, equal]
