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
  }

let create ?(keymap_config = Keymap.Config.default) editor =
  { editor; keymap = Keymap.create keymap_config; dispatched = false }
;;

let open_file ?keymap_config path =
  match File_io.read path with
  | Error error ->
    Or_error.error_string
      (sprintf "Cannot open %s: %s" path (Error.to_string_hum error))
  | Ok (Existing text) -> Ok (create ?keymap_config (Editor.create ~path text))
  | Ok Missing -> Ok (create ?keymap_config (Editor.create ~path Text_buffer.empty))
;;

let editor t = t.editor
let keymap t = t.keymap
let last_input_dispatched t = t.dispatched

let perform editor (effect : Effect.t) : Editor.t * Status.t =
  match effect with
  | Exit -> editor, Exit
  | Write_file { path; text; revision } ->
    let result = File_io.write path text in
    Editor.handle_outcome editor (Write_file_finished { path; text; revision; result }), Running
;;

(* Dispatches the editor commands in [actions] and collects the view commands, until
   an [Exit]. Returns the view commands in order, and whether any command ran. *)
let rec perform_all editor (actions : Keymap.Action.t list) ~views ~dispatched
  : Editor.t * View_command.t list * bool * Status.t
  =
  match actions with
  | [] -> editor, List.rev views, dispatched, Running
  | View view :: rest -> perform_all editor rest ~views:(view :: views) ~dispatched
  | Editor command :: rest ->
    let editor, effects = Editor.dispatch editor command in
    let editor, status =
      List.fold effects ~init:(editor, Status.Running) ~f:(fun (editor, status) effect ->
        match perform editor effect with
        | editor, Exit -> editor, Exit
        | editor, Running -> editor, status)
    in
    (match status with
     | Exit -> editor, List.rev views, true, Exit
     | Running -> perform_all editor rest ~views ~dispatched:true)
;;

let handle_input t input =
  let keymap, actions = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  let editor, views, dispatched, status =
    perform_all t.editor actions ~views:[] ~dispatched:false
  in
  { editor; keymap; dispatched }, views, status
;;

let move t motion ~count =
  match Editor.dispatch t.editor (Move { motion; count }) with
  | editor, [] -> { t with editor }
  | _, effects -> raise_s [%message "Controller.move: unexpected effects" (effects : Effect.t list)]
;;
