open! Core
module Feedback = Ches_error.Error
module Selection = Ches_tile.Navigation.Selection

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

let detail_rows problem ~width = Tile_text.wrap (description problem) ~width

let style (p : Feedback.Problem.t) : Style.t =
  match p.severity with
  | Info -> Info
  | Warning -> Warning
  | Error -> Error
;;

let render ?(focused = false) ?(navigation = Selection.empty)
  ?(details = false) ?(detail_top = 0) ?notice ?pending
  feedback ~current_document ~path ~(rect : Geometry.Rect.t) =
  let problems = entries feedback ~current_document ~path in
  let count = List.length problems in
  let total = List.length (Feedback.problems feedback) in
  let width = rect.width in
  let row style text = Tile_text.row style text ~width in
  let filter = if current_document then "document" else "workspace" in
  if focused then (
    let capacity = Tile_text.capacity rect in
    let navigation = Selection.fit navigation
      (List.map problems ~f:(fun p -> p.Feedback.Problem.identity))
      ~equal:Feedback.Identity.equal ~rows:capacity in
    let selected = List.nth problems navigation.index in
    let detail_rows = if details
      then Option.value_map selected ~default:[] ~f:(detail_rows ~width)
      else [] in
    let detail_top = Int.clamp_exn detail_top ~min:0
      ~max:(Int.max 0 (List.length detail_rows - capacity)) in
    let body =
      if details then List.take (List.drop detail_rows detail_top) capacity
      else List.take (List.drop problems navigation.top) capacity
        |> List.mapi ~f:(fun i p -> Tile_text.item (style p) (description p) ~width
          ~selected:(navigation.top + i = navigation.index)) in
    let body = if count = 0 && capacity > 0 then [ row Status "No active problems" ] else body in
    let header = sprintf "Problems*%s (%s): %d/%d [%d/%d]"
      (if details then " details" else "") filter count total
      (if count = 0 then 0 else navigation.index + 1) count in
    let default = if details
      then sprintf "Details %d-%d/%d | j/k scroll; e/Esc back"
        (detail_top + 1) (Int.min (List.length detail_rows) (detail_top + capacity))
        (List.length detail_rows)
      else sprintf "%d above, %d below | j/k e Enter a Esc"
        navigation.top (Int.max 0 (count - navigation.top - capacity)) in
    Tile_text.capture ~rect ~header ~body
      ~footer:(Tile_text.footer ~notice ~pending ~default ~width))
  else (
    let capacity = Int.max 0 (rect.height - 1) in
    let shown = if count > capacity then Int.max 0 (capacity - 1) else count in
    let preview = List.take problems shown |> List.map ~f:(fun p -> row (style p) (description p)) in
    Tile_text.fill ~rect
      (row Status (sprintf "Problems (%s): %d/%d | Space v e: details" filter count total)
       :: (if count = 0 && capacity > 0 then [ row Status "No active problems" ] else preview)
       @ (if count > shown && capacity > 0
          then [ row Warning (sprintf "+%d more | Space v e: all details" (count - shown)) ]
          else [])))
;;
