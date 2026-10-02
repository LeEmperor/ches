open! Core
open Ches_core
open Ches_screen

let ui ?(path = "f.txt") ?prefs s =
  let text =
    Text_buffer.of_string s
    |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith
  in
  Ui_state.create ?prefs (Ches_app.Controller.create (Editor.create ~path text))
;;

(* Keys in [Key_notation]'s notation, as UI inputs. *)
let keys s : Ui_state.Input.t list =
  List.map (Key_notation.keys s) ~f:(function
    | Key key -> Ui_state.Input.Key key
    | Paste _ -> assert false)
;;

(* A bracketed paste of [s], as a terminal reports it: one key per character. *)
let paste s : Ui_state.Input.t list =
  (Ui_state.Input.Paste_start :: keys s) @ [ Paste_end ]
;;

let run ?(width = 40) ?(height = 8) ui inputs =
  match Ui_state.apply_all ui ~width ~height inputs with
  | ui, Running -> ui
  | ui, Exit ->
    print_endline "EXIT";
    ui
;;

let show ?(width = 40) ?(height = 8) ui =
  print_endline (Frame.to_string (Frame.render ui ~width ~height))
;;

(* Just the cursor line of the frame. *)
let show_cursor ?(width = 40) ?(height = 8) ui =
  print_endline
    (List.last_exn
       (String.split_lines (Frame.to_string (Frame.render ui ~width ~height))))
;;

let show_styled ?(width = 40) ?(height = 8) ui =
  print_endline (Frame.to_string_styled (Frame.render ui ~width ~height))
;;
