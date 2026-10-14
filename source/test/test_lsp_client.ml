(* The language-server client against fake_lsp.exe, a scripted server (see
   fake_lsp/fake_lsp.ml), in a fresh directory per test. These run real processes in
   real time; each wait gives up after 10 s. *)
open! Core
open! Async
open Ches_source
module Source_request = Ches_error.Source_request
module Source_event = Ches_error.Source_event
module Convert = Lsp_client.Convert

let cell_width = Ches_screen.Cell_map.width

let%expect_test "server selection and document language ids" =
  List.iter
    [ "a.ml"; "a.mli"; "a.mll"; "a.mly"; "a.sv"; "a.svh"; "a.v"; "a.vh"
    ; "a.txt"; "a.sv.bak"
    ]
    ~f:(fun path ->
      match Lsp_client.Config.for_path path with
      | None -> printf "%s: none\n" path
      | Some config ->
        printf "%s: %s (%s)\n" path config.prog (config.language_id path));
  [%expect
    {|
    a.ml: ocamllsp (ocaml)
    a.mli: ocamllsp (ocaml.interface)
    a.mll: ocamllsp (ocaml.ocamllex)
    a.mly: ocamllsp (ocaml.menhir)
    a.sv: slang-server (systemverilog)
    a.svh: slang-server (systemverilog)
    a.v: slang-server (verilog)
    a.vh: slang-server (verilog)
    a.txt: none
    a.sv.bak: none
    |}];
  return ()
;;

let%expect_test "conversions: severities, one-line messages, columns per encoding" =
  List.iter
    [ None; Some Lsp.Types.DiagnosticSeverity.Error; Some Warning; Some Information; Some Hint ]
    ~f:(fun s -> print_s [%sexp (Convert.severity s : Ches_error.Error.Severity.t)]);
  print_endline (Convert.message "This expression has type int\n  but\tone of\r\n  string ");
  let column encoding line character =
    printf
      "%s %S %d -> %d\n"
      (Sexp.to_string [%sexp (encoding : Convert.encoding)])
      line
      character
      (Convert.column ~cell_width encoding ~line ~character)
  in
  (* U+1F600 is two UTF-16 units, four UTF-8 bytes, and two cells wide. *)
  column Utf16 "\xf0\x9f\x98\x80x" 2;
  column Utf16 "\xf0\x9f\x98\x80x" 1;
  column Utf8 "\xf0\x9f\x98\x80x" 4;
  column Utf32 "\xf0\x9f\x98\x80x" 1;
  column Utf8 "\xc3\xa9x" 1;
  column Utf16 "\tx" 1;
  column Utf16 "ab" 9;
  column Utf16 "" 0;
  [%expect
    {|
    Error
    Error
    Warning
    Info
    Hint
    This expression has type int but one of string
    Utf16 "\240\159\152\128x" 2 -> 3
    Utf16 "\240\159\152\128x" 1 -> 1
    Utf8 "\240\159\152\128x" 4 -> 3
    Utf32 "\240\159\152\128x" 1 -> 3
    Utf8 "\195\169x" 1 -> 1
    Utf16 "\tx" 1 -> 9
    Utf16 "ab" 9 -> 3
    Utf16 "" 0 -> 1
    |}];
  return ()
;;

let fake = lazy (Filename.concat (Core_unix.getcwd ()) "fake_lsp/fake_lsp.exe")

let config ?(args = []) ?prog () =
  { Lsp_client.Config.ocamllsp with
    source = "fake"
  ; prog = Option.value prog ~default:(force fake)
  ; args
  }
;;

let with_root f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-lsp" "") in
  Monitor.protect
    (fun () -> f root)
    ~finally:(fun () -> Process.run ~prog:"rm" ~args:[ "-rf"; root ] () >>| ignore)
;;

let changed root revision text : Source_request.t =
  Document_changed { resource = Filename.concat root "a.ml"; text; revision }
;;

let show ~root (event : Source_event.t) =
  let hide = String.substr_replace_all ~pattern:root ~with_:"<root>" in
  match event with
  | Owned _ -> failwith "unexpected owned event from standalone driver"
  | Started { source; _ } -> printf "started %s\n" source
  | Stopped { source; reason; _ } -> printf "stopped %s: %s\n" source (hide reason)
  | Unavailable { source; reason; _ } -> printf "unavailable %s: %s\n" source reason
  | Diagnostics { source = _; resource; revision; findings } ->
    printf
      "%s rev %s\n"
      (hide resource)
      (Option.value_map revision ~default:"none" ~f:Int.to_string);
    List.iter findings ~f:(fun f ->
      let line, column =
        Option.value_map f.location ~default:(0, 0) ~f:(fun l -> l.line, l.column)
      in
      printf
        "  %s %d:%d %s\n"
        (String.lowercase (Sexp.to_string [%sexp (f.severity : Ches_error.Error.Severity.t)]))
        line
        column
        f.message)
;;

(* Print events until one satisfies [f]. *)
let rec until ?(quiet = false) source ~root ~f =
  match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (Source.next_batch source) with
  | `Timeout ->
    print_endline "timeout";
    return ()
  | `Result events ->
    if not quiet then List.iter events ~f:(show ~root);
    if List.exists events ~f then return () else until ~quiet source ~root ~f
