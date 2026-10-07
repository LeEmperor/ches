open! Core

let row style text ~width =
  let width = Int.max 0 width in
  let spans =
    Span.of_text text ~style ~special:Status_special
    |> Span.keep_left ~n:width ~marker_style:Status_special
  in
  spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ]
;;

let item ~selected style text ~width =
  row style ((if selected then "> " else "  ") ^ text) ~width
;;

let fill ~(rect : Geometry.Rect.t) rows =
  List.init (Int.max 0 rect.height) ~f:(fun i ->
    Option.value (List.nth rows i) ~default:(row Status "" ~width:rect.width))
;;

(* The glyphs of [row] from [selected] offsets, exactly [width] cells. *)
let text_row (row : Ches_tile.Text_view.Row.t) ~width ~selected =
  let selection = Style.document ~overlay:Selection () in
  let spans =
    Array.to_list row.glyphs
    |> List.map ~f:(fun (glyph : Cell_map.Glyph.t) ->
      let style : Style.t =
        if selected (row.line_start + glyph.pos)
        then selection
        else (
          match glyph.kind with
          | Plain -> Status
          | Tab | Escape -> Status_special)
      in
      Span.create style glyph.text ~width:glyph.width)
  in
  let spans = Span.keep_left spans ~n:width ~marker_style:Status_special in
  let used = Span.total_width spans in
  let break =
    if used < width && Option.exists row.break ~f:selected
    then [ Span.blank selection 1 ]
    else []
  in
  Span.merge
    (spans @ break @ [ Span.blank Status (Int.max 0 (width - used - List.length break)) ])
;;

let text_view view ~width ~rows =
  let view = Ches_tile.Text_view.fit view ~width ~rows in
  let selected =
    match Ches_tile.Text_view.selection view with
    | None -> fun _ -> false
    | Some (start, stop) -> fun offset -> start <= offset && offset < stop
  in
  Ches_tile.Text_view.rows view ~width
  |> Fn.flip List.drop (Ches_tile.Text_view.top view)
  |> Fn.flip List.take (Int.max 0 rows)
  |> List.map ~f:(text_row ~width ~selected)
;;

let text_footer ?(hotkey_hints = false) view ~width ~rows =
  let view = Ches_tile.Text_view.fit view ~width ~rows in
  let total = List.length (Ches_tile.Text_view.rows view ~width) in
  let top = Ches_tile.Text_view.top view in
  let range =
    sprintf "Details %d-%d/%d" (top + 1) (Int.min total (top + Int.max 1 rows)) total
  in
  let state, keys =
    match Ches_tile.Text_view.visual view with
    | None -> "", " | hjkl w b v V yy; e/Esc back"
    | Some Characterwise -> " | VISUAL", ": y copy, o swap; Esc cancel"
    | Some Linewise -> " | VISUAL LINE", ": y copy, o swap; Esc cancel"
  in
  range ^ state ^ (if hotkey_hints then keys else "")
;;
