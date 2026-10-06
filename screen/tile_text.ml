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

let wrap text ~width =
  if width <= 0
  then []
  else (
    let finish spans =
      let spans = Span.keep_left spans ~n:width ~marker_style:Status_special in
      Span.merge (spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ])
    in
    let rows, spans, _ =
      Array.fold (Cell_map.glyphs text) ~init:([], [], 0) ~f:(fun (rows, spans, used) glyph ->
        let rows, spans, used =
          if used > 0 && used + glyph.width > width
          then finish spans :: rows, [], 0
          else rows, spans, used
        in
        let style =
          match glyph.kind with
          | Plain -> Style.Status
          | Tab | Escape -> Status_special
        in
        rows, spans @ [ Span.create style glyph.text ~width:glyph.width ], used + glyph.width)
    in
    List.rev (finish spans :: rows))
;;

let fill ~(rect : Geometry.Rect.t) rows =
  List.init (Int.max 0 rect.height) ~f:(fun i ->
    Option.value (List.nth rows i) ~default:(row Status "" ~width:rect.width))
;;