;;

let is_diagnostics ?(resource = "a.ml") ?revision (event : Source_event.t) =
  match event with
  | Diagnostics d ->
    String.is_suffix d.resource ~suffix:("/" ^ resource)
    && Option.for_all revision ~f:(fun r -> [%equal: int option] d.revision (Some r))
  | _ -> false
;;

let is_stop : Source_event.t -> bool = function
  | Stopped _ | Unavailable _ -> true
  | _ -> false
;;

let%expect_test "initial diagnostics, then an edit that fixes them" =
  with_root (fun root ->
    let source = Lsp_client.start ~config:(config ()) ~cell_width ~root () in
    (* Sent before the session is initialized: opened once it is. *)
    Source.send source (changed root 1 "let a = 1\nlet \xc3\xa9\xf0\x9f\x98\x80 = ERROR\n\tWARN\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:1) in
    [%expect
      {|
      started fake
      <root>/a.ml rev 1
        error 2:11 fake error
        warning 3:9 fake warning
      |}];
    Source.send source (changed root 2 "let a = 1\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:2) in
    [%expect {| <root>/a.ml rev 2 |}];
    Source.stop source;
    return ())
;;

let%expect_test "columns agree whichever position encoding the server picks" =
  Deferred.List.iter ~how:`Sequential [ "utf-8"; "utf-16"; "none" ] ~f:(fun encoding ->
    with_root (fun root ->
      let source =
        Lsp_client.start ~config:(config ~args:[ "-encoding"; encoding ] ()) ~cell_width ~root ()
      in
      Source.send source (changed root 1 "\t\xc3\xa9\xf0\x9f\x98\x80 ERROR\n");
      let%bind () = until source ~root ~f:(is_diagnostics ~revision:1) in
      Source.stop source;
      return ()))
  >>| fun () ->
  [%expect
    {|
    started fake
    <root>/a.ml rev 1
      error 1:13 fake error
    started fake
    <root>/a.ml rev 1
      error 1:13 fake error
    started fake
    <root>/a.ml rev 1
      error 1:13 fake error
    |}]
;;

let%expect_test "severities, a missing one, and a multi-line message" =
  with_root (fun root ->
    let source = Lsp_client.start ~config:(config ()) ~cell_width ~root () in
    Source.send source (changed root 1 "HINT\nINFO\nNOSEV\nMULTI\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:1) in
    [%expect
      {|
      started fake
      <root>/a.ml rev 1
        hint 1:1 fake hint
        info 2:1 fake info
        error 3:1 fake finding without severity
        error 4:1 This expression has type int but an expression was expected of type string
      |}];
    Source.stop source;
    return ())
;;

let%expect_test "another file: unversioned, columns from the file on disk" =
  with_root (fun root ->
    let%bind () = Writer.save (Filename.concat root "other.ml") ~contents:"let x = 1\n\tlet OTHER\n" in
    let source = Lsp_client.start ~config:(config ()) ~cell_width ~root () in
    Source.send source (changed root 1 "let a = 1\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~resource:"other.ml") in
    [%expect
      {|
      started fake
      <root>/a.ml rev 1
      <root>/other.ml rev none
        warning 2:13 fake other
      |}];
    Source.stop source;
    return ())
;;

let%expect_test "the server's own requests are answered" =
  with_root (fun root ->
    let source =
      Lsp_client.start ~config:(config ~args:[ "-request-first" ] ()) ~cell_width ~root ()
    in
    Source.send source (changed root 1 "ERROR\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:1) in
    [%expect
      {|
      started fake
      <root>/a.ml rev 1
        error 1:1 fake error
      |}];
    Source.stop source;
    return ())
;;

let%expect_test "a crash stops the source; a restart reopens the newest text; Kill is \
                 ignored"
  =
  with_root (fun root ->
    let source = Lsp_client.start ~config:(config ()) ~cell_width ~root () in
    Source.send source Kill;
    Source.send source (changed root 1 "ERROR\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:1) in
    Source.send source (changed root 2 "CRASH\n");
    let%bind () = until source ~root ~f:is_stop in
    [%expect
      {|
      started fake
      <root>/a.ml rev 1
        error 1:1 fake error
      stopped fake: exited with code 3: fake: crashed on CRASH
      |}];
    (* Edits while stopped are kept for the next session. *)
    Source.send source (changed root 3 "let a = 1\nWARN\n");
    Source.send source Restart;
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:3) in
    [%expect
      {|
      started fake
      <root>/a.ml rev 3
        warning 2:1 fake warning
      |}];
    (* A restart of a running session reports no stop for the old one. *)
    Source.send source Restart;
    Source.send source (changed root 4 "INFO\n");
    let%bind () = until source ~root ~f:(is_diagnostics ~revision:4) in
    [%expect
      {|
      started fake
      <root>/a.ml rev 4
        info 1:1 fake info
      |}];
    Source.stop source;
    return ())
;;

let%expect_test "a server that cannot run: missing, exits at once, or refuses to \
                 initialize"
  =
  with_root (fun root ->
    let attempt config =
      let source = Lsp_client.start ~config ~cell_width ~root () in
      Source.send source (changed root 1 "ERROR\n");
      let%map () = until source ~root ~f:is_stop in
      Source.stop source
    in
    let%bind () = attempt (config ~prog:"ches-no-such-server" ()) in
    let%bind () = attempt (config ~prog:"/nonexistent/ches-server" ()) in
    let%bind () = attempt (config ~args:[ "-exit-at-start" ] ()) in
    let%bind () = attempt (config ~args:[ "-fail-init" ] ()) in
    [%expect
      {|
      unavailable fake: ches-no-such-server not found on PATH
      unavailable fake: /nonexistent/ches-server not found on PATH
      stopped fake: exited with code 2: fake: cannot start
      stopped fake: initialize failed: fake: refuses to initialize
      |}];
    return ())
;;

let%expect_test "the root: nearest directory with any marker" =
  with_root (fun root ->
    let mkdir path = Core_unix.mkdir_p (Filename.concat root path) in
    let touch path = Out_channel.write_all (Filename.concat root path) ~data:"" in
    mkdir "repo/.git";
    mkdir "repo/proj/lib/deep";
    touch "repo/proj/dune-project";
    touch "repo/proj/lib/x.opam";
    touch "repo/proj/lib/package.json";
    mkdir "loose";
    let show path =
      let found = Lsp_client.Config.(root ocamllsp) (Filename.concat root path) in
      print_endline (String.substr_replace_all found ~pattern:root ~with_:"<root>")
    in
    (* The nearer package.json wins; *.opam is still a literal name. *)
    show "repo/proj/lib/deep/a.ml";
    show "repo/b.ml";
    show "loose/c.ml";
    [%expect
      {|
      <root>/repo/proj/lib
      <root>/repo
      <root>/loose
      |}];
    return ())
;;

let%expect_test "slang root: nearest project config or git, then the file's directory" =
  with_root (fun root ->
    List.iter [ "repo/.git"; "repo/rtl/.slang"; "repo/rtl/sub/.git"; "loose" ]
      ~f:(fun path -> Core_unix.mkdir_p (Filename.concat root path));
    List.iter [ "repo/rtl/sub/a.sv"; "repo/b.v"; "loose/c.svh" ] ~f:(fun path ->
      let found = Lsp_client.Config.(root slang_server) (Filename.concat root path) in
      print_endline (String.substr_replace_all found ~pattern:root ~with_:"<root>"));
    [%expect
      {|
      <root>/repo/rtl/sub
      <root>/repo
      <root>/loose
      |}];
    return ())
;;

(* The log is written by the actual child, so these assertions count processes and
   wire notifications rather than factory calls. Waits fail rather than skip. *)
let log_lines path = if Sys_unix.file_exists_exn path then In_channel.read_lines path else []
let count_method path method_ =
  List.count (log_lines path) ~f:(fun line -> String.is_suffix line ~suffix:(" " ^ method_))
;;

let wait_for f =
  let rec loop () = if f () then return () else Clock_ns.after (Time_ns.Span.of_int_ms 10) >>= loop in
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (loop ()) with
  | `Result () -> ()
  | `Timeout -> failwith "fake LSP integration condition timed out"
;;

let collect source predicate =
  let rec loop acc =
    let%bind batch = Source.next_batch source in
    let acc = acc @ batch in
    if predicate acc then return acc else loop acc
  in
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (loop []) with
  | `Result events -> events
  | `Timeout -> failwith "fake LSP diagnostics timed out"
;;

let owned_diagnostic resource generation revision = function
  | Source_event.Owned { resource = r; generation = g; event = Diagnostics d } ->
    String.equal resource r && g = generation && String.equal d.resource resource
    && [%equal: int option] d.revision (Some revision)
  | _ -> false
;;

let wait_dead log =
  let pids = log_lines log |> List.map ~f:(fun line -> List.hd_exn (String.split line ~on:' '))
    |> String.Set.of_list |> Set.to_list in
  let rec loop pid =
    match%bind Process.run ~prog:"kill" ~args:[ "-0"; pid ] () with
    | Error _ -> return ()
    | Ok _ -> Clock_ns.after (Time_ns.Span.of_int_ms 10) >>= fun () -> loop pid
  in
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10)
    (Deferred.List.iter pids ~how:`Sequential ~f:loop) with
  | `Result () -> ()
  | `Timeout -> failwith "fake server survived cleanup"
;;

let%expect_test "stdout EOF from a live server is bounded and the child is reaped" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let config = { (config ~args:[ "-log"; log; "-close-stdout" ] ()) with
      shutdown_grace = Time_ns.Span.of_int_ms 50 } in
    let source = Lsp_client.start ~config ~cell_width ~root () in
    Monitor.protect (fun () ->
      Source.send source (changed root 0 "ERROR");
      let%bind events = collect source (List.exists ~f:is_stop) in
      assert (List.exists events ~f:(function
        | Stopped { reason; _ } -> String.equal reason "protocol stream closed but server did not exit"
        | _ -> false));
      let%bind () = wait_dead log in
      assert (count_method log "textDocument/didOpen" = 1);
      print_endline "live EOF: stop reported, process reaped without waiting for editor quit";
      [%expect {| live EOF: stop reported, process reaped without waiting for editor quit |}];
      return ())
      ~finally:(fun () -> Source.stop source; return ()))
