open! Core
open! Async

let command =
  Command.async
    ~summary:"Edit a UTF-8, LF text file"
    ~readme:(fun () ->
      "Opens PATH, or starts an empty document if nothing exists there; saving \
       creates it.\n\
       Normal mode: h/j/k/l move, i inserts, x deletes, u undoes, Ctrl-r redoes,\n\
       Space w saves, Space q quits, Space Q quits discarding changes.\n\
       Space v c/h/l/H/L/-/+/r: toggle centering, move, resize, reset the layout.")
    (let%map_open.Command path = anon ("PATH" %: Filename_unix.arg_type) in
     fun () ->
       let fail error =
         eprintf "ches: %s\n" (Error.to_string_hum error);
         exit 1
       in
       (* Bonsai_term reads keys from stdin; without a terminal there it fails with a
          long message meant for its developers. *)
       if not (Core_unix.isatty Core_unix.stdin)
       then fail (Error.of_string "standard input is not a terminal")
       else (
         match Ches_app.Controller.open_file path with
         | Error error -> fail error
         | Ok controller ->
           (match%bind Ches_ui.Editor_view.run controller with
            | Ok () -> return ()
            | Error error -> fail error)))
;;

let () = Command_unix.run command
