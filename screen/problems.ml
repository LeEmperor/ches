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
  feedback ~current_document ~path ~width ~rows : Tile_shell.Content.t =
  let problems = entries feedback ~current_document ~path in
  let count = List.length problems in
  let total = List.length (Feedback.problems feedback) in
  let rows = Int.max 0 rows in
  let row style text = Tile_text.row style text ~width in
  let filter = if current_document then "document" else "workspace" in
  let empty = if count = 0 && rows > 0 then [ row Status "No active problems" ] else [] in
  if focused then (
    let navigation = Selection.fit navigation
      (List.map problems ~f:(fun p -> p.Feedback.Problem.identity))
      ~equal:Feedback.Identity.equal ~rows in
    let selected = List.nth problems navigation.index in
    let detail_rows = if details
      then Option.value_map selected ~default:[] ~f:(detail_rows ~width)
      else [] in
    let detail_top = Int.clamp_exn detail_top ~min:0
      ~max:(Int.max 0 (List.length detail_rows - rows)) in
    let body =
      if details then List.take (List.drop detail_rows detail_top) rows
      else List.take (List.drop problems navigation.top) rows
        |> List.mapi ~f:(fun i p -> Tile_text.item (style p) (description p) ~width
          ~selected:(navigation.top + i = navigation.index)) in
    let title = sprintf "Problems*%s (%s): %d/%d [%d/%d]"
      (if details then " details" else "") filter count total
      (if count = 0 then 0 else navigation.index + 1) count in
    let default = if details
      then sprintf "Details %d-%d/%d | j/k scroll; e/Esc back"
        (detail_top + 1) (Int.min (List.length detail_rows) (detail_top + rows))
        (List.length detail_rows)
      else sprintf "%d above, %d below | j/k e Enter a Esc"
        navigation.top (Int.max 0 (count - navigation.top - rows)) in
    { title
    ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default)
    ; body = (if count = 0 then empty else body)
    })
  else (
    let preview = List.take problems rows |> List.map ~f:(fun p -> row (style p) (description p)) in
    (* Overflow is counted in the footer, so it costs no content row. *)
    let footer : Tile_shell.Label.t =
      if count > rows
      then { text = sprintf "+%d more | Space v e: all details" (count - rows); style = Warning }
      else Tile_shell.Label.hint "Space v o: focus | Space v e: details"
    in
    { title = sprintf "Problems (%s): %d/%d" filter count total
    ; footer = Some footer
    ; body = (if count = 0 then empty else preview)
    })
;;
