open! Core
open Ches_input
module View_id = Ches_tile.View_id
module Host = Ches_tile.Host

module Placement = struct
  type t = View_command.Placement.t =
    | Hidden
    | Band
    | Tab
    | Split
  [@@deriving sexp_of, equal]
end

module Ask = struct
  type 'action t =
    | Confirm of
        { title : string
        ; message : string
        ; yes : 'action
        ; no : 'action option
        }
    | Prompt of
        { title : string
        ; initial : string
        ; validate : string -> string option
        ; accept : string -> 'action
        ; cancel : 'action option
        }

  module Question = struct
    type t =
      | Confirm of
          { title : string
          ; message : string
          }
      | Prompt of
          { title : string
          ; initial : string
          ; validate : string -> string option
          }
  end

  let question : _ t -> Question.t = function
    | Confirm { title; message; _ } -> Confirm { title; message }
    | Prompt { title; initial; validate; _ } -> Prompt { title; initial; validate }
  ;;
end

module Answer = struct
  type t =
    | Yes
    | No
    | Text of string
  [@@deriving sexp_of, equal]
end

module Outcome = struct
  type 'ask t =
    { controller : Ches_app.Controller.t
    ; effect : Ches_tile.Text_view.Effect.t option
    ; notice : [ `Post of string | `Show of string ] option
    ; return : bool
    ; ask : 'ask option
    }

  let create ?effect ?notice ?(return = false) ?ask controller =
    { controller; effect; notice; return; ask }
  ;;
end

module Adapter = struct
  type ('state, 'action) t =
    { spec : Ches_tile.Spec.t
    ; key : 'state Type_equal.Id.t
    ; fit : 'state -> Ches_app.Controller.t -> rows:int -> width:int -> 'state
    ; leave : 'state -> 'state
    ; text_view : 'state -> Ches_tile.Text_view.t option
    ; interpret : 'state -> Key.t list -> 'action Ches_tile.Content_key.t
    ; escape : 'state -> 'action option
    ; hint : string
    ; perform
      :  'state
      -> Ches_app.Controller.t
      -> rows:int
      -> width:int
      -> 'action
      -> 'state * 'action Ask.t Outcome.t
    ; commands : 'state -> Ches_tile.Local_command.t list
    ; render
      :  'state
      -> Ches_app.Controller.t
      -> hotkey_hints:bool
      -> focused:bool
      -> notice:string option
      -> pending:string option
      -> width:int
      -> rows:int
      -> Tile_shell.Content.t
    }
end

module Entry = struct
  type t =
    | Installed :
        { adapter : ('state, 'action) Adapter.t
        ; state : 'state
        ; placement : Placement.t
        ; pending : 'action Ask.t option
        }
        -> t
    | Unavailable of
        { id : View_id.t
        ; title : string
        ; notice : string
        }

  let install ?(placement = Placement.Hidden) adapter state =
    Installed { adapter; state; placement; pending = None }
  ;;

  let unavailable id ~title ~notice = Unavailable { id; title; notice }

  let id = function
    | Installed { adapter; _ } -> adapter.spec.id
    | Unavailable { id; _ } -> id
  ;;
end

type t = Entry.t list

let create entries =
  match List.find_a_dup (List.map entries ~f:Entry.id) ~compare:View_id.compare with
  | Some id -> raise_s [%message "View_registry.create: duplicate view" (id : View_id.t)]
  | None -> entries
;;

let installed_entries t =
  List.filter t ~f:(function
    | Entry.Installed _ -> true
    | Unavailable _ -> false)
;;

let specs t =
  List.filter_map t ~f:(function
    | Entry.Installed { adapter; _ } -> Some adapter.spec
    | Unavailable _ -> None)
;;

let ids t = List.map (specs t) ~f:(fun (spec : Ches_tile.Spec.t) -> spec.id)
let installed t id = List.mem (ids t) id ~equal:View_id.equal

