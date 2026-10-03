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

module Selection = struct
  type t =
    { anchor : int
    ; active : int
    ; kind : [ `Characterwise | `Linewise ]
    }
  [@@deriving sexp_of, equal]
end

module Search_case = struct
  type t =
    | Sensitive
    | Insensitive
    | Smart
  [@@deriving sexp_of, equal]
end

let has_ascii_uppercase s = String.exists s ~f:(fun c -> Char.(c >= 'A' && c <= 'Z'))

let case_sensitive policy query =
  match policy with
  | Search_case.Sensitive -> true
  | Search_case.Insensitive -> false
  | Search_case.Smart -> has_ascii_uppercase query
;;

type t =
  { text : B.t
  ; path : string option
  ; mode : Mode.t
  ; revision : int
  ; saved : B.t
  ; saved_revision : int
  ; cursor : int
  ; preferred_column : int
  ; cell_width : Cell_layout.Width.t
  ; history : History.t
  ; unnamed_register : Register.t option
  ; message : Message.t option
  ; last_find : (Motion.Find.t * int) option
  ; last_search : (string * bool * bool * int option) option
  ; search_case : Search_case.t
  ; search_visible : bool
  ; selection : Selection.t option
  }

let create ?path ?(search_case = Search_case.Smart) ~cell_width text =
  { text
  ; path
  ; mode = Normal
  ; revision = 0
  ; saved = text
  ; saved_revision = 0
  ; cursor = 0
  ; preferred_column =
      Cell_layout.column
        (Cell_layout.glyphs ~width:cell_width (B.line_text text 0))
        ~pos:0
        ~tab_end:true
  ; cell_width
  ; history = History.empty
  ; unnamed_register = None
  ; message = None
  ; last_find = None
  ; last_search = None
  ; search_case
  ; search_visible = false
  ; selection = None
  }
;;

let text t = t.text
let path t = t.path
let mode t = t.mode
let revision t = t.revision
let is_dirty t = not (B.equal t.text t.saved)
let cursor t = t.cursor
let selection t = t.selection
let message t = t.message
let unnamed_register t = t.unnamed_register
let search_case t = t.search_case
let search_state t =
  if t.search_visible
  then Option.map t.last_search ~f:(fun (query, _direction, whole_word, current) -> query, whole_word, case_sensitive t.search_case query, current)
  else None
let cursor_line t = B.line_of_offset t.text t.cursor
let cursor_column t = B.column_of_offset t.text t.cursor

(* The display column of boundary [offset]. *)
let display_column t offset ~tab_end =
  let line = B.line_of_offset t.text offset in
  Cell_layout.column
    (Cell_layout.glyphs ~width:t.cell_width (B.line_text t.text line))
    ~pos:(offset - B.line_start t.text line)
    ~tab_end
;;

(* The preferred column of a cursor at [offset], as Vim's [curswant]. A cursor on a TAB
   aims for the TAB's last cell, where Vim shows it, except in Insert mode and, in
   Visual mode, at or before the anchor. *)
let preferred_column_at t offset =
  display_column
    t
    offset
    ~tab_end:
      (match t.mode, t.selection with
       | Insert, _ -> false
       | Visual _, Some { anchor; _ } -> offset > anchor
       | (Normal | Visual _), _ -> true)
;;

