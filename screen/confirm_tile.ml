open! Core
open Ches_input

let id = Ches_tile.View_id.of_string "confirm"
let spec = Ches_tile.Spec.read_only id ~title:"Confirm"

type t =
  { origin : Ches_tile.View_id.t
  ; title : string
  ; message : string
  }
[@@deriving sexp_of]

let create ~origin ~title ~message = { origin; title; message }
let origin t = t.origin
let title t = t.title
let message t = t.message
let answer_row = "y yes   n no (default)"
let cells text = Cell_map.total_width (Cell_map.glyphs text)

(* Words of [text] in lines of at most [width] cells; a longer word gets a line of
   its own, cut when drawn. *)
let wrap text ~width =
  String.split_lines text
  |> List.concat_map ~f:(fun line ->
    let words = String.split line ~on:' ' |> List.filter ~f:(Fn.non String.is_empty) in
    let lines, current =
      List.fold words ~init:([], "") ~f:(fun (lines, current) word ->
        if String.is_empty current
        then lines, word
        else if cells current + 1 + cells word <= width
        then lines, current ^ " " ^ word
        else current :: lines, word)
    in
    List.rev (current :: lines))
;;

(* Frame and padding around the content. *)
let chrome = 4

let preferred_size t : Floating.Size.t =
  let width =
    Int.clamp_exn
      (Int.max (cells t.message) (Int.max (cells t.title) (cells answer_row)) + chrome)
      ~min:32
      ~max:64
  in
  { width; height = List.length (wrap t.message ~width:(width - chrome)) + 1 + 2 }
;;

let minimum : Floating.Size.t = { width = 20; height = 4 }

type action =
  | Yes
  | No
[@@deriving sexp_of, equal]

let interpret (keys : Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ key ] when Key.equal key (Key.char 'y') -> Action Yes
  | [ key ] when Key.equal key (Key.char 'n') -> Action No
  | _ -> Unbound
;;

let hint = "y confirms; n or Escape cancels"

let render ?notice t ~width ~rows : Tile_shell.Content.t =
  let rows = Int.max 0 rows in
  let message =
    List.take (wrap t.message ~width) (Int.max 0 (rows - 1))
    |> List.map ~f:(fun line -> Tile_text.row Status line ~width)
  in
  let blank = List.init (Int.max 0 (rows - 1 - List.length message)) ~f:(fun _ ->
    Tile_text.row Status "" ~width)
  in
  { title = t.title
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None ~default:"")
  ; body =
      (if rows = 0 then [] else message @ blank @ [ Tile_text.row Pending answer_row ~width ])
  }
;;
