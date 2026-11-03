open! Core
open Ches_error.Language_query

let field = Completion_wire.field
let string_field = Completion_wire.string_field
let int_field = Completion_wire.int_field
let bad message = Error message
let point json =
  match int_field json "line", int_field json "character" with
  | Some line, Some character when line >= 0 && character >= 0 -> Ok { line; character }
  | _ -> bad "Invalid navigation position"
let compare_point a b =
  let c = Int.compare a.line b.line in if c = 0 then Int.compare a.character b.character else c
let range json =
  let open Result.Let_syntax in
  let%bind start = point (Option.value (field json "start") ~default:`Null) in
  let%bind stop = point (Option.value (field json "end") ~default:`Null) in
  if compare_point start stop <= 0 then Ok { start; stop } else bad "Reversed navigation range"

(* Do not realpath: aliases of symlinked source trees must remain lexical. *)
let path uri =
  match String.lsplit2 uri ~on:':' with
  | Some (scheme, rest) when String.Caseless.equal scheme "file" ->
    (* RFC 8089 permits both file:/absolute and file:///absolute, and URI
       schemes and host names are case-insensitive. Decode only the path. *)
    let rest = match String.chop_prefix rest ~prefix:"//" with
      | None -> rest
      | Some rest ->
        (match String.lsplit2 rest ~on:'/' with
         | Some (authority, path) when String.is_empty authority
             || String.Caseless.equal authority "localhost" -> "/" ^ path
         | _ -> "") in
    if not (String.is_prefix rest ~prefix:"/") || String.exists rest ~f:(fun c -> Char.equal c '?' || Char.equal c '#')
    then bad "Invalid file URI authority or unescaped delimiter"
    else
      let buffer = Buffer.create (String.length rest) in
      let hex c = match c with
        | '0' .. '9' -> Some (Char.to_int c - Char.to_int '0')
        | 'a' .. 'f' -> Some (10 + Char.to_int c - Char.to_int 'a')
        | 'A' .. 'F' -> Some (10 + Char.to_int c - Char.to_int 'A') | _ -> None in
      let rec decode i =
        if i = String.length rest then
          let path = Buffer.contents buffer in
          if String.mem path '\000' || not (Stdlib.String.is_valid_utf_8 path) then bad "Invalid file URI path"
          else Ok (Ches_core.Resource.normalize ~cwd:"/" path)
        else if Char.equal rest.[i] '%' then
          if i + 2 >= String.length rest then bad "Invalid file URI escape"
          else (match hex rest.[i+1], hex rest.[i+2] with
            | Some a, Some b -> Buffer.add_char buffer (Char.of_int_exn (a * 16 + b)); decode (i+3)
            | _ -> bad "Invalid file URI escape")
        else (Buffer.add_char buffer rest.[i]; decode (i+1)) in
      decode 0
  | _ -> bad "Navigation target is not a file URI"

let locations encoding json =
  let open Result.Let_syntax in
  let target json =
    let link = Option.is_some (field json "targetUri") in
    let%bind uri = match string_field json (if link then "targetUri" else "uri") with
      | Some uri when String.length uri <= 16384 -> Ok uri | _ -> bad "Invalid navigation URI" in
    let%bind path = path uri in
    let%bind full = range (Option.value (field json (if link then "targetRange" else "range")) ~default:`Null) in
    let%bind selection = if link then range (Option.value (field json "targetSelectionRange") ~default:`Null) else Ok full in
    if compare_point full.start selection.start <= 0 && compare_point selection.stop full.stop <= 0
    then Ok { path; range = full; selection; encoding } else bad "Navigation selection is outside target range" in
  match json with
  | `Null -> Ok []
  | `List items when List.length items <= 256 -> Result.all (List.map items ~f:target)
  | `Assoc _ -> Result.map (target json) ~f:List.return
  | _ -> bad "Invalid or oversized navigation locations"

let hover json =
  let open Result.Let_syntax in
  let content = function
    | `String value -> Ok { kind = Markdown; value }
    | json -> (match string_field json "kind", string_field json "language", string_field json "value" with
      | Some "plaintext", _, Some value -> Ok { kind = Plaintext; value }
      | Some "markdown", _, Some value -> Ok { kind = Markdown; value }
      | None, Some language, Some value ->
        let fence = if String.is_substring value ~substring:"```" then "~~~~" else "```" in
        Ok { kind = Markdown; value = fence ^ language ^ "\n" ^ value ^ "\n" ^ fence }
      | _ -> bad "Invalid hover content") in
  match json with
  | `Null -> Ok None
  | _ ->
    let%bind contents = match field json "contents" with
      | Some (`List xs) when List.length xs <= 128 -> Result.all (List.map xs ~f:content)
      | Some x -> Result.map (content x) ~f:List.return
      | None -> bad "Missing hover contents" in
    let%bind () = if List.sum (module Int) contents ~f:(fun c -> String.length c.value) <= 262144
      then Ok () else bad "Hover content is too large" in
    let%map range = match field json "range" with
      | None | Some `Null -> Ok None | Some x -> Result.map (range x) ~f:Option.some in
    let contents = List.filter contents ~f:(fun c -> not (String.is_empty c.value)) in
    if List.is_empty contents then None else Some { contents; range }

let decode encoding kind json = match kind with
  | Hover -> Result.map (hover json) ~f:(fun h -> Hover_result h)
  | References | Declaration | Definition -> Result.map (locations encoding json) ~f:(fun xs -> Locations xs)
  | Instances | Activate_instance _ | Instantiation -> Error "Invalid instance query decoder"
