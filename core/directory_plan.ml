open! Core
open Directory_identity

type operation =
  | Create_file of string
  | Create_directory of string
  | Rename of { id : int; source : string; destination : string }
  | Delete of { id : int; source : string; kind : Kind.t }
  | Copy of { id : int; source : string; destination : string; kind : Kind.t }
[@@deriving sexp_of, equal]

let plan entries text =
  let open Or_error.Let_syntax in
  let%bind baseline = create entries in
  let%bind rows = parse baseline text in
  let missing = missing_ids baseline rows in
  if List.contains_dup (List.map rows ~f:(fun r -> r.Row.name)) ~compare:String.compare then
    Or_error.error_string "Duplicate destination/collision; give every row a unique child name"
  else
    Ok (List.map missing ~f:(fun id ->
      let e = List.find_exn entries ~f:(fun e -> e.Entry.id = id) in
      Delete { id; source = e.name; kind = e.kind }) @ List.filter_map rows ~f:(fun row ->
      match row.Row.identity with
      | Fresh -> Some (if Kind.equal row.kind Directory then Create_directory row.name else Create_file row.name)
      | Copy id ->
        let entry = List.find_exn entries ~f:(fun e -> e.Entry.id = id) in
        Some (Copy { id; source = entry.name; destination = row.name; kind = entry.kind })
      | Existing id ->
        let entry = List.find_exn entries ~f:(fun e -> e.Entry.id = id) in
        if String.equal entry.name row.name then None
        else Some (Rename { id; source = entry.name; destination = row.name })))
;;

let summary operations =
  if List.is_empty operations then "No filesystem changes proposed"
  else List.map operations ~f:(function
    | Create_file name -> "Create file " ^ encode_name name
    | Create_directory name -> "Create directory " ^ encode_name name ^ "/"
    | Delete { source; kind; _ } -> "Permanently delete " ^ encode_name source ^ (if Kind.equal kind Directory then "/ (empty only)" else "")
    | Copy { source; destination; _ } -> "Copy " ^ encode_name source ^ " -> " ^ encode_name destination
    | Rename { source; destination; _ } -> "Rename " ^ encode_name source ^ " -> " ^ encode_name destination)
    |> String.concat ~sep:"; "
;;