;;

let%expect_test "pooled LSP: two documents, routed changes/saves, close/reopen, restart and shutdown" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let config = config ~args:[ "-log"; log; "-late-on-close"; "-request-first" ] () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    let send = Source.send source in
    let open_doc resource generation text =
      send (Document_opened { resource; generation });
      send (Document_changed { resource; revision = 0; text }) in
    open_doc a 1 "\tERROR";
    open_doc b 2 "\xf0\x9f\x98\x80WARN";
    let%bind events = collect source (fun events ->
      List.exists events ~f:(owned_diagnostic a 1 0)
      && List.exists events ~f:(owned_diagnostic b 2 0)) in
    List.iter events ~f:(function
      | Owned { resource; event = Diagnostics { findings = [ { location = Some l; _ } ]; _ }; _ } ->
        assert (l.column = if String.equal resource a then 9 else 3)
      | _ -> ());
    assert (count_method log "initialize" = 1 && count_method log "textDocument/didOpen" = 2);
    send (Document_changed { resource = a; revision = 1; text = "\xc3\xa9ERROR" });
    let%bind events = collect source (List.exists ~f:(owned_diagnostic a 1 1)) in
    assert (not (List.exists events ~f:(owned_diagnostic b 2 1)));
    send (Document_saved { resource = a; revision = 1 });
    send (Document_closed { resource = a });
    let%bind () = wait_for (fun () -> count_method log "textDocument/didClose" = 1) in
    assert (count_method log "shutdown" = 0);
    open_doc a 3 "INFO";
    let%bind events = collect source (List.exists ~f:(owned_diagnostic a 3 0)) in
    assert (not (List.exists events ~f:(function
       | Owned { event = Diagnostics d; _ } -> List.exists d.findings ~f:(fun f -> String.equal f.message "late closed version")
      | _ -> false)));
    send (Document_changed { resource = b; revision = 1; text = "\tWARN" });
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic b 2 1)) in
    send Restart;
    let%bind _ = collect source (fun events ->
      List.exists events ~f:(owned_diagnostic a 3 0)
      && List.exists events ~f:(owned_diagnostic b 2 1)) in
    assert (count_method log "initialize" = 2 && count_method log "textDocument/didOpen" = 5);
    assert (count_method log "textDocument/didSave" = 1);
    send Kill;
    send (Document_closed { resource = a });
    send (Document_changed { resource = b; revision = 2; text = "ERROR" });
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic b 2 2)) in
    send (Document_closed { resource = b });
    let%bind () = wait_for (fun () -> count_method log "exit" = 2) in
    assert (count_method log "shutdown" = 2);
    open_doc a 4 "ERROR";
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic a 4 0)) in
    Source.stop source; Source.stop source;
    let%bind () = wait_for (fun () -> count_method log "exit" = 3) in
    assert (count_method log "initialize" = 3 && count_method log "shutdown" = 3);
    let%bind () = wait_dead log in
    print_endline "one process; per-document columns/versions; sibling survives; late output rejected; one restart; all processes shut down";
    [%expect {| one process; per-document columns/versions; sibling survives; late output rejected; one restart; all processes shut down |}];
    return ())
