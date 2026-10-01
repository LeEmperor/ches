(* [open! Core] would shadow our [Command] with Core's command-line [Command]. *)
module Editor_command = Command
open! Core
module Command = Editor_command
module B = Text_buffer

module Message = struct
  type t =
    | Info of string
    | Error of string
  [@@deriving sexp_of, equal]
end

type t =
  { text : B.t
  ; path : string option
  ; mode : Mode.t
  ; revision : int
  ; saved : B.t
  ; saved_revision : int
  ; cursor : int
  ; preferred_column : int
  ; history : History.t
  ; message : Message.t option
  }

let create ?path text =
  { text
  ; path
  ; mode = Normal
  ; revision = 0
  ; saved = text
  ; saved_revision = 0
  ; cursor = 0
  ; preferred_column = 0
  ; history = History.empty
  ; message = None
  }
;;

let text t = t.text
let path t = t.path
let mode t = t.mode
let revision t = t.revision
let is_dirty t = not (B.equal t.text t.saved)
let cursor t = t.cursor
let message t = t.message
let cursor_line t = B.line_of_offset t.text t.cursor
let cursor_column t = B.column_of_offset t.text t.cursor

(* In Normal mode, step back off the end of a nonempty line. *)
let normalize text (mode : Mode.t) offset =
  match mode with
  | Insert -> offset
  | Normal ->
    let line = B.line_of_offset text offset in
    if offset = B.line_end text line && offset > B.line_start text line
    then Option.value_exn (B.prev_boundary text offset)
    else offset
;;

(* Place the cursor for anything but a vertical move. *)
let set_cursor t offset =
  let cursor = normalize t.text t.mode offset in
  { t with cursor; preferred_column = B.column_of_offset t.text cursor }
;;

let snapshot t = { History.text = t.text; cursor = t.cursor }
let commit t = { t with history = History.commit t.history ~after:(snapshot t) }

(* [text] must differ from [t.text]. Joins the active transaction, starting one if
   needed. *)
let edit t ~text ~cursor =
  let history = History.ensure_active t.history ~before:(snapshot t) in
  set_cursor { t with text; revision = t.revision + 1; history } cursor
;;

let move t (direction : Command.Direction.t) =
  let t = commit t in
  let line = cursor_line t in
  match direction with
  | Left ->
    if t.cursor > B.line_start t.text line
    then set_cursor t (Option.value_exn (B.prev_boundary t.text t.cursor))
    else set_cursor t t.cursor
  | Right ->
    let last = normalize t.text t.mode (B.line_end t.text line) in
    if t.cursor < last
    then set_cursor t (Option.value_exn (B.next_boundary t.text t.cursor))
    else set_cursor t t.cursor
  | Up | Down ->
    let target = if Command.Direction.equal direction Up then line - 1 else line + 1 in
    if target < 0 || target >= B.line_count t.text
    then t
    else (
      let offset = B.offset_of_column t.text ~line:target t.preferred_column in
      { t with cursor = normalize t.text t.mode offset })
;;

let exit_insert t =
  let t = commit t in
  let line_start = B.line_start t.text (cursor_line t) in
  let offset =
    if t.cursor > line_start
    then Option.value_exn (B.prev_boundary t.text t.cursor)
    else t.cursor
  in
  set_cursor { t with mode = Normal } offset
;;

let insert_text t s =
  if String.is_empty s
  then t
  else (
    match B.insert t.text ~at:t.cursor s with
    | Ok text -> edit t ~text ~cursor:(t.cursor + String.length s)
    | Error e ->
      let message = "Rejected text: " ^ B.Invalid_text.to_string_hum e in
      { t with message = Some (Error message) })
;;

let delete_backward t =
  match B.prev_boundary t.text t.cursor with
  | None -> t
  | Some pos -> edit t ~text:(B.delete t.text ~pos ~len:(t.cursor - pos)) ~cursor:pos
;;

let check_width width =
  if width < 1 then invalid_argf "soft tab width %d is less than 1" width ()
;;

let insert_soft_tab t width =
  check_width width;
  insert_text t (String.make (width - (cursor_column t % width)) ' ')
;;

let delete_soft_tab_backward t width =
  check_width width;
  let column = cursor_column t in
  let stop = if column = 0 then 0 else (column - 1) / width * width in
  (* Spaces are one byte and one column each. *)
  let rec start pos column =
    if column > stop && String.equal (B.slice t.text ~pos:(pos - 1) ~len:1) " "
    then start (pos - 1) (column - 1)
    else pos
  in
  let pos = start t.cursor column in
  if pos = t.cursor
  then delete_backward t
  else edit t ~text:(B.delete t.text ~pos ~len:(t.cursor - pos)) ~cursor:pos
;;

let delete_forward t =
  match B.next_boundary t.text t.cursor with
  | None -> t
  | Some next ->
    edit t ~text:(B.delete t.text ~pos:t.cursor ~len:(next - t.cursor)) ~cursor:t.cursor
;;

(* Normal mode: the cursor is on a code point other than LF unless its line is
   empty, in which case it sits on the LF (or end of text). *)
let delete_char t =
  if t.cursor = B.line_end t.text (cursor_line t) then t else commit (delete_forward t)
;;

let restore t ~step ~none_message =
  let t = commit t in
  match step t.history with
  | None -> { t with message = Some (Info none_message) }
  | Some (history, (snapshot : History.snapshot)) ->
    set_cursor
      { t with text = snapshot.text; history; revision = t.revision + 1 }
      snapshot.cursor
;;

let save t =
  let t = commit t in
  match t.path with
  | None -> { t with message = Some (Error "No file name") }, []
  | Some path -> t, [ Effect.Write_file { path; text = t.text; revision = t.revision } ]
;;

let quit t =
  if is_dirty t
  then { t with message = Some (Error "Unsaved changes: save them or force quit") }, []
  else t, [ Effect.Exit ]
;;

let dispatch t (command : Command.t) =
  let applies =
    match command, t.mode with
    | Enter_insert, Insert
    | ( ( Exit_insert
        | Insert_text _
        | Delete_backward
        | Delete_forward
        | Insert_soft_tab _
        | Delete_soft_tab_backward _ )
      , Normal )
    | Delete_char, Insert -> false
    | _ -> true
  in
  if not applies
  then t, []
  else (
    let t = { t with message = None } in
    match command with
    | Move direction -> move t direction, []
    | Enter_insert -> set_cursor { t with mode = Insert } t.cursor, []
    | Exit_insert -> exit_insert t, []
    | Insert_text s -> insert_text t s, []
    | Delete_backward -> delete_backward t, []
    | Delete_forward -> delete_forward t, []
    | Insert_soft_tab width -> insert_soft_tab t width, []
    | Delete_soft_tab_backward width -> delete_soft_tab_backward t width, []
    | Delete_char -> delete_char t, []
    | Undo -> restore t ~step:History.undo ~none_message:"Already at oldest change", []
    | Redo -> restore t ~step:History.redo ~none_message:"Already at newest change", []
    | Save -> save t
    | Quit -> quit t
    | Force_quit -> t, [ Effect.Exit ])
;;

let handle_outcome t (outcome : Effect.Outcome.t) =
  match outcome with
  | Write_file_finished { path; text; revision; result } ->
    (match result with
     | Error error ->
       let message = sprintf "Failed to write %s: %s" path (Error.to_string_hum error) in
       { t with message = Some (Error message) }
     | Ok () ->
       let t =
         if [%equal: string option] (Some path) t.path && revision >= t.saved_revision
         then { t with saved = text; saved_revision = revision }
         else t
       in
       let message = sprintf "Wrote %s (%d bytes)" path (B.length text) in
       { t with message = Some (Info message) })
;;
