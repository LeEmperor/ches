open! Core
module Feedback = Ches_error.Error
module History = Feedback.History
module Navigation = Ches_tile.Navigation
module Selection = Navigation.Selection
module Text_view = Ches_tile.Text_view

let id = Ches_tile.View_id.of_string "history"
let spec = Ches_tile.Spec.read_only_text id ~title:"History"

type t =
  { selection : int Selection.t
  ; follow : bool (** Select the newest entry, until the user moves or opens one. *)
  ; details : Text_view.t option (** The selected entry's description, while open. *)
  }
[@@deriving sexp_of]

let empty = { selection = Selection.empty; follow = true; details = None }
let selection t = t.selection
let details t = Option.is_some t.details
let text_view t = t.details
let keys history = List.map (History.entries history) ~f:(fun (e : History.Entry.t) -> e.seq)

let severity_name : Feedback.Severity.t -> string = function
  | Hint -> "hint"
  | Info -> "info"
  | Warning -> "warning"
  | Error -> "error"
;;

let description ({ seq; event; count } : History.Entry.t) =
  let count = if count > 1 then sprintf " ×%d" count else "" in
  let identity (identity : Feedback.Identity.t) =
    let kind =
      match identity.kind with
      | Save -> "save"
      | Reload -> "reload"
    in
    sprintf "[%s %s] %s" identity.source kind identity.resource
  in
  match event with
  | Notified n ->
    sprintf
      "#%d%s %s [%s]%s: %s"
      seq
      count
      (severity_name n.severity)
      n.source
      (Option.value_map n.scope ~default:"" ~f:(fun scope -> " " ^ scope))
      n.text
  | Reported { identity = i; severity; text; location; again } ->
    sprintf
      "#%d%s %s problem%s %s%s: %s"
      seq
      count
      (severity_name severity)
      (if again then " again" else "")
      (identity i)
      (Option.value_map location ~default:"" ~f:(fun l -> sprintf ":%d:%d" l.line l.column))
      text
  | Resolved { identity = i; severity = _; text } ->
    sprintf "#%d%s resolved %s (was: %s)" seq count (identity i) text
;;

let style ({ event; _ } : History.Entry.t) : Style.t =
  match event with
  | Notified { severity; _ } | Reported { severity; _ } ->
    (match severity with
     | Hint -> Severity_hint
     | Info -> Info
     | Warning -> Warning
     | Error -> Error)
  | Resolved _ -> Info
;;

(* The adapter's reconciliation: the newest entry while following, the oldest
   retained one when the selected entry was evicted, and otherwise the same entry. *)
let fit_selection selection ~follow history ~rows =
  let keys = keys history in
  match selection.Selection.selected, keys with
  | _, [] -> Selection.empty
  | _ when follow ->
    Selection.select selection keys ~equal:Int.equal ~rows (List.length keys - 1)
  | Some seq, first :: _ when seq < first ->
    Selection.select selection keys ~equal:Int.equal ~rows 0
  | (Some _ | None), _ -> Selection.fit selection keys ~equal:Int.equal ~rows
;;

let selected_entry selection history =
  Option.bind selection.Selection.selected ~f:(fun seq ->
    List.find (History.entries history) ~f:(fun (e : History.Entry.t) -> e.seq = seq))
;;

let fit t history ~rows ~width =
  let selection = fit_selection t.selection ~follow:t.follow history ~rows in
  let changed = not ([%equal: int option] selection.selected t.selection.selected) in
  let details =
    match t.details, selected_entry selection history with
    | Some view, Some entry when not changed ->
      (* The same entry with new text (a merged repeat): the view decides what
         survives. *)
      Some (Text_view.fit (fst (Text_view.update view (description entry))) ~width ~rows)
    | Some _, _ | None, _ -> None
  in
  { t with selection; details }
;;

let leave _ = empty

type action =
  | Move of Navigation.Motion.t
  | Toggle_details
  | Close_details
  | Clear
  | Copy_item
  | Edit
  | Text of Text_view.Action.t
[@@deriving sexp_of]

let interpret t (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  let is c key = Ches_input.Key.equal key (Ches_input.Key.char c) in
  match keys, t.details with
  | [ Enter ], _ -> Action Toggle_details
  | [ key ], _ when is 'e' key -> Action Toggle_details
  | [ key ], _ when is 'X' key -> Action Clear
  | keys, Some view ->
    Ches_tile.Content_key.map (Text_view.interpret view keys) ~f:(fun a -> Text a)
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

let hint = "Read-only history: j/k e/Enter yy X; Escape returns"

module Outcome = struct
  type nonrec t =
    { tile : t
    ; effect : Text_view.Effect.t option
    ; clear : bool
    }
end

let perform t history ~rows ~width action : Outcome.t =
  let t = fit t history ~rows ~width in
  let outcome ?effect ?(clear = false) tile = { Outcome.tile; effect; clear } in
  match action with
  | Close_details -> outcome { t with details = None }
  | Clear -> outcome empty ~clear:true
  | Toggle_details ->
    (match t.details, selected_entry t.selection history with
     | Some _, _ -> outcome { t with details = None }
     | None, None -> outcome t ~effect:(Notice "nothing selected")
     | None, Some entry ->
       outcome
         { t with
           follow = false
         ; details = Some (Text_view.create ~cell_width:Cell_map.width (description entry))
         })
  | Text action ->
    (match t.details with
     | None -> outcome t
     | Some view ->
       let view, effect = Text_view.perform view ~width ~rows action in
       outcome { t with details = Some view } ?effect)
  | Copy_item ->
    outcome
      t
      ~effect:
        (Option.value_map
           (selected_entry t.selection history)
           ~default:(Text_view.Effect.Notice "nothing to copy")
           ~f:(fun entry -> Text_view.copy_item (description entry)))
  | Edit -> outcome t ~effect:(Notice Text_view.read_only)
  | Move motion ->
    outcome
      { selection = Selection.move t.selection (keys history) ~equal:Int.equal ~rows motion
      ; follow = false
      ; details = None
      }
;;

let render ?(hotkey_hints = false) ?(focused = false) ?notice ?pending
  t history ~width ~rows : Tile_shell.Content.t =
  let entries = History.entries history in
  let count = List.length entries in
  let rows = Int.max 0 rows in
  let dropped =
    match History.dropped history with
    | 0 -> ""
    | n -> sprintf ", %d dropped" n
  in
  let empty = if rows > 0 then [ Tile_text.row Status "No history" ~width ] else [] in
  if focused
  then (
    let t = fit t history ~rows ~width in
    let navigation = t.selection in
    let body =
      match t.details with
      | Some view -> Tile_text.text_view view ~width ~rows
      | None when count = 0 -> empty
      | None ->
        List.take (List.drop entries navigation.top) rows
        |> List.mapi ~f:(fun i entry ->
          Tile_text.item
            (style entry)
            (description entry)
            ~width
            ~selected:(navigation.top + i = navigation.index))
    in
    let title =
      sprintf
        "History*%s: [%d/%d%s]"
        (if Option.is_some t.details then " details" else "")
        (if count = 0 then 0 else navigation.index + 1)
        count
        dropped
    in
    let default =
      match t.details with
      | Some view -> Tile_text.text_footer ~hotkey_hints view ~width ~rows
      | None ->
        sprintf
          "%d above, %d below%s"
          navigation.top
          (Int.max 0 (count - navigation.top - rows))
          (if hotkey_hints then " | j/k e yy X Esc" else "")
    in
    { title; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default); body })
  else (
    (* The newest entries that fit, still oldest first, like a log's tail. *)
    let shown = List.drop entries (Int.max 0 (count - rows)) in
    let footer =
      if count > rows
      then sprintf "+%d earlier%s" (count - rows)
        (if hotkey_hints then " | Space v M: focus" else "")
      else if hotkey_hints then "Space v M: focus" else ""
    in
    { title = sprintf "History: %d entr%s%s" count (if count = 1 then "y" else "ies") dropped
    ; footer = Some (Tile_shell.Label.hint footer)
    ; body =
        (if count = 0
         then empty
         else
           List.map shown ~f:(fun entry ->
             Tile_text.row (style entry) (description entry) ~width))
    })
;;
