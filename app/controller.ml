open! Core
open Ches_core
open Ches_input
module Feedback = Ches_error.Error

module Kind = struct
  type t = File | Directory [@@deriving sexp_of, equal]
end

module Status = struct
  type t =
    | Running
    | Exit
  [@@deriving sexp_of, equal]
end

module Saved = struct
  type t =
    { path : string
    ; revision : int
    }
  [@@deriving sexp_of, equal]
end

type t =
  { editor : Editor.t
  ; feedback : Feedback.t
  ; keymap : Keymap.t
  ; dispatched : bool
  ; clipboard : string option (** The newest [Set_clipboard] not yet taken. *)
  ; saved : Saved.t option (** The newest successful write not yet taken. *)
  ; highlighting : Highlighting.t
  ; display_path : string option
  ; kind : Kind.t
  }

let create ?(keymap_config = Keymap.Config.default) ?(kind = Kind.File) editor =
  { editor
  ; feedback = Feedback.empty
  ; keymap = Keymap.create keymap_config
  ; dispatched = false
  ; clipboard = None
  ; saved = None
  ; highlighting = Highlighting.create editor
  ; display_path = Editor.path editor
  ; kind
  }
;;

let open_file ?keymap_config ~cell_width path =
  let display_path = path in
  let path = Resource.normalize ~cwd:(Core_unix.getcwd ()) path in
  let create editor = { (create ?keymap_config editor) with display_path = Some display_path } in
  match File_io.read path with
  | Error error ->
    Or_error.error_string (sprintf "Cannot open %s: %s" path (Error.to_string_hum error))
  | Ok (Existing text) ->
    Ok (create (Editor.create ~path ~cell_width text))
  | Ok Missing ->
    Ok (create (Editor.create ~path ~cell_width Text_buffer.empty))
;;

let editor t = t.editor
let kind t = t.kind
let display_path t = t.display_path
let keymap t = t.keymap
let highlights t = Highlighting.snapshot t.highlighting
let highlight_status t = Highlighting.status t.highlighting
let highlight_parse_count t = Highlighting.parse_count t.highlighting
let close t = Highlighting.close t.highlighting
let last_input_dispatched t = t.dispatched
let take_clipboard t = { t with clipboard = None }, t.clipboard
let take_saved t = { t with saved = None }, t.saved

let yank t register =
  { t with
    editor = Editor.set_unnamed_register t.editor register
  ; clipboard = Some (Register.to_string register)
  }
;;

let feedback t = t.feedback
let update_feedback t update = { t with feedback = Feedback.apply t.feedback update }
let cancel_pending t = { t with keymap = Keymap.reset t.keymap; dispatched = false }
let with_feedback t feedback = { t with feedback }
let with_path t path =
  if Option.equal String.equal (Editor.path t.editor) (Some path) then t
  else let editor = Editor.with_path t.editor path in
    { t with editor; highlighting = Highlighting.update t.highlighting editor ~reset:false }
;;
let with_register t register =
  if Option.equal Register.equal register (Editor.unnamed_register t.editor) then t
  else { t with editor = Option.value_map register ~default:t.editor ~f:(Editor.set_unnamed_register t.editor) }
;;

let reassociate t path = { (with_path t path) with display_path = Some path }
let rebase_text t ~saved ~text =
  let editor = Editor.rebase_text t.editor ~saved ~text in
  { (cancel_pending t) with editor; highlighting = Highlighting.update t.highlighting editor ~reset:true }
;;

let jump t ~line ~column =
  Result.map (Editor.go_to_display_position t.editor ~line ~column) ~f:(fun editor ->
    { (cancel_pending t) with
      editor
    ; highlighting = Highlighting.update t.highlighting editor ~reset:false
    })
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

(* What the frontend takes after {!handle_input}: the newest of each. *)
module Pending = struct
  type t =
    { clipboard : string option
    ; saved : Saved.t option
    }
end

(* The final [bool] is whether the effect reloaded the document from disk, which
   invalidates the highlight cache. *)
let perform editor feedback (effect : Effect.t) ~(pending : Pending.t)
  : Editor.t * Feedback.t * Pending.t * Status.t * bool
  =
  match effect with
  | Exit -> editor, feedback, pending, Exit, false
  | Set_clipboard text -> editor, feedback, { pending with clipboard = Some text }, Running, false
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
    let pending =
      if Result.is_ok result then { pending with saved = Some { path; revision } } else pending
    in
    editor, feedback, pending, Running, false
  | Read_file { path } ->
    let result =
      match File_io.read path with
      | Ok (Existing text) -> Ok text
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
    editor, feedback, pending, Running, Result.is_ok result