;;

let%expect_test "pooled LSP isolates roots and effective configurations and rejects lexical URI collisions" =
  with_root (fun root ->
    List.iter [ "one"; "two" ] ~f:(fun dir -> Core_unix.mkdir (Filename.concat root dir));
    let log = Filename.concat root "wire.log" in
    let first = config ~args:[ "-log"; log ] () in
    let second = { first with args = [ "-log"; log; "-encoding"; "utf-8" ] } in
    let source = Lsp_client.start_workspace ~cell_width ~config_for_path:(fun path ->
      Some (if String.is_suffix path ~suffix:".mli" then second else first)) () in
    let a = Filename.concat root "one/a.ml" in
    let b = Filename.concat root "two/b.ml" in
    let c = Filename.concat root "one/c.mli" in
    List.iteri [ a; b; c ] ~f:(fun generation resource ->
      Source.send source (Document_opened { resource; generation });
      Source.send source (Document_changed { resource; revision = 0; text = "ERROR" }));
    let%bind events = collect source (fun events -> List.for_all (List.mapi [ a; b; c ] ~f:(fun g r -> r, g))
      ~f:(fun (r, g) -> List.exists events ~f:(owned_diagnostic r g 0))) in
    let sources = List.filter_map events ~f:(function
      | Owned { event = Diagnostics d; _ } -> Some d.source
      | _ -> None) |> String.Set.of_list in
    assert (Set.length sources = 3);
    assert (count_method log "initialize" = 3);
    (* A symlink alias is a different lexical URI, with independent unsaved text,
       but root discovery resolves its directory to the same workspace. *)
    Core_unix.symlink ~target:(Filename.concat root "one") ~link_name:(Filename.concat root "link");
    let symlink = Filename.concat root "link/a.ml" in
    Source.send source (Document_opened { resource = symlink; generation = 8 });
    Source.send source (Document_changed { resource = symlink; revision = 0; text = "\tWARN" });
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic symlink 8 0)) in
    assert (count_method log "initialize" = 3);
    let alias = Filename.concat root "one/./a.ml" in
    Source.send source (Document_opened { resource = alias; generation = 9 });
    let%bind _ = collect source (List.exists ~f:(function
      | Source_event.Owned { resource; generation = 9; event = Unavailable _ } -> String.equal resource alias
      | _ -> false)) in
    Source.send source (Document_closed { resource = alias });
    Source.send source (Document_changed { resource = a; revision = 1; text = "WARN" });
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic a 0 1)) in
    Source.send source (Document_changed { resource = a; revision = 2; text = "CRASH" });
    let%bind stopped = collect source (List.exists ~f:(function Source_event.Stopped _ -> true | _ -> false)) in
    let module Feedback = Ches_error.Error in
    let feedback = List.fold (events @ stopped) ~init:Feedback.empty ~f:(fun state event ->
      Feedback.apply state (Source_event.to_update event ~current_revision:0)) in
    List.iter (Feedback.Diagnostics.collections (Feedback.diagnostics feedback)) ~f:(fun collection ->
      assert (Bool.equal collection.session_ended (String.equal collection.resource a)));
    List.iter [ b; c ] ~f:(fun resource ->
      Source.send source (Document_changed { resource; revision = 1; text = "WARN" }));
    let%bind _ = collect source (fun events -> List.exists events ~f:(owned_diagnostic b 1 1)
      && List.exists events ~f:(owned_diagnostic c 2 1)) in
    Source.stop source;
    let%bind () = wait_for (fun () -> count_method log "exit" = 2) in
    assert (count_method log "shutdown" = 2);
    let pids = log_lines log |> List.map ~f:(fun line -> List.hd_exn (String.split line ~on:' ')) |> String.Set.of_list in
    assert (Set.length pids = 3);
    let%bind () = wait_dead log in
    print_endline "two roots and two configs: three distinct processes; lexical collision explicit and close harmless";
    [%expect {| two roots and two configs: three distinct processes; lexical collision explicit and close harmless |}];
    return ())
