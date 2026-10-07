open! Core
open Directory_identity

type operation =
  | Create_file of string
  | Create_directory of string
  | Rename of { id : int; source : string; destination : string }
[@@deriving sexp_of, equal]

let plan entries text =
  let open Or_error.Let_syntax in
  let%bind baseline = create entries in
  let%bind rows = parse baseline text in
  let missing = missing_ids baseline rows in
  if not (List.is_empty missing) then
    Or_error.error_string "Deletion is unsupported; restore missing identity rows (or undo)"
  else if List.contains_dup (List.map rows ~f:(fun r -> r.Row.name)) ~compare:String.compare then
    Or_error.error_string "Duplicate destination/collision; give every row a unique child name"
  else
    Ok (List.filter_map rows ~f:(fun row ->
      match row.Row.identity with
      | Fresh -> Some (if Kind.equal row.kind Directory then Create_directory row.name else Create_file row.name)
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
    | Rename { source; destination; _ } -> "Rename " ^ encode_name source ^ " -> " ^ encode_name destination)
    |> String.concat ~sep:"; "
;;