;;

(* Dispatches the editor commands in [actions] and collects the view commands, until an
   [Exit]. Returns the view commands in order, the newest clipboard text and save,
   whether any command ran, and whether a document reload succeeded. *)
let rec perform_all
  editor
  feedback
  (actions : Keymap.Action.t list)
  ~views
  ~pending
  ~dispatched
  ~reloaded
  : Editor.t * Feedback.t * View_command.t list * Pending.t * bool * Status.t * bool
  =
  match actions with
  | [] -> editor, feedback, List.rev views, pending, dispatched, Running, reloaded
  | View view :: rest ->
    perform_all editor feedback rest ~views:(view :: views) ~pending ~dispatched ~reloaded
  | Editor command :: rest ->
    let feedback = Feedback.apply feedback Command_completed in
    let editor, effects =
      if Command.equal command Save then Editor.request_save editor
      else Editor.dispatch editor command
    in
    let feedback = notify_editor feedback editor in
    let editor, feedback, pending, status, reloaded =
      List.fold
        effects
        ~init:(editor, feedback, pending, Status.Running, reloaded)
        ~f:(fun (editor, feedback, pending, status, reloaded) effect ->
          match perform editor feedback effect ~pending with
          | editor, feedback, pending, Exit, loaded ->
            editor, feedback, pending, Exit, reloaded || loaded
          | editor, feedback, pending, Running, loaded ->
            editor, feedback, pending, status, reloaded || loaded)
    in
    (match status with
     | Exit -> editor, feedback, List.rev views, pending, true, Exit, reloaded
     | Running ->
       perform_all editor feedback rest ~views ~pending ~dispatched:true ~reloaded)
;;

(* The shared route from typed actions to the editor, effects, highlighting, and the
   [Exit] cutoff, for both {!handle_input} and {!dispatch}. *)
let run t ~keymap ~feedback actions =
  (* Defence in depth: even callers bypassing Session cannot serialize a directory
     listing through file save/reload effects. Session supplies planning feedback. *)
  let actions = if Kind.equal t.kind Directory then List.filter actions ~f:(function
    | Keymap.Action.Editor (Save | Reload) -> false
    | _ -> true) else actions in
  let editor, feedback, views, { Pending.clipboard; saved }, dispatched, status, reloaded =
    perform_all
      t.editor
      feedback
      actions
      ~views:[]
      ~pending:{ clipboard = t.clipboard; saved = t.saved }
      ~dispatched:false
      ~reloaded:false
  in
  let highlighting = Highlighting.update t.highlighting editor ~reset:reloaded in
   let t = { t with editor; feedback; keymap; dispatched; clipboard; saved; highlighting } in
  (match status with
   | Exit -> close t
   | Running -> ());
  t, views, status
;;

let feed_input t input =
  let keymap, actions = Keymap.feed t.keymap ~mode:(Editor.mode t.editor) input in
  (* Only idle Normal Escape dispatches [Clear_search_highlight]. Acknowledge
     before command completion clears the inspected identity. *)
  let acknowledge =
    match input, actions with
    | Key Escape, [ Editor Clear_search_highlight ] -> true
    | _ -> false
  in
  { t with keymap; dispatched = false; feedback = (if acknowledge then Feedback.apply t.feedback Acknowledge else t.feedback) }, actions
;;

let handle_input t input =
  let t, actions = feed_input t input in
  run t ~keymap:t.keymap ~feedback:t.feedback actions
;;

let dispatch t actions = run t ~keymap:t.keymap ~feedback:t.feedback actions

let move t motion ~count =
  match Editor.dispatch t.editor (Move { motion; count }) with
  | editor, [] ->
    { t with
      editor
    ; feedback = notify_editor (Feedback.apply t.feedback Command_completed) editor
    ; highlighting = Highlighting.update t.highlighting editor ~reset:false
    }
  | _, effects ->
    raise_s [%message "Controller.move: unexpected effects" (effects : Effect.t list)]
;;

module For_testing = struct
  let highlight_incremental_count t =
    Highlighting.For_testing.incremental_count t.highlighting
  ;;

  let with_highlight_language t language =
    { t with
      highlighting = Highlighting.For_testing.with_language t.highlighting t.editor language
    }
  ;;

  let fail_next_highlight t = Highlighting.For_testing.fail_next_parse t.highlighting
end
