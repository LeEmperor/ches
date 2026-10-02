open! Core

type t =
  { top : int
  ; left : int
  }
[@@deriving sexp_of, equal]

let zero = { top = 0; left = 0 }

let fit t ~line ~span:(start, width) ~rows ~cols ~line_count =
  if rows <= 0 || cols <= 0
  then t
  else (
    let top =
      if line < t.top
      then line
      else if line >= t.top + rows
      then line - rows + 1
      else t.top
    in
    let top = Int.max 0 (Int.min top (line_count - rows)) in
    let left =
      if start + width <= cols
      then 0
      else if width > cols
      then start
      else if start < t.left
      then start
      else if start + width > t.left + cols
      then start + width - cols
      else t.left
    in
    { top; left })
;;
