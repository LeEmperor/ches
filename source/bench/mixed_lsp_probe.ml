(* Manual integration probe: both real built-in servers through the production pool. *)
open! Core
open! Async
module Source = Ches_source.Source
module Lsp_client = Ches_source.Lsp_client
module Server = Ches_error.Source_event.Server

let main () =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-mixed-lsp" "") in
  let source = Lsp_client.start_workspace ~cell_width:Ches_screen.Cell_map.width () in
  Monitor.protect (fun () ->
    let%bind () = Writer.save (Filename.concat root "dune-project") ~contents:"(lang dune 3.0)\n" in
    let files = [ "a.ml", "let answer = 42\n"; "a.sv", "module example; endmodule\n" ] in
    let%bind () = Deferred.List.iteri files ~how:`Sequential ~f:(fun generation (name, text) ->
      let resource = Filename.concat root name in
      let%map () = Writer.save resource ~contents:text in
      Source.send source (Document_opened { resource; generation });
      Source.send source (Document_changed { resource; revision = 0; text })) in
    let rec await_running () =
      let%bind events = Source.next_batch source in
      let inventories = List.filter_map events ~f:(function
        | Ches_error.Source_event.Servers servers -> Some servers | _ -> None) in
      List.iter inventories ~f:(fun servers -> print_s [%sexp (servers : Server.t list)]);
      if List.exists inventories ~f:(fun servers ->
        List.length servers = 2 && List.for_all servers ~f:(fun s -> Server.equal_status s.status Running))
      then return () else await_running ()
    in
    let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 20) (await_running ()) in
    (match result with `Result () -> () | `Timeout -> failwith "both real servers did not initialize");
    List.iter files ~f:(fun (name, _) ->
      Source.send source (Document_closed { resource = Filename.concat root name }));
    Source.send source Inspect;
    assert (List.exists (Source.poll source) ~f:(function Servers [] -> true | _ -> false));
    print_endline "Both real servers initialized; final managed inventory is empty.";
    return ())
    ~finally:(fun () ->
      Source.stop source;
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1500) in
      Process.run ~prog:"/bin/rm" ~args:[ "-rf"; root ] () >>| ignore)
;;

let () =
  Command.async ~summary:"Smoke-test real OCaml and Slang managed server inventory"
    (Command.Param.return main)
  |> Command_unix.run
