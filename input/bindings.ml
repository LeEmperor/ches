module Editor_command = Ches_core.Command
open! Core
module Command = Editor_command

module Target = struct
  type t =
    | Move of Ches_core.Motion.t
    | Editor of Command.t
    | View of View_command.t
    | Scroll of View_command.Scroll.t
    | Delete_operator
    | Yank_operator
    | Delete_chars_forward
    | Delete_chars_backward
    | Delete_to_line_end
    | Paste of { before : bool }
    | Find of { direction : Ches_core.Motion.Find.direction; till : bool }
    | Repeat_find of { opposite : bool }
    | Search_prompt of { forward : bool }
    | Repeat_search of { opposite : bool }
    | Search_word of { forward : bool }
    | Visual of [ `Characterwise | `Linewise | `Blockwise ]
  [@@deriving sexp_of, equal]
end

type t = (Key.t list * Target.t) list [@@deriving sexp_of]

let keys_to_string keys = List.map keys ~f:Key.to_string_hum |> String.concat ~sep:" "

let is_count_start key =
  match Key.digit key with
  | Some d -> d > 0
  | None -> false
;;

let is_reserved (key : Key.t) =
  match key with
  | Escape | Ctrl 'c' -> true
  | Char _ | Ctrl _ | Enter | Tab | Backspace | Delete -> false
;;

let problems_of_sequence keys =
  match keys with
  | [] -> [ "an empty key sequence is bound" ]
  | first :: _ ->
    List.filter_opt
      [ Option.some_if
          (is_count_start first)
          (sprintf "%s starts with a digit, which starts a count" (keys_to_string keys))
      ; Option.some_if
          (List.exists keys ~f:is_reserved)
          (sprintf "%s uses Escape or Ctrl-c, which always cancel" (keys_to_string keys))
      ]
;;

let create bindings =
  let sequences = List.map bindings ~f:fst in
  let per_sequence = List.concat_map sequences ~f:problems_of_sequence in
  let duplicates =
    let mem = List.mem ~equal:[%equal: Key.t list] in
    List.fold sequences ~init:([], []) ~f:(fun (seen, dups) keys ->
      if not (mem seen keys)
      then keys :: seen, dups
      else if mem dups keys
      then seen, dups
      else seen, keys :: dups)
    |> snd
    |> List.rev_map ~f:(fun keys ->
      sprintf "%s is bound more than once" (keys_to_string keys))
  in
  let prefixes =
    List.concat_map sequences ~f:(fun keys ->
      List.filter_map sequences ~f:(fun longer ->
        Option.some_if
          (List.length keys < List.length longer
           && (not (List.is_empty keys))
           && List.is_prefix longer ~prefix:keys ~equal:Key.equal)
          (sprintf
             "%s is a prefix of %s, so it could never run"
             (keys_to_string keys)
             (keys_to_string longer))))
    |> List.dedup_and_sort ~compare:String.compare
  in
  match per_sequence @ duplicates @ prefixes with
  | [] -> Ok bindings
  | problems ->
    Or_error.error_s [%message "Invalid key bindings" ~_:(problems : string list)]
;;

let default =
  let leader = Key.char ' ' in
  let editor keys (command : Command.t) = List.map keys ~f:Key.char, Target.Editor command in
  let move keys (motion : Ches_core.Motion.t) =
    List.map keys ~f:Key.char, Target.Move motion
  in
  let scroll keys (scroll : View_command.Scroll.t) =
    List.map keys ~f:Key.char, Target.Scroll scroll
  in
  let view c (command : View_command.t) =
    [ leader; Key.char 'v'; Key.char c ], Target.View command
  in
  let status c (command : View_command.t) =
    [ leader; Key.char 'v'; Key.char 'p'; Key.char c ], Target.View command
  in
  create
    [ move [ 'h' ] Left
    ; move [ 'j' ] Down
    ; move [ 'k' ] Up
    ; move [ 'l' ] Right
    ; move [ 'w' ] (Word_forward Small)
    ; move [ 'b' ] (Word_backward Small)
    ; move [ 'e' ] (Word_end Small)
    ; move [ 'W' ] (Word_forward Big)
    ; move [ 'B' ] (Word_backward Big)
    ; move [ 'E' ] (Word_end Big)
    ; move [ '0' ] Line_start
    ; move [ '^' ] First_nonblank
    ; move [ '$' ] Line_end
    ; move [ '_' ] First_nonblank_down
    ; move [ 'g'; '_' ] Last_nonblank
    ; move [ 'g'; 'g' ] First_line
    ; move [ 'G' ] Last_line
     ; move [ '%' ] Matching_delimiter
     ; [ Key.char 'f' ], Find { direction = Ches_core.Motion.Find.Forward; till = false }
     ; [ Key.char 'F' ], Find { direction = Ches_core.Motion.Find.Backward; till = false }
     ; [ Key.char 't' ], Find { direction = Ches_core.Motion.Find.Forward; till = true }
     ; [ Key.char 'T' ], Find { direction = Ches_core.Motion.Find.Backward; till = true }
     ; [ Key.char ';' ], Repeat_find { opposite = false }
     ; [ Key.char ',' ], Repeat_find { opposite = true }
     ; [ Key.char '/' ], Search_prompt { forward = true }
     ; [ Key.char '?' ], Search_prompt { forward = false }
     ; [ Key.char 'n' ], Repeat_search { opposite = false }
     ; [ Key.char 'N' ], Repeat_search { opposite = true }
     ; [ Key.char '*' ], Search_word { forward = true }
     ; [ Key.char '#' ], Search_word { forward = false }
     ; [ Key.char 'v' ], Visual `Characterwise
     ; [ Key.char 'V' ], Visual `Linewise
     ; [ Ctrl 'v' ], Visual `Blockwise
    ; editor [ 'i' ] (Enter_insert Before_cursor)
    ; editor [ 'a' ] (Enter_insert After_cursor)
    ; editor [ 'A' ] (Enter_insert Line_end)
    ; editor [ 'I' ] (Enter_insert First_nonblank)
     ; editor [ 'o' ] Open_line_below
     ; editor [ 'O' ] Open_line_above
    ; [ Key.char 'd' ], Delete_operator
    ; [ Key.char 'y' ], Yank_operator
     ; [ Key.char 'x' ], Delete_chars_forward
     ; [ Key.char 'X' ], Delete_chars_backward
    ; [ Key.char 'D' ], Delete_to_line_end
    ; [ Key.char 'p' ], Paste { before = false }
    ; [ Key.char 'P' ], Paste { before = true }
    ; editor [ 'u' ] Undo
    ; [ Ctrl 'r' ], Editor Redo
    ; [ Ctrl 'e' ], Scroll Line_down
    ; [ Ctrl 'y' ], Scroll Line_up
    ; [ Ctrl 'd' ], Scroll Half_page_down
    ; [ Ctrl 'u' ], Scroll Half_page_up
    ; scroll [ 'z'; 'z' ] Cursor_middle
    ; scroll [ 'z'; 't' ] Cursor_top
    ; scroll [ 'z'; 'b' ] Cursor_bottom
    ; editor [ ' '; 'w' ] Save
    ; editor [ ' '; 'q' ] Quit
    ; editor [ ' '; 'Q' ] Force_quit
    ; [ leader; Key.char 'b'; Key.char 'n' ], View Next_tab
    ; [ leader; Key.char 'o' ], View Toggle_directory
    ; [ leader; Key.char 'd'; Key.char 'm' ], View Directory_major
    ; [ leader; Key.char 'd'; Key.char 's' ], View Directory_side
    ; [ leader; Key.char 'd'; Key.char 'h' ], View Hide_directory
    ; [ leader; Key.char 'd'; Key.char 'f' ], View Focus_directory
    ; [ leader; Key.char 'd'; Key.char '+' ], View (Adjust_directory_size 4)
    ; [ leader; Key.char 'd'; Key.char '-' ], View (Adjust_directory_size (-4))
    ; [ Key.Enter ], View Open_directory_entry
    ; [ Key.char '-' ], View Directory_parent
    ; [ leader; Key.char 'r' ], View Refresh_directory
    ; [ leader; Key.char 'm'; Key.char 'm' ], View Toggle_entry_mark
    ; [ leader; Key.char 'm'; Key.char 's' ], View Mark_selection
    ; [ leader; Key.char 'm'; Key.char 'u' ], View Unmark_selection
    ; [ leader; Key.char 'm'; Key.char 'c' ], View Clear_directory_marks
    ; [ leader; Key.char 'm'; Key.char 'o' ], View Open_marked_files
    ; [ leader; Key.char 'b'; Key.char 'p' ], View Previous_tab
    ; [ leader; Key.char 'b'; Key.char 'c' ], View Close_tab
    ; [ leader; Key.char 'b'; Key.char 'C' ], View Force_close_tab
    ; [ leader; Key.char 'b'; Key.char 'r' ], View Recreate_missing_file
    ; [ leader; Key.char 'b'; Key.char 't' ], View (Present_buffers Top)
    ; [ leader; Key.char 'b'; Key.char 's' ], View (Present_buffers Status_rows)
    ; view 'c' Toggle_centered
    ; view 'h' (Shift (-2))
    ; view 'l' (Shift 2)
    ; view 'H' (Shift (-10))
    ; view 'L' (Shift 10)
    ; view '-' (Adjust_width (-10))
    ; view '+' (Adjust_width 10)
    ; view '=' (Adjust_width 10)
    ; view 'n' Toggle_absolute_numbers
    ; view 'N' Toggle_relative_numbers
    ; view 's' Toggle_smear
    ; view 'e' Inspect_problems
    ; view 'b' Toggle_problems
    ; view 'f' Toggle_problems_filter
    ; view 'o' Focus_problems
    ; view 'd' Toggle_demo_report
    ; view 'D' Focus_demo_report
    ; view 'm' Toggle_history
    ; view 'M' Focus_history
    ; view 'R' Restart_source
    ; view 'K' Kill_source
    ; view 't' Toggle_status
    ; view '?' Toggle_hotkey_hints
    ; view 'z' Toggle_zen
    ; status 'h' (Position_status Left)
    ; status 'l' (Position_status Right)
    ; status 'k' (Position_status Above)
    ; status 'j' (Position_status Below)
    ; status '-' (Adjust_status_size (-2))
    ; status '+' (Adjust_status_size 2)
    ; status '=' (Adjust_status_size 2)
    ; view 'r' Reset
    ; [ leader; Key.char 'c'; Key.char 'c' ], View Open_palette
    ; [ leader; Key.char 'f'; Key.char 'l' ], View Open_line_picker
    ; [ leader; Key.char 'f'; Key.char 'f' ], View Open_file_picker
    ; [ leader; Key.char 'f'; Key.char 'g' ], View Open_content_picker
    ]
  |> Or_error.ok_exn
;;

type lookup =
  | Bound of Target.t
  | Prefix
  | Unbound

let to_list t = t

let find t keys =
  match List.Assoc.find t keys ~equal:[%equal: Key.t list] with
  | Some target -> Bound target
  | None ->
    if List.exists t ~f:(fun (sequence, _) ->
         List.is_prefix sequence ~prefix:keys ~equal:Key.equal)
    then Prefix
    else Unbound
;;