(* The preferred column after [$]: every line's end, however long. *)
let line_end_column = Int.max_value

(* In Normal mode, step back off the end of a nonempty line. *)
let normalize text (mode : Mode.t) offset =
  match mode with
  | Insert -> offset
   | Normal | Visual _ ->
    let line = B.line_of_offset text offset in
    if offset = B.line_end text line && offset > B.line_start text line
    then Option.value_exn (B.prev_boundary text offset)
    else offset
;;

(* Place the cursor for anything but a vertical move. *)
let set_cursor t offset =
  let cursor = normalize t.text t.mode offset in
  { t with cursor; preferred_column = preferred_column_at t cursor }
;;

let snapshot t = { History.text = t.text; cursor = t.cursor }
let commit t = { t with history = History.commit t.history ~after:(snapshot t) }

(* [text] must differ from [t.text]. Joins the active transaction, starting one if
   needed. *)
let edit t ~text ~cursor =
  let history = History.ensure_active t.history ~before:(snapshot t) in
  set_cursor { t with text; revision = t.revision + 1; history } cursor
;;

let check_count count =
  if count < 1 || count > Command.max_count
  then invalid_argf "count %d is not between 1 and %d" count Command.max_count ()
;;

let resolve_motion t motion ~count =
  match motion with
  | Motion.Find find -> Motion.find_destination t.text find ~cursor:t.cursor ~count:(Option.value count ~default:1) ~skip:None
  | _ -> Motion.destination t.text motion ~cell_width:t.cell_width ~cursor:t.cursor ~preferred_column:t.preferred_column ~count |> Result.map ~f:(fun x -> x, -1)
;;

let move t motion ~count =
  Option.iter count ~f:check_count;
  if Option.is_some count && not (Motion.takes_count motion)
  then invalid_argf "%s takes no count" (Sexp.to_string [%sexp (motion : Motion.t)]) ();
  let t = commit t in
  match
    resolve_motion t motion ~count
  with
  | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }
  | Ok (offset, matched) ->
    let t = match motion with Motion.Find find -> { t with last_find = Some (find, matched) } | _ -> t in
    let t =
      match motion with
      | _ when Motion.keeps_preferred_column motion ->
        { t with cursor = normalize t.text t.mode offset }
      | Line_end -> { (set_cursor t offset) with preferred_column = line_end_column }
      | _ -> set_cursor t offset
    in
    match t.selection with
    | None -> t
    | Some selection -> { t with selection = Some { selection with active = t.cursor } }
;;

let selection_range t selection =
  match selection.Selection.kind with
  | `Linewise -> Range.linewise t.text ~cursor:selection.anchor ~destination:selection.active
  | `Characterwise ->
    let start = Int.min selection.anchor selection.active in
    let stop = Int.max selection.anchor selection.active in
    let stop = Option.value (B.next_boundary t.text stop) ~default:stop in
    { Range.start; stop; kind = Characterwise }
;;

let enter_visual t kind =
  match t.mode, t.selection with
  | Visual _, Some selection ->
    { t with mode = Visual kind; selection = Some { selection with kind } }
  | Visual _, None -> { t with mode = Visual kind; selection = Some { anchor = t.cursor; active = t.cursor; kind } }
  | Normal, _ -> { t with mode = Visual kind; selection = Some { anchor = t.cursor; active = t.cursor; kind } }
  | Insert, _ -> t
;;

let leave_visual t ~cursor =
  set_cursor { t with mode = Normal; selection = None } cursor
;;

let visual_yank t =
  match t.selection with
  | None -> t
  | Some selection ->
    let range = selection_range t selection in
    let selected = B.slice t.text ~pos:range.start ~len:(range.stop - range.start) in
    let t =
      if String.is_empty selected && Register.Kind.equal range.kind Characterwise
      then t
      else { t with unnamed_register = Some { Register.text = selected; kind = range.kind } }
    in
    leave_visual t ~cursor:(Int.min selection.anchor selection.active)
;;

let visual_delete t ~change =
  match t.selection with
  | None -> t
  | Some selection ->
    let range = selection_range t selection in
    if range.start = range.stop
    then leave_visual t ~cursor:range.start
    else (
      let deleted = B.slice t.text ~pos:range.start ~len:(range.stop - range.start) in
      let text = B.delete t.text ~pos:range.start ~len:(range.stop - range.start) in
      let mode = if change then Mode.Insert else Mode.Normal in
      let t = edit { t with mode; selection = None; unnamed_register = Some { Register.text = deleted; kind = range.kind } } ~text ~cursor:range.start in
      if change then t else commit t)
;;

(* The leading spaces and TABs of [line]. *)
let indentation t line =
  let text = t.text in
  let start = B.line_start text line in
  let first_nonblank =
    Motion.destination
      text
      First_nonblank
      ~cell_width:t.cell_width
      ~cursor:start
      ~preferred_column:0
      ~count:None
    |> Result.ok
    |> Option.value_exn ~message:"First_nonblank never fails"
  in
  B.slice text ~pos:start ~len:(first_nonblank - start)
;;

