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

let effective_item defaults item =
  match item with
  | `Assoc fields ->
    let fields = List.fold ["insertTextFormat"; "insertTextMode"; "data"; "commitCharacters"]
      ~init:fields ~f:(fun fields key ->
        if List.Assoc.mem fields key ~equal:String.equal then fields
        else match field defaults key with None -> fields | Some value -> (key, value) :: fields) in
    let item = `Assoc fields in
    if Option.is_some (field item "textEdit") then item
    else (match field defaults "editRange" with
      | None -> item
      | Some range ->
        let new_text = Option.first_some (string_field item "textEditText")
          (Option.first_some (string_field item "insertText") (string_field item "label")) in
        match new_text with
        | None -> item
        | Some text ->
          let ranges = match field range "insert", field range "replace" with
            | Some insert, Some replace -> ["insert", insert; "replace", replace]
            | _ -> ["range", range] in
          `Assoc (("textEdit", `Assoc (("newText", `String text) :: ranges)) :: fields))
  | _ -> item
;;

(* Ches deliberately chooses replace, never insert, for InsertReplaceEdit.
   Validate the protocol's same-start, single-line, insert-prefix constraints. *)
let primary_edit encoding text request json =
  match field json "insert", field json "replace" with
  | None, None -> edit encoding text json
  | Some insert, Some replace ->
    let open Option.Let_syntax in
    let%bind i = edit encoding text (`Assoc ["range", insert; "newText", `String ""]) in
    let%bind r = edit encoding text (`Assoc ["range", replace;
      "newText", Option.value (field json "newText") ~default:`Null]) in
    let%bind start = field replace "start" in
    let%bind stop = field replace "end" in
    let%bind start_line = int_field start "line" in
    let%bind stop_line = int_field stop "line" in
    Option.some_if (i.start = r.start && i.stop <= r.stop && i.start <= request.Model.Request.cursor
      && request.cursor <= i.stop && start_line = stop_line) r
  | _ -> None
;;

let metadata ?revision ?additional ~resolvable candidate_id item =
  let documentation = match field item "documentation" with
    | Some (`String text) -> Some text
    | Some json -> string_field json "value"
    | None -> None in
  { Ches_error.Completion_info.candidate_id; kind = int_field item "kind";
    documentation; detail = string_field item "detail"; resolvable; additional; revision }
;;

let decode ~encoding ~text ~(request : Model.Request.t) ~source json =
  let items, incomplete = match json with
    | `List items -> items, false
    | `Assoc _ ->
      (match field json "items" with Some (`List items) -> items | _ -> []),
      (match field json "isIncomplete" with Some (`Bool b) -> b | _ -> false)
    | _ -> [], false
  in
  let defaults = Option.value (field json "itemDefaults") ~default:`Null in
  let retained = ref [] in
  let base = Ches_core.Text_buffer.of_string text |> Result.ok in
  let candidates = List.take items 512 |> List.filter_mapi ~f:(fun index item ->
    let item = effective_item defaults item in
    let open Option.Let_syntax in
    let%bind base = base in
    let%bind label = string_field item "label" in
    let%bind () = match int_field item "insertTextFormat", int_field item "insertTextMode", field item "command" with
      | (None | Some 1), (None | Some 1), (None | Some `Null) -> Some ()
      | _ -> None in
    let%bind primary = match field item "textEdit" with
      | None | Some `Null -> Some { Text_edit.start = request.fallback_start; stop = request.fallback_stop;
          text = Option.value (string_field item "insertText") ~default:label }
      | Some json -> primary_edit encoding text request json in
    let%bind additional = match field item "additionalTextEdits" with
      | None | Some `Null -> Some []
      | Some (`List edits) when List.length edits <= 128 ->
        Option.all (List.map edits ~f:(edit encoding text))
      | _ -> None in
    let%bind () = match Text_edit.apply base [primary :: additional] with
      | Ok _ -> Some () | Error _ -> None in
    let id = sprintf "%s:%d" source index in
    retained := (id, item) :: !retained;
    Some { Model.Candidate.id = id
      ; source = Lsp source; label; detail = string_field item "detail"
      ; filter_text = Option.value (string_field item "filterText") ~default:label
      ; sort_text = Option.value (string_field item "sortText") ~default:label
      ; primary; additional; cursor = String.length primary.text })
  in
  { Model.Reply.token = request.token; source; candidates; incomplete }, List.rev !retained
;;

let candidates ~encoding ~text ~request ~source json =
  fst (decode ~encoding ~text ~request ~source json)
;;

(* Resolve may enrich docs/detail/additional edits only; never replace the
   already presented primary, ranking, format or command semantics. *)
let resolved ~encoding ~text ~(candidate : Model.Candidate.t) raw json =
  let open Option.Let_syntax in
  let%bind fields = match raw, json with
    | `Assoc old, `Assoc fresh ->
      Some (`Assoc (fresh @ List.filter old ~f:(fun (key, _) ->
        not (List.Assoc.mem fresh key ~equal:String.equal))))
    | _ -> None in
  let%bind () = match int_field fields "insertTextFormat", field fields "command" with
    | (None | Some 1), (None | Some `Null) -> Some () | _ -> None in
  let%bind additional = match field fields "additionalTextEdits" with
    | None | Some `Null -> Some candidate.additional
    | Some (`List edits) when List.length edits <= 128 -> Option.all (List.map edits ~f:(edit encoding text))
    | _ -> None in
  let%bind base = Ches_core.Text_buffer.of_string text |> Result.ok in
  let%map _ = Text_edit.apply base [candidate.primary :: additional] |> Result.ok in
  fields, additional
;;
