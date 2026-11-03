open! Core
open Ches_error.Language_query

let field = Completion_wire.field
let companion_capability caps =
  let enabled json = match field json "handleSwitchImplIntf" with
    | Some (`Bool true) -> true | _ -> false in
  match field caps "experimental" with
  | Some exp -> enabled exp || Option.exists (field exp "ocamllsp") ~f:enabled
  | _ -> false

let strings json key = match field json key with
  | Some (`List xs) when List.length xs <= 256 ->
    List.filter_map xs ~f:(function `String s when String.length s <= 128 -> Some s | _ -> None)
  | _ -> []

let context ~triggers ~retriggers = function
  | Signature_help { automatic; character; retrigger } ->
    let advertised c = List.mem triggers c ~equal:String.equal
      || (retrigger && List.mem retriggers c ~equal:String.equal) in
    if automatic && not retrigger && not (Option.exists character ~f:advertised) then None
    else
      let character = if automatic then Option.filter character ~f:advertised else None in
      Some (`Assoc (["triggerKind", `Int (if Option.is_some character then 2 else if automatic then 3 else 1);
        "isRetrigger", `Bool retrigger]
        @ Option.to_list (Option.map character ~f:(fun c -> "triggerCharacter", `String c))))
  | _ -> None

let index json key length =
  if length = 0 then None else
  match Completion_wire.int_field json key with
  | Some n when n >= 0 && n < length -> Some n
  | _ -> Some 0

let documentation json =
  match field json "documentation" with
  | None | Some `Null -> Ok []
  | Some (`String value) when String.length value <= 65536 ->
    Ok [{ kind = Plaintext; value }]
  | Some json ->
    (match Completion_wire.string_field json "kind", Completion_wire.string_field json "value" with
     | Some kind, Some value when String.length value <= 65536
         && (String.equal kind "markdown" || String.equal kind "plaintext") ->
       Ok [{ kind = (if String.equal kind "markdown" then Markdown else Plaintext); value }]
     | _ -> Error "Invalid signature documentation")

(* Offsets are in a label, not document lines: CR/LF count as ordinary units. *)
let byte label units =
  let rec walk pos count =
    if count = units then Some pos
    else if pos >= String.length label || count > units then None
    else let d = Stdlib.String.get_utf_8_uchar label pos in
      walk (pos + Stdlib.Uchar.utf_decode_length d)
        (count + if Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d) >= 0x10000 then 2 else 1)
  in
  if units < 0 then None else walk 0 0

let parameter label json =
  let open Result.Let_syntax in
  let%map documentation = documentation json in
  let range = match field json "label" with
    | Some (`List [`Int a; `Int b]) when a <= b ->
      Option.both (byte label a) (byte label b)
    | Some (`String s) when not (String.is_empty s) && String.length s <= String.length label
        && Stdlib.String.is_valid_utf_8 s ->
      (match String.substr_index label ~pattern:s with
       | Some start when Option.is_none (String.substr_index label ~pos:(start + 1) ~pattern:s) ->
         Some (start, start + String.length s)
       | _ -> None)
    | _ -> None in
  let label_start, label_stop = Option.value range ~default:(-1, -1) in
  { label_start; label_stop; documentation }

let signature json =
  let open Result.Let_syntax in
  let%bind label = match Completion_wire.string_field json "label" with
    | Some s when String.length s <= 65536 && Stdlib.String.is_valid_utf_8 s -> Ok s
    | _ -> Error "Invalid signature label" in
  let%bind documentation = documentation json in
  let%map parameters = match field json "parameters" with
    | None | Some `Null -> Ok []
    | Some (`List xs) when List.length xs <= 256 -> Result.all (List.map xs ~f:(parameter label))
    | _ -> Error "Invalid signature parameters" in
  let active_parameter = match field json "activeParameter" with
    | None | Some `Null -> None
    | _ -> index json "activeParameter" (List.length parameters) in
  { label; documentation; parameters; active_parameter }

let decode json =
  let open Result.Let_syntax in
  match json with
  | `Null -> Ok (Signature_result None)
  | _ ->
    let%bind signatures = match field json "signatures" with
      | Some (`List xs) when List.length xs <= 64 -> Result.all (List.map xs ~f:signature)
      | _ -> Error "Invalid signature help" in
    let size = List.sum (module Int) signatures ~f:(fun s -> String.length s.label
      + List.sum (module Int) s.documentation ~f:(fun d -> String.length d.value)
      + List.sum (module Int) s.parameters ~f:(fun p ->
        List.sum (module Int) p.documentation ~f:(fun d -> String.length d.value))) in
    if size > 262144 then Error "Signature help is too large"
    else match signatures with
    | [] -> Ok (Signature_result None)
    | _ ->
      let active_signature = Option.value (index json "activeSignature" (List.length signatures)) ~default:0 in
      let selected = List.nth_exn signatures active_signature in
      let active_parameter = index json "activeParameter" (List.length selected.parameters) in
      Ok (Signature_result (Some { signatures; active_signature; active_parameter }))

let companions = function
  | `List xs when List.length xs <= 256 ->
    Result.map (Result.all (List.map xs ~f:(function
      | `String uri when String.length uri <= 16384
          && not (String.exists uri ~f:(fun c -> Char.to_int c <= 32 || Char.to_int c = 127
            || Char.equal c '\\')) -> Navigation_wire.path uri
      | _ -> Error "Invalid companion URI"))) ~f:(fun xs ->
        Companions (List.stable_dedup xs ~compare:String.compare))
  | _ -> Error "Invalid companion files"
