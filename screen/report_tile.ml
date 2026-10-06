open! Core
module Navigation = Ches_tile.Navigation
module Selection = Navigation.Selection

let id = Ches_tile.View_id.of_string "demo-report"
let spec = Ches_tile.Spec.read_only id ~title:"Demo report"

module Item = struct
  type t =
    { key : string
    ; title : string
    ; body : string
    }
  [@@deriving sexp_of, equal]
end

type t =
  { items : Item.t list
  ; selection : string Selection.t
  ; details : bool
  ; detail_top : int
  }
[@@deriving sexp_of]

let create items = { items; selection = Selection.empty; details = false; detail_top = 0 }

let demo =
  List.init 10 ~f:(fun i ->
    let n = i + 1 in
    { Item.key = sprintf "demo-report/%02d" n
    ; title = sprintf "DEMO REPORT %d/10: static row %d (界🙂 é)" n n
    ; body =
        sprintf
          "Static report item %d. This fixture has no source, file, or problem identity; \
           selecting, scrolling, copying, or hiding it changes nothing else.%s"
          n
          (if n = 10
           then
             " "
             ^ String.concat
                 ~sep:" "
                 (List.init 12 ~f:(fun j ->
                    sprintf "Long detail sentence %d: scroll with j/k or Ctrl-d/u." (j + 1)))
           else "")
    })
;;

let items t = t.items
let selection t = t.selection
let details t = t.details
let detail_top t = t.detail_top
let keys t = List.map t.items ~f:(fun (item : Item.t) -> item.key)

let fit t ~rows =
  let selection = Selection.fit t.selection (keys t) ~equal:String.equal ~rows in
  let changed = not ([%equal: string option] selection.selected t.selection.selected) in
  { t with
    selection
  ; details = t.details && not changed
  ; detail_top = (if changed then 0 else t.detail_top)
  }
;;

let leave t = { t with details = false }
let selected t = List.nth t.items t.selection.index

let detail_rows (item : Item.t) ~width =
  Tile_text.wrap (item.title ^ ": " ^ item.body) ~width
;;

type action =
  | Move of Navigation.Motion.t
  | Toggle_details
  | Close_details
[@@deriving sexp_of]

let interpret (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ Enter ] -> Action Toggle_details
  | [ key ] when Ches_input.Key.equal key (Ches_input.Key.char 'e') -> Action Toggle_details
  | keys -> Ches_tile.Content_key.map (Navigation.interpret keys) ~f:(fun m -> Move m)
;;

let escape t = Option.some_if t.details Close_details
let hint = "Read-only demo report: j/k e/Enter; Escape returns"

let perform t ~rows ~width action =
  let t = fit t ~rows in
  match action with
  | Close_details -> { t with details = false }
  | Toggle_details ->
    { t with details = (not t.details) && Option.is_some (selected t); detail_top = 0 }
  | Move motion when t.details ->
    let total =
      Option.value_map (selected t) ~default:0 ~f:(fun item ->
        List.length (detail_rows item ~width))
    in
    { t with detail_top = Navigation.move_offset t.detail_top ~total ~rows motion }
  | Move motion ->
    { t with
      selection = Selection.move t.selection (keys t) ~equal:String.equal ~rows motion
    ; details = false
    ; detail_top = 0
    }
;;

let render ?(focused = false) ?notice ?pending t ~width ~rows : Tile_shell.Content.t =
  let count = List.length t.items in
  let rows = Int.max 0 rows in
  let empty = if rows > 0 then [ Tile_text.row Status "Empty report" ~width ] else [] in
  if focused
  then (
    let t = fit t ~rows in
    let navigation = t.selection in
    let detail_rows =
      if t.details then Option.value_map (selected t) ~default:[] ~f:(detail_rows ~width) else []
    in
    let detail_top =
      Int.clamp_exn t.detail_top ~min:0 ~max:(Int.max 0 (List.length detail_rows - rows))
    in
    let body =
      if t.details
      then List.take (List.drop detail_rows detail_top) rows
      else if count = 0
      then empty
      else
        List.take (List.drop t.items navigation.top) rows
        |> List.mapi ~f:(fun i (item : Item.t) ->
          Tile_text.item
            Status
            item.title
            ~width
            ~selected:(navigation.top + i = navigation.index))
    in
    let title =
      sprintf
        "Demo report*%s (static): [%d/%d]"
        (if t.details then " details" else "")
        (if count = 0 then 0 else navigation.index + 1)
        count
    in
    let default =
      if t.details
      then
        sprintf
          "Details %d-%d/%d | j/k scroll; e/Esc back"
          (detail_top + 1)
          (Int.min (List.length detail_rows) (detail_top + rows))
          (List.length detail_rows)
      else
        sprintf
          "%d above, %d below | j/k e Esc"
          navigation.top
          (Int.max 0 (count - navigation.top - rows))
    in
    { title; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default); body })
  else
    { title = sprintf "Demo report (static): %d items" count
    ; footer = Some (Tile_shell.Label.hint "Space v D: focus")
    ; body =
        (if count = 0
         then empty
         else
           List.map (List.take t.items rows) ~f:(fun (item : Item.t) ->
             Tile_text.row Status item.title ~width))
    }
;;
