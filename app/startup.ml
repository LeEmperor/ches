open! Core
open Ches_core

type kind = File | Directory
let classify path =
  let path = Resource.normalize ~cwd:(Core_unix.getcwd ()) path in
  if Directory_buffer.is_directory path then Directory else File
let open_path ?keymap_config ~cell_width path =
  match classify path with
  | File -> Controller.open_file ?keymap_config ~cell_width path
  | Directory ->
    let path = Resource.normalize ~cwd:(Core_unix.getcwd ()) path in
    Or_error.map (Or_error.try_with (fun () -> ignore (Stdlib.Sys.readdir path : string array)))
      ~f:(fun () -> Controller.create ?keymap_config ~kind:Directory (Editor.create ~path ~cell_width Text_buffer.empty))