;;

let%expect_test "pooled workspace diagnostics are one collection with disk-based columns" =
  with_root (fun root ->
    let other = Filename.concat root "other.ml" in
    let%bind () = Writer.save other ~contents:"\tOTHER\n" in
    let config = config () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    List.iteri [ a; b ] ~f:(fun generation resource ->
      Source.send source (Document_opened { resource; generation });
      Source.send source (Document_changed { resource; revision = 0; text = "ERROR" }));
    let workspace = function
      | Source_event.Diagnostics { resource; revision = None; findings = [ { location = Some l; _ } ]; _ } ->
        String.equal resource other && l.column = 9
      | _ -> false in
    let%bind events = collect source (fun events -> List.exists events ~f:workspace
      && List.exists events ~f:(owned_diagnostic a 0 0)
      && List.exists events ~f:(owned_diagnostic b 1 0)) in
    let module Feedback = Ches_error.Error in
    let feedback = List.fold events ~init:Feedback.empty ~f:(fun state event ->
      Feedback.apply state (Source_event.to_update event ~current_revision:0)) in
    let collections = Feedback.Diagnostics.collections (Feedback.diagnostics feedback) in
    let others = List.filter collections ~f:(fun c -> String.equal c.resource other) in
    assert (List.length others = 1 && List.length (List.hd_exn others).findings = 1);
    Source.stop source;
    print_endline "unopened URI stays unowned/unversioned; disk columns; no per-document duplicate collections";
    [%expect {| unopened URI stays unowned/unversioned; disk columns; no per-document duplicate collections |}];
    return ())
;;