let enter_insert t (position : Command.Insert_position.t) =
  let line = cursor_line t in
  let offset =
    match position with
    | Before_cursor -> t.cursor
    | After_cursor ->
      if t.cursor < B.line_end t.text line
      then Option.value_exn (B.next_boundary t.text t.cursor)
      else t.cursor
    | Line_end -> B.line_end t.text line
    | First_nonblank -> B.line_start t.text line + String.length (indentation t line)
  in
  set_cursor { t with mode = Insert } offset
;;

(* The new line's indentation and LF are the first edit of the Insert transaction, so
   that undoing it also removes the typing that follows. *)
let open_line t ~below =
  let line = cursor_line t in
  let indent = indentation t line in
  let at, s, cursor =
    if below
    then (
      let at = B.line_end t.text line in
      at, "\n" ^ indent, at + 1 + String.length indent)
    else (
      let at = B.line_start t.text line in
      at, indent ^ "\n", at + String.length indent)
  in
  match B.insert t.text ~at s with
  | Ok text -> edit { t with mode = Insert } ~text ~cursor
  | Error e -> raise_s [%message "indentation is valid text" (e : B.Invalid_text.t)]
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

let insert_newline t =
  let line = cursor_line t in
  let before_cursor = t.cursor - B.line_start t.text line in
  insert_text t ("\n" ^ String.prefix (indentation t line) before_cursor)
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
  insert_text t (String.make (width - (display_column t t.cursor ~tab_end:false % width)) ' ')
;;

let delete_soft_tab_backward t width =
  check_width width;
  let column = display_column t t.cursor ~tab_end:false in
  let stop = if column = 0 then 0 else (column - 1) / width * width in
  (* Spaces are one byte and one display column each. *)
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
let delete_range t (range : Range.t) =
  if range.start = range.stop
  then t
  else (
    let deleted = B.slice t.text ~pos:range.start ~len:(range.stop - range.start) in
    let text = B.delete t.text ~pos:range.start ~len:(range.stop - range.start) in
    let t = edit t ~text ~cursor:range.start in
    commit
      { t with
        unnamed_register = Some { Register.text = deleted; kind = range.kind }
      })
;;

let delete_chars_forward t count =
  check_count count;
  let line_end = B.line_end t.text (cursor_line t) in
  let rec stop offset remaining =
    if remaining = 0 || offset = line_end
    then offset
    else stop (Option.value_exn (B.next_boundary t.text offset)) (remaining - 1)
  in
  delete_range t { Range.start = t.cursor; stop = stop t.cursor count; kind = Characterwise }
;;

let delete_chars_backward t count =
  check_count count;
  let line_start = B.line_start t.text (cursor_line t) in
  let rec start offset remaining =
    if remaining = 0 || offset = line_start
    then offset
    else start (Option.value_exn (B.prev_boundary t.text offset)) (remaining - 1)
  in
  delete_range t { Range.start = start t.cursor count; stop = t.cursor; kind = Characterwise }
;;

let delete_motion t motion ~count =
  Option.iter count ~f:check_count;
  if Option.is_some count && not (Motion.takes_count motion)
  then invalid_argf "%s takes no count" (Sexp.to_string [%sexp (motion : Motion.t)]) ();
  let t, motion =
    match motion with
    | Motion.Find find ->
      (match Motion.find_destination t.text find ~cursor:t.cursor ~count:(Option.value count ~default:1) ~skip:None with
       | Error failure -> t, Error failure
       | Ok (destination, matched) -> { t with last_find = Some (find, matched) }, Ok (Motion.Find find, destination))
    | _ -> t, Ok (motion, -1)
  in
  match t, motion with
  | t, Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }
  | t, Ok (Motion.Find find, destination) ->
    Range.resolve_destination t.text find ~cursor:t.cursor ~destination |> delete_range t
  | t, Ok (motion, _) ->
    (match Range.resolve t.text motion ~cell_width:t.cell_width ~cursor:t.cursor ~preferred_column:t.preferred_column ~count with
     | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }
     | Ok range -> delete_range t range)
;;

let delete_lines t count =
  check_count count;
  let first = cursor_line t in
  let last = Int.min (B.line_count t.text - 1) (first + count - 1) in
  let start = B.line_start t.text first in
  let stop = if last + 1 < B.line_count t.text then B.line_start t.text (last + 1) else B.length t.text in
  delete_range t { Range.start; stop; kind = Linewise }
