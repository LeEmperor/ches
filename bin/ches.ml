open! Core
open! Async

let command =
  Command.async
    ~summary:"Edit a UTF-8, LF text file"
    ~readme:(fun () ->
      "Opens PATH, or starts an empty document if nothing exists there; saving creates \
       it.\n\
       MVP0 phase 5: the file is loaded, but the screen is still the phase 1 terminal \
       skeleton.")
    (let%map_open.Command path = anon ("PATH" %: Filename_unix.arg_type) in
     fun () ->
       match Ches_app.Controller.open_file path with
       | Error error ->
         eprintf "ches: %s\n" (Error.to_string_hum error);
         exit 1
       | Ok (_ : Ches_app.Controller.t) ->
         (match%bind Ches_ui.Skeleton.run () with
          | Ok () -> return ()
          | Error error ->
            eprintf "ches: %s\n" (Error.to_string_hum error);
            exit 1))
;;

let () = Command_unix.run command
