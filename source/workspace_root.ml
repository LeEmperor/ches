open! Core

let find path =
  let directory = Filename.dirname path in
  match Filename_unix.realpath directory with
  | exception _ -> directory
  | start ->
    let rec up dir =
      if Sys_unix.file_exists_exn (Filename.concat dir "dune-project")
      then Some dir
      else (
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else up parent)
    in
    Option.value (up start) ~default:start
;;