;;

let delete_inner_word t =
  match Range.inner_word t.text ~cursor:t.cursor with
  | None -> t
  | Some range -> delete_range t range
;;

let yank_range t (range : Range.t) =
  (* A linewise yank of an empty final line is still useful: its kind lets [p]
     create a blank line. *)
  let text = B.slice t.text ~pos:range.start ~len:(range.stop - range.start) in
  if String.is_empty text && Register.Kind.equal range.kind Characterwise
  then t
  else { t with unnamed_register = Some { Register.text; kind = range.kind } }
;;

let yank_motion t motion ~count =
  Option.iter count ~f:check_count;
  if Option.is_some count && not (Motion.takes_count motion)
  then invalid_argf "%s takes no count" (Sexp.to_string [%sexp (motion : Motion.t)]) ();
  match motion with
  | Motion.Find find ->
    (match Motion.find_destination t.text find ~cursor:t.cursor ~count:(Option.value count ~default:1) ~skip:None with
     | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }
     | Ok (destination, matched) ->
       yank_range { t with last_find = Some (find, matched) }
         (Range.resolve_destination t.text find ~cursor:t.cursor ~destination))
  | _ ->
    (match Range.resolve t.text motion ~cell_width:t.cell_width ~cursor:t.cursor ~preferred_column:t.preferred_column ~count with
     | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }
     | Ok range -> yank_range t range)
;;

let repeat_find t ~opposite ~count =
  check_count count;
  match t.last_find with
  | None -> Error Motion.Failure.No_previous_find
  | Some (original_find, previous_match) ->
    let find =
      if not opposite then original_find
      else { original_find with direction = (match original_find.direction with Motion.Find.Forward -> Motion.Find.Backward | Motion.Find.Backward -> Motion.Find.Forward) }
    in
    let skip = Option.some_if (find.till && not opposite) previous_match in
    Motion.find_destination t.text find ~cursor:t.cursor ~count ~skip
    |> Result.map ~f:(fun (destination, matched) -> original_find, destination, matched)
;;

let small_word_class = Search_match.small_word_class

let search t ~query ~forward ~count ~whole_word =
  check_count count;
  let query, direction, whole_word =
    match query, t.last_search with
    | Some query, _ when not (String.is_empty query) -> query, forward, whole_word
    | Some _, Some (query, previous_direction, whole_word, _) | None, Some (query, previous_direction, whole_word, _) ->
      query, (if forward then previous_direction else not previous_direction), whole_word
    | Some _, None | None, None -> "", forward, whole_word
  in
  if String.is_empty query
  then { t with message = Some (Error "No previous search") }
  else (
    let case_sensitive = case_sensitive t.search_case query in
    let step = if direction then B.next_boundary else B.prev_boundary in
    let edge = if direction then 0 else B.length t.text in
    (* Visit at most one full cycle before reducing large counts modulo the
       number of matches. Ordinary searches stop at the first destination. *)
    let rec scan position ~wrapped ~remaining ~found =
      match position with
      | None when not wrapped -> scan (Some edge) ~wrapped:true ~remaining ~found
      | None -> finish_cycle ~remaining ~found
      | Some at when wrapped && (if direction then at > t.cursor else at < t.cursor) ->
        finish_cycle ~remaining ~found
      | Some at ->
        if Search_match.matches t.text ~query ~whole_word ~case_sensitive ~at
        then if remaining = 1 then Some (at, wrapped)
          else scan (step t.text at) ~wrapped ~remaining:(remaining - 1) ~found:(found + 1)
        else scan (step t.text at) ~wrapped ~remaining ~found
    and finish_cycle ~remaining ~found =
      if found = 0 then None
      else
        scan (step t.text t.cursor) ~wrapped:false
          ~remaining:(((remaining - 1) % found) + 1) ~found:0
        |> Option.map ~f:(fun (at, _) -> at, true)
    in
    match scan (step t.text t.cursor) ~wrapped:false ~remaining:count ~found:0 with
    | None -> { t with last_search = Some (query, direction, whole_word, None); search_visible = true; message = Some (Error ("Pattern not found: " ^ query)) }
    | Some (offset, wrapped) ->
      let t = set_cursor { t with last_search = Some (query, direction, whole_word, Some offset); search_visible = true } offset in
      if wrapped then { t with message = Some (Info "Search wrapped") } else t)
