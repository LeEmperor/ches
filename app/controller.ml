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
  ; highlighting : Highlighting.t
  }

let create ?(keymap_config = Keymap.Config.default) editor =
  { editor
  ; keymap = Keymap.create keymap_config
  ; dispatched = false
  ; clipboard = None
  ; highlighting = Highlighting.create editor
  }
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
let highlights t = Highlighting.snapshot t.highlighting
let highlight_status t = Highlighting.status t.highlighting
let highlight_parse_count t = Highlighting.parse_count t.highlighting
let close t = Highlighting.close t.highlighting
let last_input_dispatched t = t.dispatched
let take_clipboard t = { t with clipboard = None }, t.clipboard

let perform editor (effect : Effect.t) ~clipboard : Editor.t * string option * Status.t * bool =
  match effect with
  | Exit -> editor, clipboard, Exit, false
  | Set_clipboard text -> editor, Some text, Running, false
  | Write_file { path; text; revision } ->
    let result = File_io.write path text in
    ( Editor.handle_outcome editor (Write_file_finished { path; text; revision; result })
    , clipboard
    , Running
    , false )
  | Read_file { path } ->
    let result =
      match File_io.read path with
      | Ok (File_io.Loaded.Existing text) -> Ok text
      | Ok Missing -> Or_error.error_string "File no longer exists"
      | Error error -> Error error
    in
    ( Editor.handle_outcome editor (Read_file_finished { path; result })
    , clipboard
    , Running
    , Result.is_ok result )
;;

(* Dispatches the editor commands in [actions] and collects the view commands, until
   an [Exit]. Returns the view commands in order, the newest clipboard text, and
   whether any command ran or a document reload succeeded. *)
let rec perform_all editor (actions : Keymap.Action.t list) ~views ~clipboard ~dispatched ~reloaded
  : Editor.t * View_command.t list * string option * bool * Status.t * bool
  =
  match actions with
  | [] -> editor, List.rev views, clipboard, dispatched, Running, reloaded
  | View view :: rest ->
    perform_all editor rest ~views:(view :: views) ~clipboard ~dispatched ~reloaded
  | Editor command :: rest ->
    let editor, effects = Editor.dispatch editor command in
    let editor, clipboard, status, reloaded =
      List.fold
        effects
        ~init:(editor, clipboard, Status.Running, reloaded)
        ~f:(fun (editor, clipboard, status, reloaded) effect ->
          match perform editor effect ~clipboard with
          | editor, clipboard, Exit, loaded -> editor, clipboard, Exit, reloaded || loaded
          | editor, clipboard, Running, loaded -> editor, clipboard, status, reloaded || loaded)
    in
    (match status with
     | Exit -> editor, List.rev views, clipboard, true, Exit, reloaded
     | Running -> perform_all editor rest ~views ~clipboard ~dispatched:true ~reloaded)
;;

let handle_input t input =
  let keymap, actions = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  let editor, views, clipboard, dispatched, status, reloaded =
    perform_all t.editor actions ~views:[] ~clipboard:t.clipboard ~dispatched:false ~reloaded:false
  in
  let highlighting = Highlighting.update t.highlighting editor ~reset:reloaded in
  let t = { editor; keymap; dispatched; clipboard; highlighting } in
  (match status with Exit -> close t | Running -> ());
  t, views, status
;;

let move t motion ~count =
  match Editor.dispatch t.editor (Move { motion; count }) with
  | editor, [] ->
    { t with editor; highlighting = Highlighting.update t.highlighting editor ~reset:false }
  | _, effects -> raise_s [%message "Controller.move: unexpected effects" (effects : Effect.t list)]
;;

module For_testing = struct
  let highlight_incremental_count t = Highlighting.For_testing.incremental_count t.highlighting
  let with_highlight_language t language =
    { t with highlighting = Highlighting.For_testing.with_language t.highlighting t.editor language }
  ;;
  let fail_next_highlight t = Highlighting.For_testing.fail_next_parse t.highlighting
end
