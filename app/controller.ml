open! Core
open Ches_core
open Ches_input

module Status = struct
  type t =
    | Running
    | Exit
  [@@deriving sexp_of, equal]
end

type t =
  { editor : Editor.t
  ; keymap : Keymap.t
  ; dispatched : bool
  ; clipboard : string option (** The newest [Set_clipboard] not yet taken. *)
  }

let create ?(keymap_config = Keymap.Config.default) editor =
  { editor; keymap = Keymap.create keymap_config; dispatched = false; clipboard = None }
;;

let open_file ?keymap_config ~cell_width path =
  match File_io.read path with
  | Error error ->
    Or_error.error_string
      (sprintf "Cannot open %s: %s" path (Error.to_string_hum error))
  | Ok (Existing text) -> Ok (create ?keymap_config (Editor.create ~path ~cell_width text))
  | Ok Missing -> Ok (create ?keymap_config (Editor.create ~path ~cell_width Text_buffer.empty))
;;

let editor t = t.editor
let keymap t = t.keymap
let last_input_dispatched t = t.dispatched
let take_clipboard t = { t with clipboard = None }, t.clipboard

let perform editor (effect : Effect.t) ~clipboard : Editor.t * string option * Status.t =
  match effect with
  | Exit -> editor, clipboard, Exit
  | Set_clipboard text -> editor, Some text, Running
  | Write_file { path; text; revision } ->
    let result = File_io.write path text in
    ( Editor.handle_outcome editor (Write_file_finished { path; text; revision; result })
    , clipboard
    , Running )
  | Read_file { path } ->
    let result =
      match File_io.read path with
      | Ok (File_io.Loaded.Existing text) -> Ok text
      | Ok Missing -> Or_error.error_string "File no longer exists"
      | Error error -> Error error
    in
    Editor.handle_outcome editor (Read_file_finished { path; result }), clipboard, Running
;;

(* Dispatches the editor commands in [actions] and collects the view commands, until
   an [Exit]. Returns the view commands in order, the newest clipboard text, and
   whether any command ran. *)
let rec perform_all editor (actions : Keymap.Action.t list) ~views ~clipboard ~dispatched
  : Editor.t * View_command.t list * string option * bool * Status.t
  =
  match actions with
  | [] -> editor, List.rev views, clipboard, dispatched, Running
  | View view :: rest ->
    perform_all editor rest ~views:(view :: views) ~clipboard ~dispatched
  | Editor command :: rest ->
    let editor, effects = Editor.dispatch editor command in
    let editor, clipboard, status =
      List.fold
        effects
        ~init:(editor, clipboard, Status.Running)
        ~f:(fun (editor, clipboard, status) effect ->
          match perform editor effect ~clipboard with
          | editor, clipboard, Exit -> editor, clipboard, Exit
          | editor, clipboard, Running -> editor, clipboard, status)
    in
    (match status with
     | Exit -> editor, List.rev views, clipboard, true, Exit
     | Running -> perform_all editor rest ~views ~clipboard ~dispatched:true)
;;

let handle_input t input =
  let keymap, actions = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  let editor, views, clipboard, dispatched, status =
    perform_all t.editor actions ~views:[] ~clipboard:t.clipboard ~dispatched:false
  in
  { editor; keymap; dispatched; clipboard }, views, status
;;

let move t motion ~count =
  match Editor.dispatch t.editor (Move { motion; count }) with
  | editor, [] -> { t with editor }
  | _, effects -> raise_s [%message "Controller.move: unexpected effects" (effects : Effect.t list)]
;;
