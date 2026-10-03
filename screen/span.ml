open! Core

type t =
  { text : string
  ; width : int
  ; style : Style.t
  }
[@@deriving sexp_of]

let create style text ~width = { text; width; style }
let blank style width = create style (String.make width ' ') ~width
let total_width spans = List.sum (module Int) spans ~f:(fun s -> s.width)

let merge spans =
  List.fold spans ~init:[] ~f:(fun acc s ->
    match acc with
    | _ when String.is_empty s.text -> acc
    | prev :: rest when Style.equal prev.style s.style ->
      { prev with text = prev.text ^ s.text; width = prev.width + s.width } :: rest
    | _ -> s :: acc)
  |> List.rev
;;

let of_glyphs ?highlight glyphs ~left ~cols ~(text : Style.t) ~(special : Style.t) =
  let right = left + cols in
  let spans, _attachable =
    Array.fold
      glyphs
      ~init:([], false)
      ~f:
        (fun
          (spans, attachable)
           ({ pos; col; width; text = s; kind } : Cell_map.Glyph.t)
        ->
        let stop = col + width in
        let style : Style.t =
          match kind with
          | Escape -> special
          | Plain | Tab -> text
        in
        let glyph : Cell_map.Glyph.t = { pos; col; width; text = s; kind } in
        let style =
          match Option.bind highlight ~f:(fun f -> f glyph) with
          | None -> style
          | Some `Match -> (match kind with Escape -> Search_special_match | Plain | Tab -> Search_match)
          | Some `Current -> (match kind with Escape -> Search_special_match_current | Plain | Tab -> Search_match_current)
          | Some `Selection -> (match kind with Escape -> Selection_special | Plain | Tab -> Selection)
        in
        if width = 0
        then
          (* Attach to the preceding cell when that cell was drawn as itself. *)
          if attachable then create text s ~width:0 :: spans, true else spans, false
        else if stop <= left || col >= right
        then spans, false
        else if col >= left && stop <= right
        then create style s ~width :: spans, Cell_map.Kind.equal kind Plain
        else (
          let first = Int.max col left in
          let visible = Int.min stop right - first in
          let clipped =
            match kind with
            | Tab -> blank style visible
            | Escape ->
              create
                special
                (String.sub s ~pos:(first - col) ~len:visible)
                ~width:visible
            | Plain ->
              (* A wide character cut by an edge. *)
              create special (if col < left then "<" else ">") ~width:visible
          in
          clipped :: spans, false))
  in
  List.rev (blank text (cols - total_width spans) :: spans) |> merge
;;

let of_text s ~style ~special =
  let glyphs = Cell_map.glyphs s in
  of_glyphs glyphs ~left:0 ~cols:(Cell_map.total_width glyphs) ~text:style ~special
;;

(* Span text is already mapped, so mapping it again to find glyph boundaries changes
   nothing. *)
let concat_glyphs glyphs =
  String.concat_array (Array.map glyphs ~f:(fun (g : Cell_map.Glyph.t) -> g.text))
;;

let take spans ~n =
  let rec take spans k =
    match spans with
    | [] -> []
    | s :: rest ->
      if k <= 0
      then []
      else if s.width <= k
      then s :: take rest (k - s.width)
      else (
        let kept =
          Array.filter (Cell_map.glyphs s.text) ~f:(fun g -> g.col + g.width <= k)
        in
        let kept_width = Cell_map.total_width kept in
        [ create s.style (concat_glyphs kept) ~width:kept_width
        ; blank s.style (k - kept_width)
        ])
  in
  take spans n |> merge
;;

let keep_left spans ~n ~marker_style =
  if total_width spans <= n
  then spans
  else if n <= 0
  then []
  else take spans ~n:(n - 1) @ [ create marker_style ">" ~width:1 ] |> merge
;;

let keep_right spans ~n ~marker_style =
  let total = total_width spans in
  if total <= n
  then spans
  else if n <= 0
  then []
  else (
    let rec drop spans k =
      (* Drop [k] cells from the left; a glyph cut in two becomes spaces. *)
      match spans with
      | [] -> []
      | s :: rest ->
        if k <= 0
        then spans
        else if s.width <= k
        then drop rest (k - s.width)
        else (
          let kept = Array.filter (Cell_map.glyphs s.text) ~f:(fun g -> g.col >= k) in
          let first = if Array.is_empty kept then s.width else kept.(0).col in
          blank s.style (first - k)
          :: create s.style (concat_glyphs kept) ~width:(s.width - first)
          :: rest)
    in
    create marker_style "<" ~width:1 :: drop spans (total - n + 1) |> merge)
;;
