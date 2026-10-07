open! Core

let normalize ~cwd path =
  let absolute = if Filename.is_relative path then Filename.concat cwd path else path in
  let parts = String.split absolute ~on:'/' in
  let parts = List.fold parts ~init:[] ~f:(fun acc part ->
    match part, acc with
    | ("" | "."), _ -> acc
    | "..", _ :: tail -> tail
    | "..", [] -> []
    | part, _ -> part :: acc)
  in
  "/" ^ String.concat ~sep:"/" (List.rev parts)
;;