;;

let search_word t ~forward =
  match small_word_class t.text t.cursor with
  | None -> { t with message = Some (Error "No word under cursor") }
  | Some class_ ->
    let rec first p =
      match B.prev_boundary t.text p with
      | Some previous when [%equal: [ `Identifier | `Punctuation ] option] (small_word_class t.text previous) (Some class_) -> first previous
      | None | Some _ -> p
    in
    let rec stop p =
      if [%equal: [ `Identifier | `Punctuation ] option] (small_word_class t.text p) (Some class_)
      then stop (Option.value_exn (B.next_boundary t.text p)) else p
    in
    let start = first t.cursor and stop = stop t.cursor in
    search t ~query:(Some (B.slice t.text ~pos:start ~len:(stop - start))) ~forward ~count:1 ~whole_word:true
;;

let yank_lines t count =
  check_count count;
  let first = cursor_line t in
  let last = Int.min (B.line_count t.text - 1) (first + count - 1) in
  let start = B.line_start t.text first in
  let stop = if last + 1 < B.line_count t.text then B.line_start t.text (last + 1) else B.length t.text in
  yank_range t { Range.start; stop; kind = Linewise }
;;

let repeat_text t text count =
  if String.length text > (Sys.max_string_length - B.length t.text) / count
  then Error "Paste is too large"
  else Ok (String.concat (List.init count ~f:(fun _ -> text)))
;;

let paste t ~before ~count =
  check_count count;
  match t.unnamed_register with
  | None -> { t with message = Some (Error "Nothing in register") }
  | Some { Register.text; kind = Characterwise } ->
    (match repeat_text t text count with
     | Error message -> { t with message = Some (Error message) }
     | Ok inserted when String.is_empty inserted -> t
     | Ok inserted ->
       let line = cursor_line t in
       let at =
         if before || t.cursor = B.line_end t.text line
         then t.cursor
         else Option.value_exn (B.next_boundary t.text t.cursor)
       in
       let text =
         B.insert t.text ~at inserted
         |> Result.map_error ~f:B.Invalid_text.to_string_hum
         |> Result.ok_or_failwith
       in
       let cursor = Option.value_exn (B.prev_boundary text (at + String.length inserted)) in
       commit (edit t ~text ~cursor))
  | Some { Register.text; kind = Linewise } ->
    let one = if String.is_suffix text ~suffix:"\n" then text else text ^ "\n" in
    (match repeat_text t one count with
     | Error message -> { t with message = Some (Error message) }
     | Ok inserted ->
       let line = cursor_line t in
       let at =
         if before
         then B.line_start t.text line
         else if line + 1 < B.line_count t.text
         then B.line_start t.text (line + 1)
         else B.length t.text
       in
       let separator =
         if before || at < B.length t.text || String.is_suffix (B.to_string t.text) ~suffix:"\n"
         then ""
         else "\n"
       in
       let inserted = separator ^ inserted in
       if String.length inserted > Sys.max_string_length - B.length t.text
       then { t with message = Some (Error "Paste is too large") }
       else (
         let text =
           B.insert t.text ~at inserted
           |> Result.map_error ~f:B.Invalid_text.to_string_hum
           |> Result.ok_or_failwith
         in
         let first_line = B.line_of_offset text (at + String.length separator) in
         let cursor =
           Motion.destination
             text
             First_nonblank
             ~cell_width:t.cell_width
             ~cursor:(B.line_start text first_line)
             ~preferred_column:0
             ~count:None
           |> Result.map_error ~f:Motion.Failure.to_string
           |> Result.ok_or_failwith
         in
         commit (edit t ~text ~cursor)))
;;

