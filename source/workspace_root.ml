open! Core

let find_first ~markers path =
  let directory = Filename.dirname path in
  match Filename_unix.realpath directory with
  | exception _ -> directory
  | start ->
    let rec up marker dir =
      if Sys_unix.file_exists_exn (Filename.concat dir marker)
      then Some dir
      else (
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else up marker parent)
    in
    Option.value (List.find_map markers ~f:(fun marker -> up marker start)) ~default:start
;;

let find = find_first ~markers:[ "dune-project" ]
