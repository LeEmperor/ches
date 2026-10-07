open! Core

let find path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys_unix.getcwd ()) path else path
  in
  let directory = Filename.dirname path in
  let start =
    match Filename_unix.realpath directory with
    | directory -> directory
    | exception _ -> directory
  in
  let exists path =
    match Sys_unix.file_exists_exn path with
    | exists -> exists
    | exception _ -> false
  in
  let rec up directory =
    if List.exists [ ".git"; "dune-project" ] ~f:(fun marker ->
      exists (Filename.concat directory marker))
    then directory
    else (
      let parent = Filename.dirname directory in
      if String.equal parent directory then start else up parent)
  in
  up start
;;