let%expect_test "pooled LSP uses each document's old text and bounds revision history" =
  with_root (fun root ->
    let config = config ~args:[ "-replay-on-save" ] () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    let send = Source.send source in
    List.iteri [ a, "\tERROR"; b, "\xf0\x9f\x98\x80WARN" ] ~f:(fun generation (resource, text) ->
      send (Document_opened { resource; generation });
      send (Document_changed { resource; revision = 0; text }));
    let both revision events = List.exists events ~f:(owned_diagnostic a 0 revision)
      && List.exists events ~f:(owned_diagnostic b 1 revision) in
    let%bind _ = collect source (both 0) in
    List.iter [ a; b ] ~f:(fun resource -> send (Document_changed { resource; revision = 1; text = "ERROR" }));
    let%bind _ = collect source (both 1) in
    List.iter [ a; b ] ~f:(fun resource -> send (Document_saved { resource; revision = 1 }));
    let%bind events = collect source (both 0) in
    List.iter events ~f:(function
      | Owned { resource; event = Diagnostics { revision = Some 0; findings = [ { location = Some l; _ } ]; _ }; _ } ->
        assert (l.column = if String.equal resource a then 9 else 3)
      | _ -> ());
     let%bind () = Deferred.List.iter (List.range 2 35) ~how:`Sequential ~f:(fun revision ->
       send (Document_changed { resource = a; revision; text = "ERROR" });
       collect source (List.exists ~f:(owned_diagnostic a 0 revision)) >>| ignore) in
    send (Document_saved { resource = a; revision = 34 });
    send (Document_changed { resource = b; revision = 2; text = "WARN" });
    let%bind events = collect source (List.exists ~f:(owned_diagnostic b 1 2)) in
    assert (not (List.exists events ~f:(owned_diagnostic a 0 0)));
    Source.stop source;
    print_endline "old UTF-16 positions use document-specific text; evicted wire versions discarded";
    [%expect {| old UTF-16 positions use document-specific text; evicted wire versions discarded |}];
    return ())
;;

let%expect_test "pooled LSP kills a server exceeding shutdown grace" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let config = { (config ~args:[ "-log"; log; "-ignore-shutdown" ] ()) with
      shutdown_grace = Time_ns.Span.of_int_ms 30 } in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let resource = Filename.concat root "a.ml" in
    Source.send source (Document_opened { resource; generation = 1 });
    Source.send source (Document_changed { resource; revision = 0; text = "ERROR" });
    let%bind _ = collect source (List.exists ~f:(owned_diagnostic resource 1 0)) in
    Source.stop source;
    let%bind () = wait_for (fun () -> count_method log "shutdown" = 1) in
    let%bind () = wait_dead log in
    assert (count_method log "exit" = 0);
    print_endline "unresponsive pooled child killed and reaped";
    [%expect {| unresponsive pooled child killed and reaped |}];
    return ())
;;

let%expect_test "unversioned server: reopen receives normal current-URI diagnostics" =
  with_root (fun root ->
    let config = config ~args:[ "-unversioned" ] () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    let send = Source.send source in
    let is_unversioned resource generation = function
      | Source_event.Owned { resource = r; generation = g; event = Diagnostics { revision = None; _ } } ->
        String.equal resource r && generation = g
      | _ -> false in
    let open_doc resource generation =
      send (Document_opened { resource; generation });
      send (Document_changed { resource; revision = 0; text = "ERROR" }) in
    open_doc a 1; open_doc b 2;
    let both generation events = List.exists events ~f:(is_unversioned a generation)
      && List.exists events ~f:(is_unversioned b 2) in
    let%bind _ = collect source (both 1) in
    send (Document_closed { resource = a }); open_doc a 3;
    send (Document_changed { resource = b; revision = 1; text = "WARN" });
     let%bind _ = collect source (both 3) in
    send Restart;
    let%bind _ = collect source (both 3) in
    Source.stop source;
     print_endline "unversioned output remains available on reopen and restart for both documents";
     [%expect {| unversioned output remains available on reopen and restart for both documents |}];
    return ())
;;

let%expect_test "restart and reopen during initialization supersede pending launches" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let config = { (config ~args:[ "-log"; log; "-delay-init" ] ()) with
      shutdown_grace = Time_ns.Span.of_int_ms 30 } in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    let send = Source.send source in
    let open_doc resource generation text =
      send (Document_opened { resource; generation });
      send (Document_changed { resource; revision = 0; text }) in
    open_doc a 1 "ERROR";
    let%bind () = wait_for (fun () -> count_method log "initialize" = 1) in
    open_doc b 3 "INFO";
    send Restart; send Restart;
    send (Document_closed { resource = a });
    open_doc a 2 "WARN";
    let%bind events = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 2 0)
      && List.exists events ~f:(owned_diagnostic b 3 0)) in
    assert (not (List.exists events ~f:(owned_diagnostic a 1 0)));
    assert (count_method log "textDocument/didOpen" = 2);
    assert (List.count events ~f:(function Source_event.Started _ -> true | _ -> false) = 1);
    Source.stop source;
    let%bind () = wait_dead log in
    print_endline "only the current launch opens newest lifetimes; pending and initialized children reaped";
    [%expect {| only the current launch opens newest lifetimes; pending and initialized children reaped |}];
    return ())
;;

let wire_notifications path =
  log_lines path |> List.map ~f:(fun line ->
    let notification = match Jsonrpc.Packet.t_of_yojson (Yojson.Safe.from_string line) with
      | Notification n -> n | _ -> failwith "expected wire notification" in
    match Lsp.Client_notification.of_jsonrpc notification with
    | Ok notification -> notification | Error message -> failwith message)
;;

let wire_changes path =
  wire_notifications path |> List.filter_map ~f:(function
    | TextDocumentDidChange change -> Some change
    | _ -> None)
;;

let%expect_test "sync kinds: burst coalescing, independent queues, Unicode ranges and save flush" =
  Deferred.List.iter ~how:`Sequential
    [ "full", "utf-16"; "incremental", "utf-16"; "options", "utf-8";
      "incremental", "utf-32"; "incremental", "none" ]
    ~f:(fun (sync, encoding) -> with_root (fun root ->
      let log = Filename.concat root "wire.log" and payload = Filename.concat root "payload.log" in
      let config = config ~args:[ "-sync"; sync; "-encoding"; encoding; "-log"; log;
        "-payload-log"; payload; "-replay-on-save"; "-gap-on-save" ] () in
      let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
      let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
      let send = Source.send source in
      let tail = String.make 100_000 'x' in
      let old_text = "\t\xc3\xa9\xf0\x9f\x98\x80OLD\nremove\nsuffix\n" ^ tail in
      let newest = "\t\xc3\xa9\xf0\x9f\x98\x81NEW\nsuffix\n" ^ tail in
      List.iteri [ a, old_text; b, "WARN" ] ~f:(fun generation (resource, text) ->
        send (Document_opened { resource; generation });
        send (Document_changed { resource; revision = 0; text }));
      let%bind _ = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 0 0)
        && List.exists events ~f:(owned_diagnostic b 1 0)) in
      (* No scheduler yield in the burst: count work, not a timer threshold. *)
      for revision = 1 to 100 do
        send (Document_changed { resource = a; revision; text = if revision = 100 then newest else "obsolete" });
        send (Document_changed { resource = b; revision; text = if revision = 100 then "INFO" else "obsolete" })
      done;
      send (Document_saved { resource = a; revision = 100 });
      let%bind events = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 0 100)
        && List.exists events ~f:(owned_diagnostic b 1 100)) in
      assert (not (List.exists events ~f:(function
        | Owned { event = Diagnostics { revision = Some r; _ }; _ } -> r > 0 && r < 100
        | _ -> false)));
      let changes = wire_changes payload in
      assert (List.length changes = 2);
      let a_change = List.find_exn changes ~f:(fun c -> String.equal (Lsp.Uri.to_path c.textDocument.uri) a) in
      let change = List.hd_exn a_change.contentChanges in
      if String.equal sync "full" then (
        assert (Option.is_none change.range && String.equal change.text newest))
      else (
        let range = Option.value_exn change.range in
        assert (range.start.line = 0 && range.start.character = if String.equal encoding "utf-8" then 3 else 2);
        assert (range.end_.line = 1 && range.end_.character = 6);
        assert (String.equal change.text "\xf0\x9f\x98\x81NEW");
        assert (String.length (Yojson.Safe.to_string (Lsp.Types.DidChangeTextDocumentParams.yojson_of_t a_change)) < 400));
      let notifications = wire_notifications payload in
      let before_save = List.take_while notifications ~f:(function DidSaveTextDocument _ -> false | _ -> true) in
      assert (List.exists before_save ~f:(function
        | TextDocumentDidChange c -> String.equal (Lsp.Uri.to_path c.textDocument.uri) a
        | _ -> false));
      if String.equal sync "options" then
        assert (List.exists notifications ~f:(function
          | DidSaveTextDocument { text = Some text; _ } -> String.equal text newest
          | _ -> false));
      (* Save replays version zero: coalesced-away versions must not evict sent history. *)
      send (Document_saved { resource = a; revision = 100 });
      let%bind _ = collect source (List.exists ~f:(owned_diagnostic a 0 0)) in
      Source.stop source;
      let%bind () = wait_dead log in
      let text_bytes = List.sum (module Int) changes ~f:(fun c ->
        List.sum (module Int) c.contentChanges ~f:(fun change -> String.length change.text)) in
      printf "%s/%s: 200 updates -> 2 changes, %d text bytes; correct replacement, save ordering and sent history\n" sync encoding text_bytes;
      return ()))
  >>| fun () ->
  [%expect {|
    full/utf-16: 200 updates -> 2 changes, 100022 text bytes; correct replacement, save ordering and sent history
    incremental/utf-16: 200 updates -> 2 changes, 11 text bytes; correct replacement, save ordering and sent history
    options/utf-8: 200 updates -> 2 changes, 11 text bytes; correct replacement, save ordering and sent history
    incremental/utf-32: 200 updates -> 2 changes, 11 text bytes; correct replacement, save ordering and sent history
    incremental/none: 200 updates -> 2 changes, 11 text bytes; correct replacement, save ordering and sent history
    |}]
