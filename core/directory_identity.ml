open! Core

module Kind = struct
  type t =
    | File
    | Directory
    | Symlink
    | Unsupported
  [@@deriving sexp_of, equal]
end

module Entry = struct
  type t =
    { id : int
    ; name : string
    ; kind : Kind.t
    }
  [@@deriving sexp_of, equal]
end

type t =
  { entries : Entry.t list
  ; by_id : Entry.t Int.Map.t
  ; by_token : Entry.t String.Map.t
  }

module Row = struct
  type identity =
    | Existing of int
    | Copy of int
    | Fresh
  [@@deriving sexp_of, equal]

  type t =
    { line : int
    ; identity : identity
    ; name : string
    ; kind : Kind.t
    }
  [@@deriving sexp_of, equal]
end

let valid_name name =
  not (String.is_empty name)
  && not (List.mem [ "."; ".." ] name ~equal:String.equal)
  && not (String.exists name ~f:(fun c -> Char.equal c '/' || Char.equal c '\000'))
;;

let encode_name name =
  let buffer = Buffer.create (String.length name) in
  String.iteri name ~f:(fun i c ->
    let code = Char.to_int c in
    if code < 32 || code >= 127 || Char.equal c '\\' || Char.equal c '@'
       || (Char.equal c ' ' && (i = 0 || i = String.length name - 1))
    then Buffer.add_string buffer (sprintf "\\x%02X" code)
    else Buffer.add_char buffer c);
  Buffer.contents buffer
;;

let decode_name encoded =
  let buffer = Buffer.create (String.length encoded) in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.to_int c - Char.to_int '0')
    | 'A' .. 'F' -> Some (Char.to_int c - Char.to_int 'A' + 10)
    | _ -> None
  in
  let rec loop i =
    if i = String.length encoded
    then (
      let name = Buffer.contents buffer in
      if not (valid_name name)
      then Or_error.error_string "not a legal child name"
      else if not (String.equal (encode_name name) encoded)
      then Or_error.error_string "use canonical byte escapes (uppercase \\xHH)"
      else Ok name)
    else if Char.equal encoded.[i] '\\'
    then (
      if i + 3 >= String.length encoded || not (Char.equal encoded.[i + 1] 'x')
      then Or_error.error_string "invalid byte escape; use \\xHH"
      else (
        match hex encoded.[i + 2], hex encoded.[i + 3] with
        | Some hi, Some lo ->
          Buffer.add_char buffer (Char.of_int_exn ((hi * 16) + lo));
          loop (i + 4)
        | _ -> Or_error.error_string "invalid byte escape; use uppercase \\xHH"))
    else (
      Buffer.add_char buffer encoded.[i];
      loop (i + 1))
  in
  loop 0
;;

let decode_destination encoded =
  String.split encoded ~on:'/'
  |> List.map ~f:(function
    | "" -> Ok "" | "." -> Ok "." | ".." -> Ok ".." | part -> decode_name part)
  |> Or_error.combine_errors
  |> Or_error.bind ~f:(fun parts ->
    if not (Option.value_map (List.last parts) ~default:false ~f:valid_name)
    then Or_error.error_string "Destination requires a legal final name" else Ok (String.concat ~sep:"/" parts))
;;

let create entries =
  if List.exists entries ~f:(fun (entry : Entry.t) -> entry.id <= 0 || not (valid_name entry.name))
  then Or_error.error_string "invalid baseline ID or child name"
  else if List.contains_dup (List.map entries ~f:(fun e -> e.Entry.id)) ~compare:Int.compare
  then Or_error.error_string "duplicate baseline identity"
  else if List.contains_dup (List.map entries ~f:(fun e -> e.Entry.name)) ~compare:String.compare
  then Or_error.error_string "duplicate baseline name"
  else
    let by_id = Int.Map.of_alist_exn (List.map entries ~f:(fun e -> e.Entry.id, e)) in
    let by_token = String.Map.of_alist_exn (List.concat_map entries ~f:(fun e ->
      [ sprintf "@ches[%d]" e.Entry.id, e; sprintf "@copy[%d]" e.id, e ])) in
    Ok { entries; by_id; by_token }
;;

