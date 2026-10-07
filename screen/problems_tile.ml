open! Core
open Ches_core
open Ches_app
module Feedback = Ches_error.Error
module Navigation = Ches_tile.Navigation
module Selection = Navigation.Selection
module Text_view = Ches_tile.Text_view

let id = Ches_tile.View_id.of_string "problems"
let spec = Ches_tile.Spec.read_only_text id ~title:"Problems"

type t =
  { current_document : bool
  ; selection : Problems.Key.t Selection.t
  ; details : Text_view.t option (** The selected row's description, while open. *)
  ; anchor_texts : ((string * string) * (Text_buffer.t[@sexp.opaque])) list
  (** Per source, the open document's text when its list for it was applied. *)
  }
[@@deriving sexp_of]

let empty =
  { current_document = false
  ; selection = Selection.empty
  ; details = None
  ; anchor_texts = []
  }
;;

let applied t ~source ~resource ~text =
  { t with anchor_texts = List.Assoc.add t.anchor_texts ~equal:[%equal: string * string] (source, resource) text }
;;
let forget_resource t resource =
  { t with anchor_texts = List.filter t.anchor_texts ~f:(fun ((_, r), _) -> not (Problems.Document.same_resource r resource)) }
;;

let document t editor = Problems.Document.of_editor editor ~anchor_text:(fun source ->
  Option.bind (Editor.path editor) ~f:(fun resource ->
    List.find_map t.anchor_texts ~f:(fun ((s, r), text) ->
      Option.some_if (String.equal s source && Problems.Document.same_resource r resource) text)))
let current_document t = t.current_document
let toggle_filter t = { t with current_document = not t.current_document }
let selection t = t.selection
let details t = Option.is_some t.details
let detail_top t = Option.value_map t.details ~default:0 ~f:Text_view.top
let text_view t = t.details

let entries t feedback ~document =
  Problems.entries feedback ~current_document:t.current_document ~document
;;

let keys t feedback ~document =
  List.map (entries t feedback ~document) ~f:(fun (r : Problems.Row.t) -> r.key)
;;

let fit t feedback ~document ~rows ~width =
  let entries = entries t feedback ~document in
  let selection =
    Selection.fit t.selection
      (List.map entries ~f:(fun (r : Problems.Row.t) -> r.key))
      ~equal:Problems.Key.equal ~rows
  in
  let changed =
    not ([%equal: Problems.Key.t option] selection.selected t.selection.selected)
  in
  let details =
    match t.details, List.nth entries selection.index with
    | Some view, Some problem when not changed ->
      (* The same problem with new text: the view decides what survives. *)
      Some (Text_view.fit (fst (Text_view.update view (Problems.description problem))) ~width ~rows)
    | Some _, _ | None, _ -> None
  in
  { t with selection; details }
;;

let selected t feedback ~document ~rows =
  List.nth (entries t feedback ~document)
    (Selection.fit t.selection (keys t feedback ~document) ~equal:Problems.Key.equal ~rows)
      .index
;;

let leave t = { t with details = None }

type action =
  | Move of Navigation.Motion.t
  | Inspect
  | Acknowledge
  | Jump
  | Close_details
  | Copy_item
  | Edit
  | Text of Text_view.Action.t
[@@deriving sexp_of]

let interpret t (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  let is c key = Ches_input.Key.equal key (Ches_input.Key.char c) in
  match keys, t.details with
  | [ Enter ], _ -> Action Jump
  | [ key ], _ when is 'e' key -> Action Inspect
  | [ key ], _ when is 'a' key -> Action Acknowledge
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

let hint = "Read-only problems: j/k e Enter a yy; Escape returns"

module Outcome = struct
  type nonrec t =
    { tile : t
    ; controller : Controller.t
    ; notice : [ `Post of string | `Show of string ] option
    ; effect : Text_view.Effect.t option
    ; return : bool
    }
end

let perform t controller ~rows ~width action : Outcome.t =
  let feedback = Controller.feedback controller in
  let editor = Controller.editor controller in
  let path = Editor.path editor in
  let document = document t editor in
  let t = fit t feedback ~document ~rows ~width in
  let selected = List.nth (entries t feedback ~document) t.selection.index in
  let outcome ?notice ?effect ?(return = false) ?(controller = controller) tile =
    { Outcome.tile; controller; notice; effect; return }
  in
  let post text = outcome t ~notice:(`Post text) in
  match action, selected with
  | Close_details, _ -> outcome { t with details = None }
  | Text action, _ ->
    (match t.details with
     | None -> outcome t
     | Some view ->
       let view, effect = Text_view.perform view ~width ~rows action in
       outcome { t with details = Some view } ?effect)
  | Edit, _ -> outcome t ~effect:(Notice Text_view.read_only)
  | Move motion, _ ->
    outcome
      { t with
        selection =
          Selection.move t.selection (keys t feedback ~document) ~equal:Problems.Key.equal
            ~rows motion
      ; details = None
      }
  | (Inspect | Acknowledge | Jump | Copy_item), None -> post "No problem selected"
  | Copy_item, Some problem ->
    outcome t ~effect:(Text_view.copy_item (Problems.description problem))
  | Inspect, Some problem ->
    outcome
      ~controller:
        (match problem.kind with
         | Problem p -> Controller.update_feedback controller (Inspect_identity p.identity)
         | Finding _ -> controller)
      { t with
        details =
          (match t.details with
           | Some _ -> None
           | None ->
             Some (Text_view.create ~cell_width:Cell_map.width (Problems.description problem)))
      }
  | Acknowledge, Some { kind = Finding _; _ } ->
    outcome t ~notice:(`Show "Diagnostics are not acknowledged")
  | Acknowledge, Some { kind = Problem problem; _ } ->
    outcome t
      ~controller:(Controller.update_feedback controller (Acknowledge_identity problem.identity))
      ~notice:(`Show "Acknowledged; problem remains active")
  | Jump, Some problem ->
    if not (Option.value_map path ~default:false ~f:(Problems.Document.same_resource problem.resource))
    then post "Cross-file jump unavailable; current document kept"
    else (
      match problem.location with
      | None -> post "This problem has no document location"
      | Some location ->
        (match Controller.jump controller ~line:location.line ~column:location.column with
         | Error error -> post (Error.to_string_hum error)
         | Ok controller -> outcome t ~controller ~return:true))
;;
