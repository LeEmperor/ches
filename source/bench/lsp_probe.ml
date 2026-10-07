(* Runs the language-server client against the real ocamllsp on PATH, in a throwaway
   dune project, and prints what it reports: a manual check of phase 10's client that
   the tests (against a scripted server) cannot make. Not a test, since the output
   depends on the installed server. With [-build], runs [dune build] in the project
   first, as a user's watch would have, so merlin has the project's configuration. *)
open! Core
open! Async
module Source = Ches_source.Source
module Lsp_client = Ches_source.Lsp_client
module Source_event = Ches_error.Source_event

let show ~root (event : Source_event.t) =
  let hide = String.substr_replace_all ~pattern:root ~with_:"<root>" in
  match event with
  | Owned _ -> failwith "unexpected owned event from standalone driver"
  | Started { source; _ } -> printf "started %s\n%!" source
  | Stopped { source; reason; _ } -> printf "stopped %s: %s\n%!" source (hide reason)
  | Unavailable { source; reason; _ } -> printf "unavailable %s: %s\n%!" source reason
  | Diagnostics { resource; revision; findings; _ } ->
    printf
      "%s rev %s\n"
      (hide resource)
      (Option.value_map revision ~default:"none" ~f:Int.to_string);
    List.iter findings ~f:(fun f ->
      let line, column =
        Option.value_map f.location ~default:(0, 0) ~f:(fun l -> l.line, l.column)
      in
      printf
        "  %s %d:%d %s\n%!"
        (Sexp.to_string [%sexp (f.severity : Ches_error.Error.Severity.t)])
        line
        column
        f.message)
;;

(* Print events until [f] holds of one, or [seconds] pass. *)
let rec until source ~root ~seconds ~f =
  match%bind
    Clock_ns.with_timeout (Time_ns.Span.of_int_sec seconds) (Source.next_batch source)
  with
  | `Timeout -> return (print_endline "(no more within the wait)")
  | `Result events ->
    List.iter events ~f:(show ~root);
    if List.exists events ~f then return () else until source ~root ~seconds ~f
;;

(* ocamllsp 1.19 leaves the version out, so any list for the file will do. *)
let for_revision revision : Source_event.t -> bool = function
  | Diagnostics { resource; revision = r; _ } ->
    String.is_suffix resource ~suffix:"/a.ml"
    && Option.value_map r ~default:true ~f:(fun r -> r = revision)
  | Stopped _ | Unavailable _ -> true
  | _ -> false
;;

let broken = "let s = \"h\xc3\xa9llo \xf0\x9f\x98\x80\" let x : string = 1\nlet () = print_endline s\n"
let fixed = "let s = \"h\xc3\xa9llo \xf0\x9f\x98\x80\" let x : string = \"1\"\nlet () = print_endline s\n"

let main ~build () =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-lsp-probe" "") in
  let file = Filename.concat root "a.ml" in
  let%bind () = Writer.save (Filename.concat root "dune-project") ~contents:"(lang dune 3.0)\n" in
  let%bind () = Writer.save (Filename.concat root "dune") ~contents:"(executable (name a))\n" in
  let%bind () = Writer.save file ~contents:broken in
  let%bind () =
    if build
    then (
      let%map result = Process.run ~prog:"dune" ~args:[ "build"; "--root"; root ] ~working_dir:root () in
      printf "dune build: %s\n" (match result with Ok _ -> "ok" | Error _ -> "failed (expected: a.ml has a type error)"))
    else return ()
  in
  let%bind version = Process.run ~prog:"ocamllsp" ~args:[ "--version" ] () in
  printf "ocamllsp --version: %s\n" (match version with Ok v -> String.strip v | Error e -> Error.to_string_hum e);
  let source =
    Lsp_client.start ~cell_width:Ches_screen.Cell_map.width ~root ()
  in
  Source.send source (Document_changed { resource = file; text = broken; revision = 1 });
  let%bind () = until source ~root ~seconds:30 ~f:(for_revision 1) in
  print_endline "-- fixing the error (revision 2)";
  Source.send source (Document_changed { resource = file; text = fixed; revision = 2 });
  let%bind () = until source ~root ~seconds:30 ~f:(for_revision 2) in
  print_endline "-- restart";
  Source.send source Restart;
  let%bind () = until source ~root ~seconds:30 ~f:(for_revision 2) in
  Source.stop source;
  (* Give the shutdown its grace, then report any ocamllsp still running in the project. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1500) in
  let%bind left = Process.run ~prog:"pgrep" ~args:[ "-a"; "-x"; "ocamllsp" ] () in
  let left =
    match left with
    | Ok out -> String.split_lines out
    | Error _ -> []
  in
  printf "ocamllsp processes left: %d (any started before the probe count too)\n" (List.length left);
  Process.run ~prog:"rm" ~args:[ "-rf"; root ] () >>| ignore
;;

let () =
  Command.async
    ~summary:"Run the language-server client against the installed ocamllsp"
    (let%map_open.Command build = flag "-build" no_arg ~doc:" run dune build first" in
     fun () -> main ~build ())
  |> Command_unix.run
;;
