open! Core
module Navigation = Ches_tile.Navigation
module Selection = Navigation.Selection
module Text_view = Ches_tile.Text_view

let id = Ches_tile.View_id.of_string "demo-report"
let spec = Ches_tile.Spec.read_only_text id ~title:"Demo report"

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
  ; details : Text_view.t option (** The selected item's text, while open. *)
  }
[@@deriving sexp_of]

let create items = { items; selection = Selection.empty; details = None }

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
let details t = Option.is_some t.details
let detail_top t = Option.value_map t.details ~default:0 ~f:Text_view.top
let text_view t = t.details
let keys t = List.map t.items ~f:(fun (item : Item.t) -> item.key)

(* An item's canonical text: what its details show and what copying it copies. *)
let item_text (item : Item.t) = item.title ^ ": " ^ item.body

let fit t ~rows ~width =
  let selection = Selection.fit t.selection (keys t) ~equal:String.equal ~rows in
  let changed = not ([%equal: string option] selection.selected t.selection.selected) in
  { t with
    selection
  ; details =
      (if changed then None else Option.map t.details ~f:(Text_view.fit ~width ~rows))
  }
;;

let leave t = { t with details = None }
let selected t = List.nth t.items t.selection.index

type action =
  | Move of Navigation.Motion.t
  | Toggle_details
  | Close_details
  | Copy_item
  | Edit
  | Text of Text_view.Action.t
[@@deriving sexp_of]

let interpret t (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  match keys, t.details with
  | [ Enter ], _ -> Action Toggle_details
  | [ key ], _ when Ches_input.Key.equal key (Ches_input.Key.char 'e') -> Action Toggle_details
  | keys, Some view -> Ches_tile.Content_key.map (Text_view.interpret view keys) ~f:(fun a -> Text a)
  | keys, None ->
    (match Navigation.interpret keys with
     | Unbound ->
       Ches_tile.Content_key.map (Text_view.interpret_item keys) ~f:(function
         | `Copy -> Copy_item
         | `Edit -> Edit)
     | motion -> Ches_tile.Content_key.map motion ~f:(fun m -> Move m))
;;

let escape t =
  Option.map t.details ~f:(fun view ->
    Option.value_map (Text_view.escape view) ~default:Close_details ~f:(fun a -> Text a))
;;

let hint = "Read-only demo report: j/k e/Enter yy; Escape returns"

let perform t ~rows ~width action =
  let t = fit t ~rows ~width in
  match action, t.details with
  | Close_details, _ -> { t with details = None }, None
  | Toggle_details, Some _ -> { t with details = None }, None
  | Toggle_details, None ->
    ( { t with
        details =
          Option.map (selected t) ~f:(fun item ->
            Text_view.create ~cell_width:Cell_map.width (item_text item))
      }
    , None )
  | Text action, Some view ->
    let view, effect = Text_view.perform view ~width ~rows action in
    { t with details = Some view }, effect
  | Text _, None -> t, None
  | Copy_item, _ ->
    ( t
    , Some
        (Option.value_map (selected t) ~default:(Text_view.Effect.Notice "nothing to copy")
           ~f:(fun item -> Text_view.copy_item (item_text item))) )
  | Edit, _ -> t, Some (Notice Text_view.read_only)
  | Move motion, _ ->
    ( { t with
        selection = Selection.move t.selection (keys t) ~equal:String.equal ~rows motion
      ; details = None
      }
    , None )
;;

let render ?(focused = false) ?notice ?pending t ~width ~rows : Tile_shell.Content.t =
  let count = List.length t.items in
  let rows = Int.max 0 rows in
  let empty = if rows > 0 then [ Tile_text.row Status "Empty report" ~width ] else [] in
  if focused
  then (
    let t = fit t ~rows ~width in
    let navigation = t.selection in
    let body =
      match t.details with
      | Some view -> Tile_text.text_view view ~width ~rows
      | None when count = 0 -> empty
      | None ->
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
        (if Option.is_some t.details then " details" else "")
        (if count = 0 then 0 else navigation.index + 1)
        count
    in
    let default =
      match t.details with
      | Some view -> Tile_text.text_footer view ~width ~rows
      | None ->
        sprintf
          "%d above, %d below | j/k e yy Esc"
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