;;

let%expect_test "unsupported sync and incremental fallback do not invent positions or versions" =
  let%bind () = Deferred.List.iter [ "none"; "absent" ] ~how:`Sequential ~f:(fun sync ->
    with_root (fun root ->
      let log = Filename.concat root "wire.log" in
      let source = Lsp_client.start ~config:(config ~args:[ "-sync"; sync; "-log"; log ] ()) ~cell_width ~root () in
      Source.send source (changed root 0 "ERROR");
      let%bind _ = collect source (List.exists ~f:(is_diagnostics ~revision:0)) in
      Source.send source (changed root 1 "WARN");
      Source.send source (Document_saved { resource = Filename.concat root "a.ml"; revision = 1 });
      let%bind () = wait_for (fun () -> count_method log "textDocument/didSave" = 1) in
      Source.stop source;
      let%bind () = wait_dead log in
      assert (count_method log "textDocument/didChange" = 0);
      return ())) in
  let%bind () = Deferred.List.iter [ "unknown", "WARN"; "utf-16", "\xffWARN" ] ~how:`Sequential
    ~f:(fun (encoding, text) -> with_root (fun root ->
      let log = Filename.concat root "wire.log" and payload = Filename.concat root "payload.log" in
      let source = Lsp_client.start ~config:(config ~args:[ "-sync"; "incremental"; "-encoding"; encoding;
        "-log"; log; "-payload-log"; payload ] ()) ~cell_width ~root () in
      Source.send source (changed root 0 "ERROR");
      let%bind _ = collect source (List.exists ~f:(is_diagnostics ~revision:0)) in
      Source.send source (changed root 1 text);
      let%bind _ = collect source (List.exists ~f:(is_diagnostics ~revision:1)) in
      let c = List.hd_exn (wire_changes payload) in
      assert (Option.is_none (List.hd_exn c.contentChanges).range);
      assert (String.equal (List.hd_exn c.contentChanges).text text);
      Source.stop source;
      let%bind () = wait_dead log in
      return ())) in
  print_endline "None/absent: no didChange; unknown encoding/invalid UTF-8: safe full fallback";
  [%expect {| None/absent: no didChange; unknown encoding/invalid UTF-8: safe full fallback |}];
  return ()
