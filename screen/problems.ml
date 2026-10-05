open! Core
module Feedback = Ches_error.Error

let entries feedback ~current_document ~path =
  Feedback.problems feedback
  |> List.filter ~f:(fun (p : Feedback.Problem.t) ->
    not current_document
    || Option.value_map path ~default:false ~f:(String.equal p.identity.resource))
;;

let description (p : Feedback.Problem.t) =
  let severity = match p.severity with Info -> "info" | Warning -> "warning" | Error -> "error" in
  let location = Option.value_map p.location ~default:"" ~f:(fun l ->
    sprintf ":%d:%d" l.line l.column) in
  sprintf "%s [%s] %s%s: %s" severity p.identity.source p.identity.resource location p.text
;;

let detail_rows problem ~width =
  if width <= 0 then [] else
    let glyphs = Cell_map.glyphs (description problem) in
    let finish spans =
      let spans = Span.keep_left spans ~n:width ~marker_style:Status_special in
      Span.merge (spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ]) in
    let rows, spans, _ = Array.fold glyphs ~init:([], [], 0)
      ~f:(fun (rows, spans, used) glyph ->
        let rows, spans, used = if used > 0 && used + glyph.width > width
          then finish spans :: rows, [], 0 else rows, spans, used in
        let style = match glyph.kind with Plain -> Style.Status | Tab | Escape -> Status_special in
        rows, spans @ [ Span.create style glyph.text ~width:glyph.width ], used + glyph.width) in
    List.rev (finish spans :: rows)
;;

let render ?(focused = false) ?(navigation = Problem_navigation.empty)
  ?(details = false) ?(detail_top = 0) ?notice ?pending
  feedback ~current_document ~path ~(rect : Geometry.Rect.t) =
  let problems = entries feedback ~current_document ~path in
  let count = List.length problems in
  let total = List.length (Feedback.problems feedback) in
  let row style text =
    let spans = Span.of_text text ~style ~special:Status_special
      |> Span.keep_left ~n:(Int.max 0 rect.width) ~marker_style:Status_special in
    spans @ [ Span.blank Status (Int.max 0 (rect.width - Span.total_width spans)) ]
  in
  let capacity = Int.max 0 (rect.height - 1) in
  let contents = if focused then (
    let capacity = Int.max 0 (rect.height - 2) in
    let navigation = Problem_navigation.fit navigation problems ~rows:capacity in
    let selected = List.nth problems navigation.index in
    let detail_rows = if details
      then Option.value_map selected ~default:[] ~f:(detail_rows ~width:rect.width)
      else [] in
    let detail_top = Int.clamp_exn detail_top ~min:0
      ~max:(Int.max 0 (List.length detail_rows - capacity)) in
    let body =
      if details then List.take (List.drop detail_rows detail_top) capacity
      else List.take (List.drop problems navigation.top) capacity
        |> List.mapi ~f:(fun i p -> row
          (match p.Feedback.Problem.severity with Info -> Info | Warning -> Warning | Error -> Error)
          ((if navigation.top + i = navigation.index then "> " else "  ") ^ description p)) in
    let label = if details then " details" else "" in
    let header = row Title (sprintf "Problems*%s (%s): %d/%d [%d/%d]"
      label (if current_document then "document" else "workspace") count total
      (if count = 0 then 0 else navigation.index + 1) count) in
    let footer = match notice, pending with
      | Some text, _ -> row Warning text
      | None, Some text -> row Pending ("Pending: " ^ text)
      | None, None ->
        row Status (if details then sprintf "Details %d-%d/%d | j/k scroll; e/Esc back"
          (detail_top + 1) (Int.min (List.length detail_rows) (detail_top + capacity)) (List.length detail_rows)
        else sprintf "%d above, %d below | j/k e Enter a Esc"
          navigation.top (Int.max 0 (count - navigation.top - capacity))) in
    let body = if count = 0 && capacity > 0 then [ row Status "No active problems" ] else body in
    header :: List.init capacity ~f:(fun i ->
      Option.value (List.nth body i) ~default:(row Status "")) @ [footer]
  ) else (
  let shown = if count > capacity then Int.max 0 (capacity - 1) else count in
  let preview = List.take problems shown |> List.map ~f:(fun (p : Feedback.Problem.t) ->
    let style = match p.severity with
      | Info -> Style.Info
      | Warning -> Warning
      | Error -> Error in
    row style (description p)) in
    row Status (sprintf "Problems (%s): %d/%d | Space v e: details"
      (if current_document then "document" else "workspace") count total)
    :: (if count = 0 && capacity > 0 then [ row Status "No active problems" ]
        else preview)
    @ (if count > shown && capacity > 0
       then [ row Warning (sprintf "+%d more | Space v e: all details" (count - shown)) ]
       else [])
  ) in
  List.init (Int.max 0 rect.height) ~f:(fun i ->
    Option.value (List.nth contents i) ~default:(row Status ""))
;;