let unavailable_notice t id =
  List.find_map t ~f:(function
    | Entry.Unavailable { id = other; notice; _ } when View_id.equal id other -> Some notice
    | Installed _ | Unavailable _ -> None)
;;

let placements t =
  List.filter_map t ~f:(function
    | Entry.Installed { adapter; placement; _ } -> Some (adapter.spec.id, placement)
    | Unavailable _ -> None)
;;

let placement t id = List.Assoc.find (placements t) id ~equal:View_id.equal

let placed t wanted =
  List.filter_map (placements t) ~f:(fun (id, placement) ->
    Option.some_if (Placement.equal placement wanted) id)
;;

let band t = placed t Band
let tabs t = placed t Tab
let split t = List.hd (placed t Split)

let find_installed_entry t id =
  List.find (installed_entries t) ~f:(fun entry -> View_id.equal (Entry.id entry) id)
;;

(* Replace the installed entry for [id]; others are kept, in order. *)
let update t id ~f =
  List.map t ~f:(fun (entry : Entry.t) ->
    match entry with
    | Installed _ when View_id.equal (Entry.id entry) id -> f entry
    | Installed _ | Unavailable _ -> entry)
;;

let place t id placement =
  update t id ~f:(function
    | Installed entry -> Installed { entry with placement }
    | Unavailable _ as entry -> entry)
;;

let leave t id =
  update t id ~f:(function
    | Installed ({ adapter; state; _ } as entry) ->
      Installed { entry with state = adapter.leave state; pending = None }
    | Unavailable _ as entry -> entry)
;;

let withdraw t id =
  update t id ~f:(function
    | Installed entry -> Installed { entry with pending = None }
    | Unavailable _ as entry -> entry)
;;

let asking t id =
  Option.bind (find_installed_entry t id) ~f:(function
    | Entry.Installed { pending; _ } -> Option.map pending ~f:Ask.question
    | Unavailable _ -> None)
;;

let close t id = leave (place t id Hidden) id

let set_placement t id placement =
  let t =
    match placement, split t with
    | Placement.Split, Some other
      when installed t id && not (View_id.equal other id) -> close t other
    | (Hidden | Band | Tab | Split), _ -> t
  in
  place t id placement
;;

let fit t controller ~viewport =
  List.map t ~f:(function
    | Entry.Installed ({ adapter; state; _ } as entry) ->
      let rows, width = viewport adapter.spec.id in
      Entry.Installed { entry with state = adapter.fit state controller ~rows ~width }
    | Unavailable _ as entry -> entry)
;;

let find_installed = find_installed_entry

let text_view t id =
  Option.bind (find_installed t id) ~f:(function
    | Installed { adapter; state; _ } -> adapter.text_view state
    | Unavailable _ -> None)
;;

let commands t id =
  Option.value_map (find_installed t id) ~default:[] ~f:(function
    | Installed { adapter; state; _ } -> adapter.commands state
    | Unavailable _ -> [])
;;

let render t id controller ~hotkey_hints ~focused ~notice ~pending ~width ~rows =
  Option.bind (find_installed t id) ~f:(function
    | Installed { adapter; state; _ } ->
      Some
        (adapter.render state controller ~hotkey_hints ~focused ~notice ~pending ~width ~rows)
    | Unavailable _ -> None)
;;

(* What the application sees of an outcome: the question alone. The entry keeps the
   actions its answers perform. *)
let question (outcome : _ Ask.t Outcome.t) =
  { outcome with ask = Option.map outcome.ask ~f:Ask.question }
;;

module Step = struct
  type t =
    | Handled
    | Return
    | Notice of string
    | Workspace of View_command.t
    | Help
    | Performed of Ask.Question.t Outcome.t
end

