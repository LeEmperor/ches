open! Core
open Ches_app

(** Passive rows, centered around the active buffer without retained scroll state.
    Overflow is indicated in the row's leading cell, never at the expense of the
    active row. Badges precede labels so they survive narrow allocations. *)
let render (buffers : Open_buffers.t list) ~width ~rows =
  let width = Int.max 0 width and rows = Int.max 0 rows in
  let count = List.length buffers in
  let active = Option.value (List.findi buffers ~f:(fun _ b -> b.active) |> Option.map ~f:fst) ~default:0 in
  let first = Int.max 0 (Int.min (active - (rows / 2)) (count - rows)) in
  List.init rows ~f:(fun row ->
    let index = first + row in
    match List.nth buffers index with
    | None -> [ Span.blank Status width ]
    | Some b ->
      let overflow = if row = 0 && first > 0 then "^"
        else if row = rows - 1 && index < count - 1 then "v" else " " in
      let label = sprintf "%s%s%d:%s%s %s" (if b.active then ">" else overflow)
        (if b.missing then "!" else "") (index + 1) (if b.modified then "*" else "")
        (if b.missing then " [missing]" else "") b.label in
      let style : Style.t = if b.active then Title else Hint in
      let spans = Span.of_text label ~style ~special:Status_special
        |> Span.keep_left ~n:width ~marker_style:style in
      spans @ [ Span.blank Status (width - Span.total_width spans) ])
;;
