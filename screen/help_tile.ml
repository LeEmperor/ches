open! Core
module Local_command = Ches_tile.Local_command
module Navigation = Ches_tile.Navigation

let id = Ches_tile.View_id.of_string "help"
let spec = Ches_tile.Spec.read_only id ~title:"Help"

type t =
  { origin : Ches_tile.View_id.t
  ; title : string
  ; commands : Local_command.t list
  ; top : int
  }
[@@deriving sexp_of]

let create ~origin ~title commands = { origin; title; commands; top = 0 }
let origin t = t.origin
let commands t = t.commands
let top t = t.top

let keys_width t =
  List.fold t.commands ~init:0 ~f:(fun width command ->
    Int.max width (String.length (Local_command.keys_hum command)))
;;

let preferred_size t : Floating.Size.t =
  let widest =
    List.fold t.commands ~init:0 ~f:(fun width (command : Local_command.t) ->
      Int.max width (String.length command.description))
  in
  (* Frame, padding, the key column and its gap, and the description. *)
  { width = Int.max 32 (keys_width t + widest + 6)
  ; height = List.length t.commands + 2
  }
;;

type action =
  | Scroll of Navigation.Motion.t
  | Close
[@@deriving sexp_of]

let interpret (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ key ]
    when Ches_input.Key.equal key (Ches_input.Key.char 'q')
         || Ches_input.Key.equal key (Ches_input.Key.char '?') -> Action Close
  | keys -> Ches_tile.Content_key.map (Navigation.interpret keys) ~f:(fun m -> Scroll m)
;;

let hint = "Read-only help: j/k scroll; q, ? or Escape closes"

let scroll t ~rows motion =
  { t with
    top = Navigation.move_offset t.top ~total:(List.length t.commands) ~rows motion
  }
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let rows = Int.max 0 rows in
  let count = List.length t.commands in
  let top = Int.clamp_exn t.top ~min:0 ~max:(Int.max 0 (count - rows)) in
  let column = keys_width t in
  let body =
    if count = 0
    then List.take [ Tile_text.row Stale "No view-local commands" ~width ] rows
    else
      List.take (List.drop t.commands top) rows
      |> List.map ~f:(fun (command : Local_command.t) ->
        Tile_text.row
          Status
          (sprintf "%-*s  %s" column (Local_command.keys_hum command) command.description)
          ~width)
  in
  { title = sprintf "%s keys" t.title
  ; footer =
      Some
        (Tile_shell.Label.footer
           ~notice
           ~pending:None
           ~default:
             (sprintf
                "%d above, %d below%s"
                top
                (Int.max 0 (count - top - rows))
                (if hotkey_hints then " | j/k q Esc" else "")))
  ; body
  }
;;