;;

let%expect_test "pending changes cancel on close/reopen, restart and stop; initialization opens latest" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" and payload = Filename.concat root "payload.log" in
    let config = config ~args:[ "-sync"; "incremental"; "-delay-init"; "-log"; log; "-payload-log"; payload ] () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config) ~cell_width () in
    let a = Filename.concat root "a.ml" and b = Filename.concat root "b.ml" in
    let send = Source.send source in
    let open_doc resource generation text =
      send (Document_opened { resource; generation });
      send (Document_changed { resource; revision = 0; text }) in
    open_doc a 1 "CRASH"; open_doc b 2 "WARN";
    let%bind () = wait_for (fun () -> count_method log "initialize" = 1) in
    send (Document_changed { resource = a; revision = 1; text = "INFO" });
    send (Document_saved { resource = a; revision = 1 });
    let%bind _ = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 1 1)
      && List.exists events ~f:(owned_diagnostic b 2 0)) in
    let%bind () = wait_for (fun () -> count_method log "textDocument/didSave" = 1) in
    assert (List.is_empty (wire_changes payload));
    send (Document_changed { resource = a; revision = 2; text = "CRASH" });
    send (Document_closed { resource = a });
    open_doc a 3 "ERROR";
    (* A sibling's timer provides a protocol barrier beyond the cancelled window. *)
    send (Document_changed { resource = b; revision = 1; text = "INFO" });
    let%bind _ = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 3 0)
      && List.exists events ~f:(owned_diagnostic b 2 1)) in
    assert (List.length (wire_changes payload) = 1);
    send (Document_changed { resource = a; revision = 1; text = "WARN" });
    send Restart;
    let%bind _ = collect source (fun events -> List.exists events ~f:(owned_diagnostic a 3 1)
      && List.exists events ~f:(owned_diagnostic b 2 1)) in
    assert (List.length (wire_changes payload) = 1);
    send (Document_changed { resource = a; revision = 2; text = "CRASH" });
    Source.stop source;
    let%bind () = wait_dead log in
    assert (List.length (wire_changes payload) = 1 && count_method log "shutdown" = 2);
    print_endline "newest initialization/open; pre-init save; cancelled close/restart/stop work; children reaped";
    [%expect {| newest initialization/open; pre-init save; cancelled close/restart/stop work; children reaped |}];
    return ())
;;

let%expect_test "incremental changes reconstruct Unicode insert/delete and CRLF safely" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let source = Lsp_client.start ~config:(config ~args:[ "-sync"; "incremental"; "-log"; log ] ()) ~cell_width ~root () in
    let texts = [ "\xc3\xa9\xf0\x9f\x98\x80\r\nERROR"; "\xc3\xa9\xf0\x9f\x98\x80\nERROR";
      "\xc3\xa9\xf0\x9f\x98\x80\r\nERROR"; "\xc3\xa9\xf0\x9f\x98\x80\r\n\tERROR";
      "\xc3\xa9\xf0\x9f\x98\x80\rERROR"; "\xc3\xa9\xf0\x9f\x98\x80\r\tERROR";
      ""; "ERROR"; "ERROR" ] in
    let%bind () = Deferred.List.iter (List.mapi texts ~f:(fun revision text -> revision, text))
      ~how:`Sequential ~f:(fun (revision, text) ->
        Source.send source (changed root revision text);
        collect source (List.exists ~f:(is_diagnostics ~revision)) >>| fun events ->
        List.iter events ~f:(function
          | Diagnostics { revision = Some r; findings; _ } when r = revision ->
            assert (List.length findings = if String.is_empty text then 0 else 1)
          | _ -> ())) in
    Source.stop source;
    let%bind () = wait_dead log in
    print_endline "Unicode/CRLF insertion, deletion, empty and unchanged revisions reconstruct correctly";
    [%expect {| Unicode/CRLF insertion, deletion, empty and unchanged revisions reconstruct correctly |}];
    return ())
;;
