open! Core
open Ches_input

(* Keys in a vim-like notation: [<Esc>], [<CR>], [<Tab>], [<BS>], [<Del>], and [<C-x>]
   for Ctrl and a lowercase letter; any other code point, including a literal space,
   is that character. *)
let keys s : Keymap.Input.t list =
  let named =
    [ "<Esc>", Key.Escape
    ; "<CR>", Enter
    ; "<Tab>", Tab
    ; "<BS>", Backspace
    ; "<Del>", Delete
    ]
    @ List.init 26 ~f:(fun i ->
      let c = Char.of_int_exn (Char.to_int 'a' + i) in
      sprintf "<C-%c>" c, Key.Ctrl c)
  in
  let rec loop pos acc =
    if pos >= String.length s
    then List.rev acc
    else (
      match
        List.find named ~f:(fun (name, _) -> String.is_substring_at s ~pos ~substring:name)
      with
      | Some (name, key) -> loop (pos + String.length name) (Keymap.Input.Key key :: acc)
      | None ->
        let decode = Stdlib.String.get_utf_8_uchar s pos in
        let u = Stdlib.Uchar.utf_decode_uchar decode in
        loop (pos + Stdlib.Uchar.utf_decode_length decode) (Key (Char u) :: acc))
  in
  loop 0 []
;;