let delete_char t = delete_chars_forward t 1
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
    | (Enter_insert _ | Open_line_below | Open_line_above | Enter_visual _ | Exit_visual), Insert
    | ( ( Exit_insert
        | Insert_text _
        | Insert_newline
        | Delete_backward
        | Delete_forward
        | Insert_soft_tab _
        | Delete_soft_tab_backward _ )
      , Normal )
    | ( Delete_char
      | Delete_chars_forward _
      | Delete_chars_backward _
       | Delete_motion _
       | Delete_lines _
       | Delete_inner_word
       | Yank_motion _
        | Yank_lines _
        | Paste _
          | Search _ | Search_word _ | Clear_search_highlight
          | Visual_delete | Visual_yank | Visual_change
         | Reload ), Insert -> false
    | (Visual_delete | Visual_yank | Visual_change), Normal -> false
    | (Move _ | Enter_visual _ | Exit_visual | Visual_delete | Visual_yank | Visual_change), Visual _ -> true
    | (Delete_char | Delete_chars_forward _ | Delete_chars_backward _ | Delete_motion _ | Delete_lines _ | Delete_inner_word | Yank_motion _ | Yank_lines _ | Paste _ | Search _ | Search_word _ | Clear_search_highlight | Reload), Visual _ -> false
    | _, Visual _ -> false
    | _ -> true
  in
  if not applies
  then t, []
  else (
    let t = { t with message = None } in
    match command with
    | Move { motion; count } -> move t motion ~count, []
    | Enter_insert position -> enter_insert t position, []
    | Open_line_below -> open_line t ~below:true, []
    | Open_line_above -> open_line t ~below:false, []
    | Exit_insert -> exit_insert t, []
    | Insert_text s -> insert_text t s, []
    | Insert_newline -> insert_newline t, []
    | Delete_backward -> delete_backward t, []
    | Delete_forward -> delete_forward t, []
    | Insert_soft_tab width -> insert_soft_tab t width, []
    | Delete_soft_tab_backward width -> delete_soft_tab_backward t width, []
    | Delete_char -> delete_char t, []
    | Delete_chars_forward count -> delete_chars_forward t count, []
    | Delete_chars_backward count -> delete_chars_backward t count, []
    | Delete_motion { motion; count } -> delete_motion t motion ~count, []
    | Delete_lines count -> delete_lines t count, []
    | Delete_inner_word -> delete_inner_word t, []
    | Yank_motion { motion; count } -> yank_motion t motion ~count, []
    | Yank_lines count -> yank_lines t count, []
    | Paste { before; count } -> paste t ~before ~count, []
    | Repeat_find { opposite; count } ->
      (match repeat_find t ~opposite ~count with
       | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }, []
       | Ok (find, destination, matched) ->
         let t = { t with last_find = Some (find, matched) } in
         set_cursor t destination, [])
    | Delete_repeat_find { opposite; count } ->
      (match repeat_find t ~opposite ~count with
       | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }, []
       | Ok (find, destination, matched) ->
         delete_range { t with last_find = Some (find, matched) }
           (Range.resolve_destination t.text find ~cursor:t.cursor ~destination), [])
    | Yank_repeat_find { opposite; count } ->
      (match repeat_find t ~opposite ~count with
       | Error failure -> { t with message = Some (Error (Motion.Failure.to_string failure)) }, []
       | Ok (find, destination, matched) ->
         yank_range { t with last_find = Some (find, matched) }
           (Range.resolve_destination t.text find ~cursor:t.cursor ~destination), [])
    | Search { query; forward; count; whole_word } -> search t ~query ~forward ~count ~whole_word, []
    | Search_word { forward } -> search_word t ~forward, []
    | Clear_search_highlight -> { t with search_visible = false }, []
    | Enter_visual kind -> enter_visual t kind, []
    | Exit_visual ->
      (match t.selection with
       | None -> t, []
       | Some selection -> leave_visual t ~cursor:selection.active, [])
    | Visual_delete -> visual_delete t ~change:false, []
    | Visual_yank -> visual_yank t, []
    | Visual_change -> visual_delete t ~change:true, []
    | Reload ->
      (match t.path with
       | None -> { t with message = Some (Error "No file name") }, []
       | Some path -> t, [ Effect.Read_file { path } ])
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
  | Read_file_finished { path; result } ->
    (match result with
     | Error error ->
       { t with
         message = Some (Error (sprintf "Failed to reload %s: %s" path (Error.to_string_hum error)))
       }
     | Ok text ->
       set_cursor
         { t with
           text
         ; saved = text
         ; saved_revision = t.revision + 1
         ; revision = t.revision + 1
         ; history = History.empty
         ; message = Some (Info (sprintf "Reloaded %s" path))
         }
         0)
;;
