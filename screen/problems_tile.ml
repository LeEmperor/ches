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
  ; selection : Feedback.Identity.t Selection.t
  ; details : Text_view.t option (** The selected problem's description, while open. *)
  }
[@@deriving sexp_of]

let empty = { current_document = false; selection = Selection.empty; details = None }
let current_document t = t.current_document
let toggle_filter t = { t with current_document = not t.current_document }
let selection t = t.selection
let details t = Option.is_some t.details
let detail_top t = Option.value_map t.details ~default:0 ~f:Text_view.top
let text_view t = t.details

let entries t feedback ~path =
  Problems.entries feedback ~current_document:t.current_document ~path
;;

let keys t feedback ~path =
  List.map (entries t feedback ~path) ~f:(fun (p : Feedback.Problem.t) -> p.identity)
;;

let fit t feedback ~path ~rows ~width =
  let entries = entries t feedback ~path in
  let selection =
    Selection.fit t.selection
      (List.map entries ~f:(fun (p : Feedback.Problem.t) -> p.identity))
      ~equal:Feedback.Identity.equal ~rows
  in
  let changed =
    not ([%equal: Feedback.Identity.t option] selection.selected t.selection.selected)
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

let selected t feedback ~path ~rows =
  List.nth (entries t feedback ~path)
    (Selection.fit t.selection (keys t feedback ~path) ~equal:Feedback.Identity.equal ~rows)
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
  let t = fit t feedback ~path ~rows ~width in
  let selected = List.nth (entries t feedback ~path) t.selection.index in
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
          Selection.move t.selection (keys t feedback ~path) ~equal:Feedback.Identity.equal
            ~rows motion
      ; details = None
      }
  | (Inspect | Acknowledge | Jump | Copy_item), None -> post "No problem selected"
  | Copy_item, Some problem ->
    outcome t ~effect:(Text_view.copy_item (Problems.description problem))
  | Inspect, Some problem ->
    outcome
      ~controller:(Controller.update_feedback controller (Inspect_identity problem.identity))
      { t with
        details =
          (match t.details with
           | Some _ -> None
           | None ->
             Some (Text_view.create ~cell_width:Cell_map.width (Problems.description problem)))
      }
  | Acknowledge, Some problem ->
    outcome t
      ~controller:(Controller.update_feedback controller (Acknowledge_identity problem.identity))
      ~notice:(`Show "Acknowledged; problem remains active")
  | Jump, Some problem ->
    if not (Option.value_map path ~default:false ~f:(String.equal problem.identity.resource))
    then post "Cross-file jump unavailable; current document kept"
    else (
      match problem.location with
      | None -> post "This problem has no document location"
      | Some location ->
        (match Controller.jump controller ~line:location.line ~column:location.column with
         | Error error -> post (Error.to_string_hum error)
         | Ok controller -> outcome t ~controller ~return:true))
;;