let text ?scope entries =
  List.map entries.entries ~f:(fun (entry : Entry.t) ->
    sprintf "@ches[%d]\t%s%s" entry.id (encode_name entry.name)
      (if Kind.equal entry.kind Directory then "/" else ""))
  |> String.concat ~sep:"\n"
  |> Text_buffer.of_string
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
  |> fun text -> match scope with
    | None -> text
    | Some scope ->
      let names = List.map entries.entries ~f:(fun (entry : Entry.t) ->
        encode_name entry.name ^ (if Kind.equal entry.kind Directory then "/" else "")) in
      let visible = Text_buffer.of_string (String.concat ~sep:"\n" names) |> Result.ok |> Option.value_exn in
      Text_buffer.with_identities visible ~scope
        (List.mapi entries.entries ~f:(fun line entry -> Text_buffer.line_start visible line, sprintf "@ches[%d]" entry.id))
;;

let missing_ids entries rows =
  let present = Int.Set.of_list (List.filter_map rows ~f:(fun (row : Row.t) ->
    match row.identity with Existing id -> Some id | Copy _ | Fresh -> None)) in
  List.filter_map entries.entries ~f:(fun (entry : Entry.t) ->
    if Set.mem present entry.id
    then None else Some entry.id)
;;

let parse entries text =
  let open Or_error.Let_syntax in
  (* Resolve each anchor once, including duplicates and anchors on empty rows. *)
  let tokens_by_line = Array.create ~len:(Text_buffer.line_count text) [] in
  List.iter (Text_buffer.identities text) ~f:(fun (offset, token) ->
    let line = Text_buffer.line_of_offset text offset in
    tokens_by_line.(line) <- token :: tokens_by_line.(line));
  let parse_line line raw =
    let%bind raw = match Text_buffer.identity_scope text with
      | None -> Ok raw
      | Some _ ->
        let tokens = tokens_by_line.(line) in
        (match tokens with
         | [] -> Ok raw
         | [ token ] ->
           if String.is_prefix raw ~prefix:"@copy " && String.is_prefix token ~prefix:"@ches["
           then Ok ("@copy[" ^ String.drop_prefix token 6 ^ "\t" ^ String.drop_prefix raw 6)
           else Ok (token ^ "\t" ^ raw)
         | _ -> Or_error.error_string "joined protected identities; undo the join or delete whole rows") in
    let%bind identity, encoded =
      if (Option.is_none (Text_buffer.identity_scope text)
           || not (List.is_empty tokens_by_line.(line)))
         && (String.is_prefix raw ~prefix:"@ches[" || String.is_prefix raw ~prefix:"@copy[")
      then (
        match String.lsplit2 raw ~on:'\t' with
        | Some (token, name) ->
          (match Map.find entries.by_token token with
            | Some entry -> Ok ((if String.is_prefix token ~prefix:"@copy[" then Row.Copy entry.id else Existing entry.id), name)
           | None -> Or_error.error_string "unknown or malformed identity token")
        | None -> Or_error.error_string "identity token requires a TAB separator")
      else Ok (Row.Fresh, raw)
    in
    let directory = String.is_suffix encoded ~suffix:"/" in
    let%bind name = (match identity with Fresh -> decode_name | Existing _ | Copy _ -> decode_destination)
      (if directory then String.drop_suffix encoded 1 else encoded) in
    let%bind kind =
      match identity with
      | Fresh -> Ok (if directory then Kind.Directory else File)
      | Existing id | Copy id ->
        let entry = Map.find_exn entries.by_id id in
        if not (Bool.equal directory (Kind.equal entry.kind Directory))
        then Or_error.error_string "existing entry kind cannot change"
        else if Kind.equal entry.kind Unsupported && not (String.equal name entry.name)
        then Or_error.error_string "unsupported entry is read-only"
        else Ok entry.kind
    in
    Ok { Row.line; identity; name; kind }
  in
  let%bind rows =
    List.init (Text_buffer.line_count text) ~f:(fun line ->
      let raw = Text_buffer.line_text text line in
      if String.is_empty raw && List.is_empty tokens_by_line.(line) then Ok None
      else (
        parse_line line raw
        |> Or_error.tag ~tag:(sprintf "row %d" (line + 1))
        |> Or_error.map ~f:Option.some))
    |> Or_error.combine_errors
    |> Or_error.map ~f:List.filter_opt
  in
  let ids = List.filter_map rows ~f:(fun row ->
    match row.Row.identity with Existing id -> Some id | Fresh | Copy _ -> None) in
  if List.contains_dup ids ~compare:Int.compare
   then Or_error.error_string "duplicate identity: copying existing rows is unsupported without explicit @copy[ID] token and a unique destination"
  else if
    let present = Int.Set.of_list ids in
    List.exists entries.entries ~f:(fun (entry : Entry.t) ->
      Kind.equal entry.kind Unsupported && not (Set.mem present entry.id))
  then Or_error.error_string "unsupported entry is read-only; restore its row"
  else Ok rows
;;
