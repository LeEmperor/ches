open! Core

module Policy = struct
  type t =
    { padding : int
    ; min_content_width : int
    ; min_content_height : int
    ; bare_labels : bool
    }
  [@@deriving sexp_of, equal]

  let minor =
    { padding = 1; min_content_width = 12; min_content_height = 1; bare_labels = true }
  ;;

  let status =
    { padding = 1; min_content_width = 8; min_content_height = 5; bare_labels = false }
  ;;
end

module Layout = struct
  type t =
    { outer : Geometry.Rect.t
    ; framed : bool
    ; padding : int
    ; title : Geometry.Rect.t
    ; footer : Geometry.Rect.t
    ; content : Geometry.Rect.t
    }
  [@@deriving sexp_of, equal]
end

let layout (policy : Policy.t) (rect : Geometry.Rect.t) : Layout.t =
  let outer = { rect with width = Int.max 0 rect.width; height = Int.max 0 rect.height } in
  let row y ~height = { outer with y; height } in
  let fits padding =
    outer.width - 2 - (2 * padding) >= policy.min_content_width
    && outer.height - 2 >= policy.min_content_height
  in
  let framed padding : Layout.t =
    let inner = { outer with x = outer.x + 1; width = outer.width - 2 } in
    { outer
    ; framed = true
    ; padding
    ; title = { inner with height = 1 }
    ; footer = { inner with y = outer.y + outer.height - 1; height = 1 }
    ; content =
        { x = outer.x + 1 + padding
        ; y = outer.y + 1
        ; width = outer.width - 2 - (2 * padding)
        ; height = outer.height - 2
        }
    }
  in
  let padding = Int.max 0 policy.padding in
  if fits padding
  then framed padding
  else if fits 0
  then framed 0
  else if policy.bare_labels
  then (
    let title = Int.min 1 outer.height in
    let footer = Int.min 1 (outer.height - title) in
    { outer
    ; framed = false
    ; padding = 0
    ; title = row outer.y ~height:title
    ; footer = row (outer.y + outer.height - footer) ~height:footer
    ; content = row (outer.y + title) ~height:(outer.height - title - footer)
    })
  else
    { outer
    ; framed = false
    ; padding = 0
    ; title = row outer.y ~height:0
    ; footer = row (outer.y + outer.height) ~height:0
    ; content = outer
    }
;;

module Label = struct
  type t =
    { text : string
    ; style : Style.t
    }
  [@@deriving sexp_of]

  let hint text = { text; style = Hint }

  let footer ~notice ~pending ~default =
    match notice, pending with
    | Some text, _ -> { text; style = Warning }
    | None, Some text -> { text = "Pending: " ^ text; style = Pending }
    | None, None -> hint default
  ;;
end

module Content = struct
  type t =
    { title : string
    ; footer : Label.t option
    ; body : Span.t list list
    }
end

let fit_row row ~width =
  let row = Span.take row ~n:width in
  row @ [ Span.blank Status (width - Span.total_width row) ]
;;

(* [─ text ─────] across [width] cells of border, or an unbroken rule. *)
let border_label ~border (label : Label.t option) ~width =
  let rule n = Span.create border (String.concat (List.init n ~f:(fun _ -> "─"))) ~width:n in
  let text =
    match label with
    | Some label when width >= 4 ->
      Span.of_text label.text ~style:label.style ~special:Title_special
      |> Span.keep_left ~n:(width - 3) ~marker_style:Title_special
    | Some _ | None -> []
  in
  match label, text with
  | None, _ | _, [] -> [ rule width ]
  | Some label, text ->
    let text = (Span.blank label.style 1 :: text) @ [ Span.blank label.style 1 ] in
    (rule 1 :: text) @ [ rule (width - 1 - Span.total_width text) ]
;;

let render (layout : Layout.t) ~focused (content : Content.t) =
  let { Layout.outer; framed; padding; title = _; footer = _; content = area } = layout in
  let body =
    List.init area.height ~f:(fun i ->
      fit_row (Option.value (List.nth content.body i) ~default:[]) ~width:area.width)
  in
  let rows =
    if framed
    then (
      let border : Style.t = if focused then Border_focused else Border in
      let inner = outer.width - 2 in
      let edge left label right =
        (Span.create border left ~width:1 :: border_label ~border label ~width:inner)
        @ [ Span.create border right ~width:1 ]
      in
      let side = Span.create border "│" ~width:1 in
      let pad = Span.blank Status padding in
      (edge "╭" (Some { text = content.title; style = Title }) "╮"
       :: List.map body ~f:(fun row -> (side :: pad :: row) @ [ pad; side ]))
      @ [ edge "╰" content.footer "╯" ])
    else (
      (* Bare labels use the content background, as the unframed views always have. *)
      let label_row (label : Label.t) rect =
        List.init rect.Geometry.Rect.height ~f:(fun _ ->
          let style : Style.t =
            match label.style with
            | Hint -> Status
            | style -> style
          in
          Tile_text.row style label.text ~width:outer.width)
      in
      label_row { text = content.title; style = Title } layout.title
      @ body
      @ label_row (Option.value content.footer ~default:(Label.hint "")) layout.footer)
  in
  List.map rows ~f:Span.merge
;;
