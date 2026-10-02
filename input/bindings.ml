module Editor_command = Ches_core.Command
open! Core
module Command = Editor_command

module Target = struct
  type t =
    | Move of Ches_core.Motion.t
    | Editor of Command.t
    | View of View_command.t
    | Scroll of View_command.Scroll.t
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
    ; editor [ 'i' ] (Enter_insert Before_cursor)
    ; editor [ 'a' ] (Enter_insert After_cursor)
    ; editor [ 'A' ] (Enter_insert Line_end)
    ; editor [ 'I' ] (Enter_insert First_nonblank)
    ; editor [ 'o' ] Open_line_below
    ; editor [ 'O' ] Open_line_above
    ; editor [ 'x' ] Delete_char
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
    ; view 'r' Reset
    ]
  |> Or_error.ok_exn
;;

type lookup =
  | Bound of Target.t
  | Prefix
  | Unbound

let find t keys =
  match List.Assoc.find t keys ~equal:[%equal: Key.t list] with
  | Some target -> Bound target
  | None ->
    if List.exists t ~f:(fun (sequence, _) ->
         List.is_prefix sequence ~prefix:keys ~equal:Key.equal)
    then Prefix
    else Unbound
;;
