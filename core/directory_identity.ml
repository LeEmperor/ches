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

type t = Entry.t list

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
  else Ok entries
;;

let text entries =
  List.map entries ~f:(fun (entry : Entry.t) ->
    sprintf "@ches[%d]\t%s%s" entry.id (encode_name entry.name)
      (if Kind.equal entry.kind Directory then "/" else ""))
  |> String.concat ~sep:"\n"
  |> Text_buffer.of_string
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

let missing_ids entries rows =
  List.filter_map entries ~f:(fun (entry : Entry.t) ->
    if List.exists rows ~f:(fun (row : Row.t) -> Row.equal_identity row.identity (Existing entry.id))
    then None else Some entry.id)
;;

let parse entries text =
  let open Or_error.Let_syntax in
  let parse_line line raw =
    let%bind identity, encoded =
      if String.is_prefix raw ~prefix:"@ches[" || String.is_prefix raw ~prefix:"@copy["
      then (
        match String.lsplit2 raw ~on:'\t' with
        | Some (token, name) ->
          (match List.find entries ~f:(fun (entry : Entry.t) ->
              String.equal token (sprintf "@ches[%d]" entry.id)
              || String.equal token (sprintf "@copy[%d]" entry.id)) with
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
        let entry = List.find_exn entries ~f:(fun (entry : Entry.t) -> entry.id = id) in
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
      if String.is_empty raw then Ok None
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
  else if List.exists entries ~f:(fun (entry : Entry.t) ->
    Kind.equal entry.kind Unsupported && List.mem (missing_ids entries rows) entry.id ~equal:Int.equal)
  then Or_error.error_string "unsupported entry is read-only; restore its row"
  else Ok rows
;;
