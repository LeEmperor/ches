open! Core
open! Async
open Bonsai_term
open Bonsai.Let_syntax

let is_char (key : Event.Key.t) c =
  match key with
  | ASCII c' -> Char.equal (Char.lowercase c') c
  | Uchar u -> Uchar.equal u (Uchar.of_char c)
  | _ -> false
;;

let is_exit_key : Event.t -> bool = function
  | Key_press { key; mods = [] } -> is_char key 'q'
  | Key_press { key; mods = [ Ctrl ] } -> is_char key 'c'
  | _ -> false
;;

(* Placeholder text is ASCII, so byte truncation is safe here. Real rendering in
   phase 6 must use display widths. *)
let fit_line s ~width =
  let s = String.prefix s width in
  s ^ String.make (width - String.length s) ' '
;;

let render ~(dimensions : Dimensions.t) ~last_event =
  let { Dimensions.width; height } = dimensions in
  if width <= 0 || height <= 0
  then View.none
  else (
    let body_height = height - 1 in
    let body_lines =
      [ "Ches - Bonsai_term skeleton (MVP0 phase 1)"
      ; ""
      ; "Resize the terminal; the status line follows."
      ; "Press q or Ctrl-C to quit."
      ; ""
      ; (match last_event with
         | None -> "Last event: (none)"
         | Some event -> "Last event: " ^ Sexp.to_string_hum [%sexp (event : Event.t)])
      ]
      |> Fn.flip List.take body_height
      |> List.map ~f:(fun line -> View.text (String.prefix line width))
    in
    let body = View.pad ~b:(body_height - List.length body_lines) (View.vcat body_lines) in
    let status =
      sprintf
        " %s  [no file]  %dx%d "
        (Ches_core.Mode.to_string Normal)
        width
        height
    in
    View.vcat [ body; View.text ~attrs:[ Attr.invert ] (fit_line status ~width) ])
;;

let app ~exit ~dimensions (local_ graph) =
  let last_event, set_last_event = Bonsai.state None graph in
  let view =
    let%arr dimensions and last_event in
    render ~dimensions ~last_event
  in
  let handler =
    let%arr set_last_event in
    fun event -> if is_exit_key event then exit () else set_last_event (Some event)
  in
  ~view, ~handler
;;

let run () = Bonsai_term.start_with_exit ~dispose:true app
