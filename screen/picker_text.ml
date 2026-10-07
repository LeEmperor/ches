open! Core

let prompt = "> "

let query_row query ~width =
  let prompt = Span.of_text prompt ~style:Pending ~special:Status_special in
  let room = Int.max 0 (width - Span.total_width prompt - 1) in
  let query =
    Span.of_text query ~style:Status ~special:Status_special
    |> Span.keep_right ~n:room ~marker_style:Status_special
  in
  Span.keep_left (prompt @ query) ~n:(Int.max 0 width) ~marker_style:Status_special
;;

let cursor query ~width =
  { Ches_tile.Cursor.row = 0
  ; column = Int.min (Span.total_width (query_row query ~width)) (Int.max 0 (width - 1))
  ; shape = Bar
  }
;;

let matched_text text ~positions =
  let positions = Int.Set.of_list positions in
  let rec go pos acc =
    if pos >= String.length text
    then List.rev acc
    else (
      let length = Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text pos) in
      let style : Style.t = if Set.mem positions pos then Pending else Status in
      go (pos + length) ((style, String.sub text ~pos ~len:length) :: acc))
  in
  go 0 []
  |> List.group ~break:(fun (a, _) (b, _) -> not (Style.equal a b))
  |> List.concat_map ~f:(fun group ->
    let style = fst (List.hd_exn group) in
    Span.of_text (String.concat (List.map group ~f:snd)) ~style ~special:Status_special)
;;
