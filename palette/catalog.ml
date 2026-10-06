open! Core
open Ches_input

module Id = struct
  type t = string [@@deriving sexp_of, equal, compare]

  let of_string = Fn.id
  let to_string = Fn.id

  let is_valid t =
    (not (String.is_empty t))
    && String.for_all t ~f:(fun c ->
      Char.is_lowercase c || Char.is_digit c || Char.equal c '.' || Char.equal c '-')
  ;;
end

module Context = struct
  type t = { mode : Ches_core.Mode.t } [@@deriving sexp_of]
end

module Entry = struct
  type t =
    { id : Id.t
    ; title : string
    ; description : string option
    ; keywords : string list
    ; available : (Context.t -> bool[@sexp.opaque])
    ; action : Keymap.Action.t
    }
  [@@deriving sexp_of, fields ~getters]

  let normal_mode_only (context : Context.t) =
    Ches_core.Mode.equal context.mode Normal
  ;;

  let create ~id ~title ?description ?(keywords = []) ?(available = normal_mode_only) action
    =
    { id = Id.of_string id; title; description; keywords; available; action }
  ;;

  let is_available t context = t.available context
end

type t = Entry.t list [@@deriving sexp_of]

let create entries =
  let malformed =
    List.filter_map entries ~f:(fun (entry : Entry.t) ->
      if Id.is_valid entry.id
      then None
      else Some (sprintf "Malformed ID: %S" (Id.to_string entry.id)))
  in
  let duplicates =
    List.map entries ~f:Entry.id
    |> List.find_all_dups ~compare:Id.compare
    |> List.map ~f:(fun id -> sprintf "Duplicate ID: %s" (Id.to_string id))
  in
  let untitled =
    List.filter_map entries ~f:(fun (entry : Entry.t) ->
      if String.is_empty (String.strip entry.title)
      then Some (sprintf "Empty title: %s" (Id.to_string entry.id))
      else None)
  in
  match malformed @ duplicates @ untitled with
  | [] -> Ok entries
  | problems ->
    Or_error.error_s [%message "Invalid command catalog" ~_:(problems : string list)]
;;

let default =
  let editor ~id ~title ?keywords (command : Ches_core.Command.t) =
    Entry.create ~id ~title ?keywords (Editor command)
  in
  let view ~id ~title ?keywords (command : View_command.t) =
    Entry.create ~id ~title ?keywords (View command)
  in
  let numbers = [ "gutter"; "numbering"; "line numbers" ] in
  create
    [ editor ~id:"file.save" ~title:"Save file" ~keywords:[ "write"; "w" ] Save
    ; editor
        ~id:"app.quit"
        ~title:"Quit"
        ~keywords:[ "exit"; "close"; "q" ]
        Quit
    ; editor
        ~id:"app.quit-discarding-changes"
        ~title:"Quit, discarding unsaved changes"
        ~keywords:[ "force quit"; "exit"; "q!" ]
        Force_quit
    ; editor ~id:"edit.undo" ~title:"Undo" ~keywords:[ "revert" ] Undo
    ; editor ~id:"edit.redo" ~title:"Redo" Redo
    ; view
        ~id:"view.toggle-absolute-numbers"
        ~title:"Toggle absolute line numbers"
        ~keywords:(numbers @ [ "number"; "nu" ])
        Toggle_absolute_numbers
    ; view
        ~id:"view.toggle-relative-numbers"
        ~title:"Toggle relative line numbers"
        ~keywords:(numbers @ [ "relativenumber"; "rnu" ])
        Toggle_relative_numbers
    ; view
        ~id:"view.toggle-centered"
        ~title:"Toggle centered layout"
        ~keywords:[ "center"; "full width"; "layout" ]
        Toggle_centered
    ; view
        ~id:"view.toggle-smear"
        ~title:"Toggle animated smear cursor"
        ~keywords:[ "animation"; "cursor trail" ]
        Toggle_smear
    ; view
        ~id:"view.reset-layout"
        ~title:"Reset layout"
        ~keywords:[ "default"; "restore"; "layout" ]
        Reset
    ; view
        ~id:"view.move-tile-left-2"
        ~title:"Move document tile left by 2 columns"
        ~keywords:[ "shift" ]
        (Shift (-2))
    ; view
        ~id:"view.move-tile-right-2"
        ~title:"Move document tile right by 2 columns"
        ~keywords:[ "shift" ]
        (Shift 2)
    ; view
        ~id:"view.move-tile-left-10"
        ~title:"Move document tile left by 10 columns"
        ~keywords:[ "shift" ]
        (Shift (-10))
    ; view
        ~id:"view.move-tile-right-10"
        ~title:"Move document tile right by 10 columns"
        ~keywords:[ "shift" ]
        (Shift 10)
    ; view
        ~id:"view.narrow-tile-10"
        ~title:"Narrow document tile by 10 columns"
        ~keywords:[ "width"; "shrink" ]
        (Adjust_width (-10))
    ; view
        ~id:"view.widen-tile-10"
        ~title:"Widen document tile by 10 columns"
        ~keywords:[ "width"; "grow" ]
        (Adjust_width 10)
    ]
  |> Or_error.ok_exn
;;

let entries = Fn.id
let find t id = List.find t ~f:(fun (entry : Entry.t) -> Id.equal entry.id id)

module Field = struct
  type t =
    | Title
    | Id
    | Keyword
  [@@deriving sexp_of, equal]
end

type result = (Entry.t, Field.t) Fuzzy.Match.t

let fields (entry : Entry.t) : Field.t Fuzzy.Field.t list =
  { tag = Title; text = entry.title; weight = 100 }
  :: { tag = Id; text = Id.to_string entry.id; weight = 80 }
  :: List.map entry.keywords ~f:(fun text -> { Fuzzy.Field.tag = Field.Keyword; text; weight = 70 })
;;

let search t context ~query =
  List.filter t ~f:(fun entry -> Entry.is_available entry context)
  |> List.map ~f:(fun entry -> entry, fields entry)
  |> Fuzzy.rank ~query
;;

let title_positions (result : result) =
  List.find_map result.positions ~f:(fun ((field : _ Fuzzy.Field.t), offsets) ->
    Option.some_if (Field.equal field.tag Title) offsets)
  |> Option.value ~default:[]
;;
