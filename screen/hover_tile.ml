open! Core
module L = Ches_error.Language_query
module Navigation = Ches_tile.Navigation

let id = Ches_tile.View_id.of_string "hover"
let spec = Ches_tile.Spec.read_only id ~title:"Hover"

type t = { lines : string list; top : int } [@@deriving sexp_of]

(* Bound input independently of transport limits, before splitting or mapping.
   Never cut a UTF-8 scalar; also cap zero-cell runs so a narrow row cannot carry
   thousands of combining characters. Truncation is always visibly marked. *)
let bounded text ~bytes =
  let out = Buffer.create (Int.min bytes (String.length text)) in
  let rec loop pos combining =
    if pos >= String.length text then ()
    else if pos >= bytes then Buffer.add_string out " …"
    else
      let decode = Stdlib.String.get_utf_8_uchar text pos in
      let length = Stdlib.Uchar.utf_decode_length decode in
      let uchar = Stdlib.Uchar.utf_decode_uchar decode in
      if pos + length > bytes then Buffer.add_string out " …"
      else
        let zero = Cell_map.width uchar = 0 in
        if zero && combining >= 16 then (
          if combining = 16 then Buffer.add_string out "…";
          loop (pos + length) 17)
        else (
          Buffer.add_string out (String.sub text ~pos ~len:length);
          loop (pos + length) (if zero then combining + 1 else 0))
  in
  loop 0 0;
  Buffer.contents out
;;

let markdown lines =
  let fence = ref None in
  List.map lines ~f:(fun line ->
    let trimmed = String.strip line in
    let marker =
      if String.is_prefix trimmed ~prefix:"```" then Some "```"
      else if String.is_prefix trimmed ~prefix:"~~~" then Some "~~~"
      else None
    in
    match !fence, marker with
    | None, Some marker ->
      fence := Some marker;
      let language = String.drop_prefix trimmed 3 |> String.strip in
      if String.is_empty language then "[code]" else "[code: " ^ language ^ "]"
    | Some opening, Some marker when String.equal opening marker ->
      fence := None; "[/code]"
    | Some _, _ -> line
    | None, _ ->
      (* Keep inline links literally visible (both label and URL). Remove only
         ATX heading markers; lists and inline code are already readable. *)
      let heading = String.lstrip trimmed ~drop:(Char.equal '#') in
      if String.length heading < String.length trimmed
         && (String.is_empty heading || Char.is_whitespace heading.[0])
      then String.strip heading
      else line)
;;

let create (hover : L.hover) =
  let remaining = ref (256 * 1024) in
  let omitted = ref false in
  let lines = List.concat_map hover.contents ~f:(fun (content : L.content) ->
    if !remaining <= 0 then (
      if not (String.is_empty content.value) then omitted := true;
      []) else (
      let budget = Int.min !remaining (String.length content.value) in
      remaining := !remaining - budget;
      let text = bounded content.value ~bytes:budget in
      let lines = String.split_lines text |> List.map ~f:(bounded ~bytes:4096) in
       match content.kind with Plaintext -> lines | Markdown -> markdown lines))
  in
  let lines = if !omitted then lines @ ["…"] else lines in
  { lines; top = 0 }
;;

let top t = t.top
let layout_width width = Int.clamp_exn width ~min:1 ~max:4096

(* A wrapped row is a bounded line plus a cell offset; only visible rows become
   spans. Mapping is independent of viewport height and no unbounded line reaches
   Cell_map or Span. *)
let layout t ~width =
  let width = layout_width width in
  List.concat_map t.lines ~f:(fun line ->
    let glyphs = Cell_map.glyphs line in
    let cells = Cell_map.total_width glyphs in
    List.init (Int.max 1 ((cells + width - 1) / width)) ~f:(fun i -> glyphs, i * width))
;;

let fit t ~width ~rows =
  let total = List.length (layout t ~width) in
  { t with top = Int.clamp_exn t.top ~min:0 ~max:(Int.max 0 (total - Int.max 1 rows)) }
;;

type action = Scroll of Navigation.Motion.t | Close [@@deriving sexp_of]

let interpret (keys : Ches_input.Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [Escape] -> Action Close
  | [key] when Ches_input.Key.equal key (Ches_input.Key.char 'q') -> Action Close
  | [Ctrl 'e'] -> Action (Scroll Down)
  | [Ctrl 'y'] -> Action (Scroll Up)
  | keys -> Ches_tile.Content_key.map (Navigation.interpret keys) ~f:(fun m -> Scroll m)
;;

let scroll t ~width ~rows motion =
  { t with top = Navigation.move_offset t.top ~total:(List.length (layout t ~width))
      ~rows:(Int.max 1 rows) motion }
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let wrapped = layout t ~width in
  let rows = Int.max 0 rows in
  let top = Int.clamp_exn t.top ~min:0 ~max:(Int.max 0 (List.length wrapped - Int.max 1 rows)) in
  let body =
    if width <= 0 then List.init (Int.min rows (List.length wrapped)) ~f:(fun _ -> [])
    else List.drop wrapped top |> Fn.flip List.take rows
      |> List.map ~f:(fun (glyphs, left) ->
        Span.of_glyphs glyphs ~left ~cols:(layout_width width) ~text:Status ~special:Status_special)
  in
  { title = "Hover"
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(sprintf "%d above, %d below%s" top
        (Int.max 0 (List.length wrapped - top - rows))
        (if hotkey_hints then " | j/k Ctrl-d/u gg/G q Esc" else "")))
  ; body
  }
;;
