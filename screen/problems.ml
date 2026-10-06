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

let style (p : Feedback.Problem.t) : Style.t =
  match p.severity with
  | Info -> Info
  | Warning -> Warning
  | Error -> Error
;;

let render ?(focused = false) ?(navigation = Selection.empty)
  ?details ?notice ?pending
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
    let body = match details with
      | Some view -> Tile_text.text_view view ~width ~rows
      | None ->
        List.take (List.drop problems navigation.top) rows
        |> List.mapi ~f:(fun i p -> Tile_text.item (style p) (description p) ~width
          ~selected:(navigation.top + i = navigation.index)) in
    let title = sprintf "Problems*%s (%s): %d/%d [%d/%d]"
      (if Option.is_some details then " details" else "") filter count total
      (if count = 0 then 0 else navigation.index + 1) count in
    let default = match details with
      | Some view -> Tile_text.text_footer view ~width ~rows
      | None -> sprintf "%d above, %d below | j/k e Enter a yy Esc"
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