(* The view's action, or [?] when the view leaves it unbound. *)
type 'action keyed =
  | Act of 'action
  | Help

let is_help = function
  | [ key ] -> Key.equal key (Key.char '?')
  | _ -> false
;;

let key t id host key ~lookup ~controller ~rows ~width =
  Option.map (find_installed t id) ~f:(function
    | Unavailable _ -> t, host, Step.Return
    | Installed ({ adapter; state; _ } as entry) ->
      let content keys : _ Ches_tile.Content_key.t =
        match adapter.interpret state keys with
        | Unbound when is_help keys -> Action Help
        | result -> Ches_tile.Content_key.map result ~f:(fun action -> Act action)
      in
      let host, (decision : _ Host.Decision.t) =
        Host.key
          host
          key
          ~lookup
          ~content
          ~escape:(Option.map (adapter.escape state) ~f:(fun action -> Act action))
          ~hint:adapter.hint
      in
      (match decision with
       | Handled -> t, host, Step.Handled
       | Return -> t, host, Step.Return
       | Notice text -> t, host, Step.Notice text
       | Workspace view -> t, host, Step.Workspace view
       | Content Help -> t, host, Step.Help
       | Content (Act action) ->
         let state, outcome = adapter.perform state controller ~rows ~width action in
         let t = update t id ~f:(fun _ -> Installed { entry with state; pending = outcome.ask }) in
         t, host, Step.Performed (question outcome)))
;;

let run t id name ~controller ~rows ~width =
  match find_installed t id with
  | None | Some (Unavailable _) ->
    Or_error.error_s [%message "View not installed" (id : View_id.t)]
  | Some (Installed ({ adapter; state; _ } as entry)) ->
    let unavailable () =
      Or_error.error_string
        (sprintf "%s: %s unavailable here; nothing ran" adapter.spec.title name)
    in
    (match
       List.find (adapter.commands state) ~f:(fun (command : Ches_tile.Local_command.t) ->
         String.equal command.name name)
     with
     | None -> unavailable ()
     | Some command ->
       (match adapter.interpret state command.keys with
        | Prefix | Unbound -> unavailable ()
        | Action action ->
          let state, outcome = adapter.perform state controller ~rows ~width action in
          Ok
            ( update t id ~f:(fun _ -> Installed { entry with state; pending = outcome.ask })
            , question outcome )))
;;

let answer t id (answer : Answer.t) ~controller ~rows ~width =
  match find_installed t id with
  | None | Some (Unavailable _) -> t, None
  | Some (Installed ({ adapter; state; pending; _ } as entry)) ->
    let action =
      match pending, answer with
      | None, _ -> `Keep
      | Some (Confirm { yes; _ }), Yes -> `Perform (Some yes)
      | Some (Confirm { no; _ }), (No | Text _) -> `Perform no
      | Some (Prompt { validate; accept; _ }), Text text ->
        if Option.is_some (validate text) then `Keep else `Perform (Some (accept text))
      | Some (Prompt { cancel; _ }), (Yes | No) -> `Perform cancel
    in
    (match action with
     | `Keep -> t, None
     | `Perform None -> update t id ~f:(fun _ -> Installed { entry with pending = None }), None
     | `Perform (Some action) ->
       let state, outcome = adapter.perform state controller ~rows ~width action in
       ( update t id ~f:(fun _ -> Installed { entry with state; pending = outcome.ask })
       , Some (question outcome) ))
;;

let find (type state) t (key : state Type_equal.Id.t) : state option =
  List.find_map t ~f:(fun (entry : Entry.t) : state option ->
    match entry with
    | Installed { adapter; state; _ } ->
      (match Type_equal.Id.same_witness adapter.key key with
       | Some Type_equal.T -> Some state
       | None -> None)
    | Unavailable _ -> None)
;;

let map (type state) t (key : state Type_equal.Id.t) ~(f : state -> state) =
  List.map t ~f:(function
    | Entry.Installed ({ adapter; state; _ } as entry) ->
      (match Type_equal.Id.same_witness adapter.key key with
       | Some Type_equal.T -> Entry.Installed { entry with state = f state }
       | None -> Entry.Installed entry)
    | Unavailable _ as entry -> entry)
;;
