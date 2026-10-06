open! Core
open Ches_core
open Ches_input
module Feedback = Ches_error.Error

module Status = struct
  type t =
    | Running
    | Exit
  [@@deriving sexp_of, equal]
end

type t =
  { editor : Editor.t
  ; feedback : Feedback.t
  ; keymap : Keymap.t
  ; dispatched : bool
  ; clipboard : string option (** The newest [Set_clipboard] not yet taken. *)
  }

let create ?(keymap_config = Keymap.Config.default) editor =
  { editor
  ; feedback = Feedback.empty
  ; keymap = Keymap.create keymap_config
  ; dispatched = false
  ; clipboard = None
  }
;;

let open_file ?keymap_config ~cell_width path =
  match File_io.read path with
  | Error error ->
    Or_error.error_string (sprintf "Cannot open %s: %s" path (Error.to_string_hum error))
  | Ok (Existing text) ->
    Ok (create ?keymap_config (Editor.create ~path ~cell_width text))
  | Ok Missing ->
    Ok (create ?keymap_config (Editor.create ~path ~cell_width Text_buffer.empty))
;;

let editor t = t.editor
let keymap t = t.keymap
let last_input_dispatched t = t.dispatched
let take_clipboard t = { t with clipboard = None }, t.clipboard

let yank t register =
  { t with
    editor = Editor.set_unnamed_register t.editor register
  ; clipboard = Some (Register.to_string register)
  }
;;

let feedback t = t.feedback
let update_feedback t update = { t with feedback = Feedback.apply t.feedback update }
let cancel_pending t = { t with keymap = Keymap.reset t.keymap; dispatched = false }

let jump t ~line ~column =
  Result.map (Editor.go_to_display_position t.editor ~line ~column) ~f:(fun editor ->
    { (cancel_pending t) with editor })
;;

let notify_editor feedback editor =
  match Editor.message editor with
  | None -> feedback
  | Some message ->
    let severity, text =
      match message with
      | Info text -> Feedback.Severity.Info, text
      | Error text -> Feedback.Severity.Error, text
    in
    Feedback.apply
      feedback
      (Notify
         { source = "editor"; scope = Editor.path editor; severity; text; history = true })
;;

let record_outcome feedback editor identity result =
  match result with
  | Ok _ -> notify_editor (Feedback.apply feedback (Resolve identity)) editor
  | Error error ->
    let operation =
      match identity.Feedback.Identity.kind with
      | Save -> "write"
      | Reload -> "reload"
    in
    Feedback.apply
      feedback
      (Failed
         ( identity
         , Error
         , sprintf
             "Failed to %s %s: %s"
             operation
             identity.resource
             (Error.to_string_hum error) ))
;;

let perform editor feedback (effect : Effect.t) ~clipboard
  : Editor.t * Feedback.t * string option * Status.t
  =
  match effect with
  | Exit -> editor, feedback, clipboard, Exit
  | Set_clipboard text -> editor, feedback, Some text, Running
  | Write_file { path; text; revision } ->
    let result = File_io.write path text in
    let editor =
      Editor.handle_outcome editor (Write_file_finished { path; text; revision; result })
    in
    let feedback =
      record_outcome
        feedback
        editor
        { source = "file"; kind = Save; resource = path }
        result
    in
    editor, feedback, clipboard, Running
  | Read_file { path } ->
    let result =
      match File_io.read path with
      | Ok (File_io.Loaded.Existing text) -> Ok text
      | Ok Missing -> Or_error.error_string "File no longer exists"
      | Error error -> Error error
    in
    let editor = Editor.handle_outcome editor (Read_file_finished { path; result }) in
    let feedback =
      record_outcome
        feedback
        editor
        { source = "file"; kind = Reload; resource = path }
        result
    in
    editor, feedback, clipboard, Running
;;

(* Dispatches the editor commands in [actions] and collects the view commands, until an
   [Exit]. Returns the view commands in order, the newest clipboard text, and whether any
   command ran. *)
let rec perform_all
  editor
  feedback
  (actions : Keymap.Action.t list)
  ~views
  ~clipboard
  ~dispatched
  : Editor.t * Feedback.t * View_command.t list * string option * bool * Status.t
  =
  match actions with
  | [] -> editor, feedback, List.rev views, clipboard, dispatched, Running
  | View view :: rest ->
    perform_all editor feedback rest ~views:(view :: views) ~clipboard ~dispatched
  | Editor command :: rest ->
    let feedback = Feedback.apply feedback Command_completed in
    let editor, effects = Editor.dispatch editor command in
    let feedback = notify_editor feedback editor in
    let editor, feedback, clipboard, status =
      List.fold
        effects
        ~init:(editor, feedback, clipboard, Status.Running)
        ~f:(fun (editor, feedback, clipboard, status) effect ->
          match perform editor feedback effect ~clipboard with
          | editor, feedback, clipboard, Exit -> editor, feedback, clipboard, Exit
          | editor, feedback, clipboard, Running -> editor, feedback, clipboard, status)
    in
    (match status with
     | Exit -> editor, feedback, List.rev views, clipboard, true, Exit
     | Running -> perform_all editor feedback rest ~views ~clipboard ~dispatched:true)
;;

let handle_input t input =
  let keymap, actions = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  (* Only idle Normal Escape dispatches [Clear_search_highlight]. Acknowledge
     before command completion clears the inspected identity. *)
  let acknowledge =
    match input, actions with
    | Key Escape, [ Editor Clear_search_highlight ] -> true
    | _ -> false
  in
  let editor, feedback, views, clipboard, dispatched, status =
    perform_all
      t.editor
      (if acknowledge then Feedback.apply t.feedback Acknowledge else t.feedback)
      actions
      ~views:[]
      ~clipboard:t.clipboard
      ~dispatched:false
  in
  { editor; feedback; keymap; dispatched; clipboard }, views, status
;;

let move t motion ~count =
  match Editor.dispatch t.editor (Move { motion; count }) with
  | editor, [] ->
    { t with
      editor
    ; feedback = notify_editor (Feedback.apply t.feedback Command_completed) editor
    }
  | _, effects ->
    raise_s [%message "Controller.move: unexpected effects" (effects : Effect.t list)]
;;
