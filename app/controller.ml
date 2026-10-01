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
  }

let create ?(keymap_config = Keymap.Config.default) editor =
  { editor; keymap = Keymap.create keymap_config }
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

let perform editor (effect : Effect.t) : Editor.t * Status.t =
  match effect with
  | Exit -> editor, Exit
  | Write_file { path; text; revision } ->
    let result = File_io.write path text in
    Editor.handle_outcome editor (Write_file_finished { path; text; revision; result }), Running
;;

let rec dispatch_all editor (commands : Command.t list) : Editor.t * Status.t =
  match commands with
  | [] -> editor, Running
  | command :: rest ->
    let editor, effects = Editor.dispatch editor command in
    let editor, status =
      List.fold effects ~init:(editor, Status.Running) ~f:(fun (editor, status) effect ->
        match perform editor effect with
        | editor, Exit -> editor, Exit
        | editor, Running -> editor, status)
    in
    (match status with
     | Exit -> editor, Exit
     | Running -> dispatch_all editor rest)
;;

let handle_input t input =
  let keymap, commands = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  let editor, status = dispatch_all t.editor commands in
  { editor; keymap }, status
;;
