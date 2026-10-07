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

let%expect_test "the root: markers in priority order, each searched up all ancestors" =
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
    (* dune-project outranks the nearer package.json; *.opam is a literal name. *)
    show "repo/proj/lib/deep/a.ml";
    show "repo/b.ml";
    show "loose/c.ml";
    [%expect
      {|
      <root>/repo/proj
      <root>/repo
      <root>/loose
      |}];
    return ())
;;

let%expect_test "slang root: project config before git, then the file's directory" =
  with_root (fun root ->
    List.iter [ "repo/.git"; "repo/rtl/.slang"; "repo/rtl/sub/.git"; "loose" ]
      ~f:(fun path -> Core_unix.mkdir_p (Filename.concat root path));
    List.iter [ "repo/rtl/sub/a.sv"; "repo/b.v"; "loose/c.svh" ] ~f:(fun path ->
      let found = Lsp_client.Config.(root slang_server) (Filename.concat root path) in
      print_endline (String.substr_replace_all found ~pattern:root ~with_:"<root>"));
    [%expect
      {|
      <root>/repo/rtl
      <root>/repo
      <root>/loose
      |}];
    return ())
;;
