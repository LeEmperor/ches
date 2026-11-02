open! Core
module Model = Ches_completion.Model
module Text_edit = Ches_core.Text_edit

type encoding = Utf8 | Utf16 | Utf32 [@@deriving sexp_of]

(* Enumerate only exactly addressable boundaries. In particular, neither half of
   a surrogate pair nor the middle of a CRLF is an LSP position. *)
let find_boundary encoding text ~f =
  let length = String.length text in
  let rec walk byte line character =
    if f byte line character then Some (byte, line, character)
    else if byte = length then None
    else if Char.equal text.[byte] '\r' then
      let next = if byte + 1 < length && Char.equal text.[byte + 1] '\n'
        then byte + 2 else byte + 1 in
      walk next (line + 1) 0
    else if Char.equal text.[byte] '\n' then walk (byte + 1) (line + 1) 0
    else
      let d = Stdlib.String.get_utf_8_uchar text byte in
      if not (Stdlib.Uchar.utf_decode_is_valid d) then None
      else
        let bytes = Stdlib.Uchar.utf_decode_length d in
        let units = match encoding with
          | Utf8 -> bytes
          | Utf32 -> 1
          | Utf16 -> if Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d) >= 0x10000 then 2 else 1 in
        walk (byte + bytes) line (character + units)
  in
  if Stdlib.String.is_valid_utf_8 text then walk 0 0 0 else None
;;

let position encoding text offset =
  Option.map (find_boundary encoding text ~f:(fun byte _ _ -> byte = offset))
    ~f:(fun (_, line, character) -> Lsp.Types.Position.create ~line ~character)
;;

let offset encoding text (p : Lsp.Types.Position.t) =
  Option.map (find_boundary encoding text ~f:(fun _ line character ->
    line = p.line && character = p.character)) ~f:(fun (byte, _, _) -> byte)
;;

let field json key = match json with
  | `Assoc fields -> List.Assoc.find fields key ~equal:String.equal
  | _ -> None
;;
let string = function `String s -> Some s | _ -> None
let string_field json key = Option.bind (field json key) ~f:string
let integer = function `Int i -> Some i | _ -> None
let int_field json key = Option.bind (field json key) ~f:integer

let edit encoding text json =
  let open Option.Let_syntax in
  let%bind range = field json "range" in
  let point key =
    let%bind p = field range key in
    let%bind line = int_field p "line" in
    let%bind character = int_field p "character" in
    offset encoding text (Lsp.Types.Position.create ~line ~character)
  in
  let%bind start = point "start" in
  let%bind stop = point "end" in
  let%map text = string_field json "newText" in
  { Text_edit.start; stop; text }
;;

let candidates ~encoding ~text ~(request : Model.Request.t) ~source json =
  let items, incomplete = match json with
    | `List items -> items, false
    | `Assoc _ ->
      (match field json "items" with Some (`List items) -> items | _ -> []),
      (match field json "isIncomplete" with Some (`Bool b) -> b | _ -> false)
    | _ -> [], false
  in
  let base = Ches_core.Text_buffer.of_string text |> Result.ok in
  let candidates = List.take items 512 |> List.filter_mapi ~f:(fun index item ->
    let open Option.Let_syntax in
    let%bind base = base in
    let%bind label = string_field item "label" in
    let%bind () = match int_field item "insertTextFormat", field item "command" with
      | (None | Some 1), (None | Some `Null) -> Some ()
      | _ -> None in
    let%bind primary = match field item "textEdit" with
      | None | Some `Null -> Some { Text_edit.start = request.fallback_start; stop = request.fallback_stop;
          text = Option.value (string_field item "insertText") ~default:label }
      | Some json -> edit encoding text json in
    let%bind additional = match field item "additionalTextEdits" with
      | None | Some `Null -> Some []
      | Some (`List edits) when List.length edits <= 128 ->
        Option.all (List.map edits ~f:(edit encoding text))
      | _ -> None in
    let%bind () = match Text_edit.apply base [primary :: additional] with
      | Ok _ -> Some () | Error _ -> None in
    Some { Model.Candidate.id = sprintf "%s:%d" source index
      ; source = Lsp source; label; detail = string_field item "detail"
      ; filter_text = Option.value (string_field item "filterText") ~default:label
      ; sort_text = Option.value (string_field item "sortText") ~default:label
      ; primary; additional; cursor = String.length primary.text })
  in
  { Model.Reply.token = request.token; source; candidates; incomplete }
;;
