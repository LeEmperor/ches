open! Core
open Ches_input

let action_of_target : Bindings.Target.t -> Keymap.Action.t option = function
  | Editor command -> Some (Editor command)
  | View command -> Some (View command)
  | Move _
  | Scroll _
  | Delete_operator
  | Yank_operator
  | Delete_chars_forward
  | Delete_chars_backward
  | Delete_to_line_end
  | Paste _
  | Find _
  | Repeat_find _
  | Search_prompt _
  | Repeat_search _
  | Search_word _
  | Visual _ -> None
;;

let sequences bindings action =
  List.filter_map bindings ~f:(fun (keys, target) ->
    match action_of_target target with
    | Some bound when Keymap.Action.equal bound action -> Some keys
    | _ -> None)
;;

let to_string_hum keys = List.map keys ~f:Key.to_string_hum |> String.concat ~sep:" "
