open! Core
open Ches_core
open Ches_app
module Feedback = Ches_error.Error
module Navigation = Ches_tile.Navigation
module Selection = Navigation.Selection

let id = Ches_tile.View_id.of_string "problems"
let spec = Ches_tile.Spec.read_only id ~title:"Problems"

type t =
  { current_document : bool
  ; selection : Feedback.Identity.t Selection.t
  ; details : bool
  ; detail_top : int
  }
[@@deriving sexp_of]

let empty =
  { current_document = false; selection = Selection.empty; details = false; detail_top = 0 }
;;

let current_document t = t.current_document
let toggle_filter t = { t with current_document = not t.current_document }
let selection t = t.selection
let details t = t.details
let detail_top t = t.detail_top

let entries t feedback ~path =
  Problems.entries feedback ~current_document:t.current_document ~path
;;

let keys t feedback ~path =
  List.map (entries t feedback ~path) ~f:(fun (p : Feedback.Problem.t) -> p.identity)
;;

let fit t feedback ~path ~rows =
  let selection =
    Selection.fit t.selection (keys t feedback ~path) ~equal:Feedback.Identity.equal ~rows
  in
  let changed =
    not ([%equal: Feedback.Identity.t option] selection.selected t.selection.selected)
  in
  { t with
    selection
  ; details = t.details && not changed
  ; detail_top = (if changed then 0 else t.detail_top)
  }
;;

let selected t feedback ~path ~rows =
  List.nth (entries t feedback ~path) (fit t feedback ~path ~rows).selection.index
;;

let leave t = { t with details = false }

type action =
  | Move of Navigation.Motion.t
  | Inspect
  | Acknowledge
  | Jump
  | Close_details
[@@deriving sexp_of]

let interpret (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ Enter ] -> Action Jump
  | [ key ] when Ches_input.Key.equal key (Ches_input.Key.char 'e') -> Action Inspect
  | [ key ] when Ches_input.Key.equal key (Ches_input.Key.char 'a') -> Action Acknowledge
  | keys -> Ches_tile.Content_key.map (Navigation.interpret keys) ~f:(fun m -> Move m)
;;

let escape t = Option.some_if t.details Close_details
let hint = "Read-only problems: j/k e Enter a; Escape returns"

module Outcome = struct
  type nonrec t =
    { tile : t
    ; controller : Controller.t
    ; notice : [ `Post of string | `Show of string ] option
    ; return : bool
    }
end

let perform t controller ~rows ~width action : Outcome.t =
  let feedback = Controller.feedback controller in
  let editor = Controller.editor controller in
  let path = Editor.path editor in
  let t = fit t feedback ~path ~rows in
  let selected = List.nth (entries t feedback ~path) t.selection.index in
  let outcome ?notice ?(return = false) ?(controller = controller) tile =
    { Outcome.tile; controller; notice; return }
  in
  let post text = outcome t ~notice:(`Post text) in
  match action, selected with
  | Close_details, _ -> outcome { t with details = false }
  | Move motion, _ when t.details ->
    let total = Option.value_map selected ~default:0 ~f:(fun p ->
      List.length (Problems.detail_rows p ~width)) in
    outcome { t with detail_top = Navigation.move_offset t.detail_top ~total ~rows motion }
  | Move motion, _ ->
    outcome
      { t with
        selection =
          Selection.move t.selection (keys t feedback ~path) ~equal:Feedback.Identity.equal
            ~rows motion
      ; details = false
      ; detail_top = 0
      }
  | (Inspect | Acknowledge | Jump), None -> post "No problem selected"
  | Inspect, Some problem ->
    outcome
      ~controller:(Controller.update_feedback controller (Inspect_identity problem.identity))
      { t with details = not t.details; detail_top = 0 }
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
