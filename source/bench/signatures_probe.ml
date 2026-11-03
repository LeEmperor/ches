(* Production transport smoke in disposable source files, gated by capabilities. *)
open! Core
open! Async
module Source = Ches_source.Source
module Client = Ches_source.Lsp_client
module Query = Ches_error.Language_query

let run config name text cursor =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-signatures-probe" "") in
  let resource = Filename.concat root name in
  let source = Client.start ~config ~cell_width:(fun _ -> 1) ~root () in
  let rec receive () =
    let%bind events = Source.next_batch source in
    match List.find_map events ~f:(function
      | Ches_error.Source_event.Query_result reply -> Some reply | _ -> None) with
    | Some reply -> return reply
    | None -> receive () in
  Monitor.protect (fun () ->
    let%bind () = Writer.save resource ~contents:text in
    Source.send source (Document_opened { resource; generation = 1 });
    Source.send source (Document_changed { resource; revision = 0; text });
    let rec started () =
      let%bind events = Source.next_batch source in
      if List.exists events ~f:(function Ches_error.Source_event.Started _ -> true | _ -> false)
      then return ()
      else if List.exists events ~f:(function Unavailable _ | Stopped _ -> true | _ -> false)
      then failwith "server unavailable" else started () in
    let%bind ready = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 15) (started ()) in
    (match ready with `Timeout -> failwith "initialization timeout" | `Result () -> ());
    Deferred.List.iteri
      [ Query.Signature_help { automatic = false; character = None; retrigger = false }; Companion_files ]
      ~how:`Sequential ~f:(fun request kind ->
        Source.send source (Query { token = { resource; generation = 1; revision = 0; request }; cursor; kind });
        match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 12) (receive ()) with
        | `Timeout -> failwith "query timeout"
        | `Result reply -> printf "%s %s\n" config.source
            (Sexp.to_string_hum [%sexp (reply.result : Query.result)])))
    ~finally:(fun () ->
      Source.stop source;
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1100) in
      Process.run ~prog:"/bin/rm" ~args:["-rf"; root] () >>| ignore)

let main () =
  let text = "let f x y = x + y\nlet answer = f 1     " in
  let%bind () = run Client.Config.ocamllsp "a.ml" text (String.length text) in
  let config = Client.Config.for_path "a.sv" |> Option.value_exn in
  let text = "module a; endmodule" in
  run config "a.sv" text (String.length text)

let () = Command.async ~summary:"Probe installed signature help and companion transport"
  (Command.Param.return main) |> Command_unix.run
