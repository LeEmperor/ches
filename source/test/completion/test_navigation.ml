open! Core
open! Async
open Ches_source
open Ches_error.Language_query
module H = Test_completion.H

let request resource revision id kind : request =
  { token = { resource; generation = 7; revision; request = id }; cursor = 11; kind }

let rec replies events = List.concat_map events ~f:(function
  | Ches_error.Source_event.Query_result reply -> [reply]
  | Owned { event; _ } -> replies [event] | _ -> [])

let rec receive source =
  match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 12) (Source.next_batch source) with
  | `Timeout -> failwith "query reply timeout"
  | `Result events -> match replies events with [] -> receive source | x :: _ -> return x

let start root args =
  let source = Lsp_client.start ~config:(H.config ~args ()) ~cell_width:H.cell_width ~root () in
  let resource = Filename.concat root "a.ml" in
  Source.send source (Document_opened { resource; generation = 7 });
  Source.send source (Document_changed { resource; revision = 1; text = "😀\n😀fo" });
  let%map () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
  source, resource

let%expect_test "references and instance pipeline use server identity and direct destinations" =
  H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "instances"] in
    Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
    let ask id kind =
      Source.send source (Query (request resource 2 id kind));
      receive source >>| fun reply -> reply.result in
    let%bind refs = ask 1 References in
    (match refs with Locations [_] -> () | _ -> failwith "references failed");
    let%bind found = ask 2 Instances in
    (match found with
     | Instance_list inventory ->
       assert (String.equal inventory.module_name "leaf");
       assert (inventory.module_range.start.character = 2);
       assert (Option.equal String.equal inventory.active (Some "top.wide"));
       assert (List.length inventory.instances = 2)
     | Failed s -> failwith s | _ -> failwith "missing inventory");
    let%bind rejected = ask 3 (Activate_instance { module_name = "leaf"; hier_path = "unlisted" }) in
    assert (match rejected with Failed _ -> true | _ -> false);
    let%bind activated = ask 4 (Activate_instance { module_name = "leaf"; hier_path = "top.narrow" }) in
    assert (match activated with Instance_activated _ -> true | _ -> false);
    let%bind stale = ask 5 (Activate_instance { module_name = "leaf"; hier_path = "top.wide" }) in
    assert (match stale with Failed _ -> true | _ -> false);
    let%bind location = ask 6 Instantiation in
    (match location with
     | Locations [target] -> assert (String.equal target.path "/tmp/instance #%é.sv");
       assert (target.selection.start.line = 3)
     | _ -> failwith "missing current instantiation");
    Source.stop source;
    print_endline "references context; enclosing second module; validated activation; stale inventory; exact URI";
    [%expect {| references context; enclosing second module; validated activation; stale inventory; exact URI |}];
    return ())

let%expect_test "shared exact position helper handles Unicode, CRLF, invalid boundaries" =
  let text = "a😀é\r\nz\rx\n" in
  List.iter [Utf8; Utf16; Utf32] ~f:(fun encoding ->
    let wire = match encoding with Utf8 -> Completion_wire.Utf8 | Utf16 -> Utf16 | Utf32 -> Utf32 in
    List.iter [0; 1; 5; 7; 9; 10; 11; 12; 13] ~f:(fun byte ->
      let p = Completion_wire.position wire text byte |> Option.value_exn in
      assert (Option.equal Int.equal (offset encoding ~text {line = p.line; character = p.character}) (Some byte)));
    assert (Option.is_none (offset encoding ~text {line = 0; character = 99})));
  assert (Option.is_none (offset Utf16 ~text {line = 0; character = 2}));
  assert (Option.is_none (offset Utf8 ~text {line = 0; character = 2}));
  assert (Option.is_none (offset Utf8 ~text:"bad\xff" {line = 0; character = 0}));
  assert (Option.is_none (offset Utf8 ~text {line = -1; character = 0}));
  [%expect {| |}]; return ()

let%expect_test "instance command versions and failed activation retain no invented context" =
  let%bind () = Deferred.List.iter ["instances-symbols"; "instances-activate"; "instances-fail"; "instances-refresh"]
    ~how:`Sequential ~f:(fun profile -> H.with_root (fun root ->
      let%bind source, resource = start root ["-navigation"; profile] in
      Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
      Source.send source (Query (request resource 2 1 Instances));
      let%bind inventory = receive source in
      assert (match inventory.result with Instance_list _ -> true | _ -> false);
      Source.send source (Query (request resource 2 2 (Activate_instance { module_name = "leaf"; hier_path = "top.narrow" })));
      let%bind reply = receive source in
      assert (match reply.result with
        | Failed _ -> String.equal profile "instances-fail"
        | Instance_activated _ -> not (String.equal profile "instances-fail") | _ -> false);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "instance inventories carry the exact negotiated range encoding" =
  let%bind () = Deferred.List.iter ["utf-8", Utf8; "utf-16", Utf16; "utf-32", Utf32]
    ~how:`Sequential ~f:(fun (wire_encoding, encoding) -> H.with_root (fun root ->
      let%bind source, resource = start root ["-navigation"; "instances"; "-encoding"; wire_encoding] in
      Source.send source (Document_changed { resource; revision = 2; text = "😀abcdefg" });
      Source.send source (Query (request resource 2 1 Instances));
      let%bind reply = receive source in
      (match reply.result with
       | Instance_list inventory ->
         assert (equal_encoding inventory.encoding encoding);
         List.iter inventory.instances ~f:(fun instance ->
           assert (equal_encoding (Option.value_exn instance.target).encoding encoding))
       | _ -> failwith "missing encoded inventory");
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "references capability, null and exact server errors never use declaration fallback" =
  let%bind () = Deferred.List.iter ["instances", "all-null"; "instances", "fallback-error";
      "ocaml", "normal"; "disabled", "normal"] ~how:`Sequential ~f:(fun (caps, mode) ->
    H.with_root (fun root ->
      let log = Filename.concat root "requests.log" in
      let%bind source, resource = start root ["-navigation"; caps; "-navigation-result"; mode; "-log"; log] in
      Source.send source (Query (request resource 1 1 References));
      let%bind reply = receive source in
      assert (match reply.result with
        | Locations [] -> String.equal mode "all-null"
        | Failed s -> if String.equal mode "fallback-error" then String.equal s "genuine server error"
          else String.equal s "Language server does not support this query"
        | _ -> false);
      let%bind lines = Reader.file_lines log in
      assert (not (List.exists lines ~f:(fun line ->
        String.is_suffix line ~suffix:"textDocument/declaration" || String.is_suffix line ~suffix:"textDocument/definition")));
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "top-level instance has an explicit no-location notice" =
  H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "instances-top"] in
    Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
    Source.send source (Query (request resource 2 1 Instantiation));
    let%bind reply = receive source in
    assert (match reply.result with Failed s -> String.is_substring s ~substring:"top-level" | _ -> false);
    Source.stop source;
    [%expect {| |}]; return ())

let%expect_test "module identity excludes same-named children and foreign included-file symbols" =
  let p character = `Assoc ["line", `Int 0; "character", `Int character] in
  let range a b = `Assoc ["start", p a; "end", p b] in
  let module_ name a b children = `Assoc ["name", `String name; "kind", `Int 2;
    "range", range a b; "children", `List children] in
  let json = `List [module_ "first" 0 9 [];
    module_ "second" 10 99 [`Assoc ["name", `String "first"; "kind", `Int 13; "range", range 20 40]];
    `Assoc ["name", `String "included"; "kind", `Int 2; "location", `Assoc [
      "uri", `String "file:///included.svh"; "range", range 25 35]]] in
  let candidates = Instance_wire.modules ~uri:"file:///source.sv" ~position:{ line = 0; character = 30 } json in
  assert ([%equal: string list] (List.map candidates ~f:fst) ["second"]);
  [%expect {| |}]; return ()

let%expect_test "instance activation invalidates hover and completion across connection documents" =
  H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "instances"; "-hold-query"; "-hold-completion"] in
    Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
    Source.send source (Query (request resource 2 1 Instances));
    let%bind _ = receive source in
    let sibling = Filename.concat root "sibling.ml" in
    Source.send source (Document_opened { resource = sibling; generation = 7 });
    Source.send source (Document_changed { resource = sibling; revision = 2; text = "😀\n😀fo" });
    Source.send source (Query (request sibling 2 2 Hover));
    Source.send source (Complete (Test_completion.request sibling 7 2 3));
    Source.send source (Query (request resource 2 4 (Activate_instance { module_name = "leaf"; hier_path = "top.narrow" })));
    let%bind activated = receive source in
    assert (match activated.result with Instance_activated _ -> true | _ -> false);
    Source.send source (Document_saved { resource = sibling; revision = 2 });
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 150) in
    let events = Source.poll source in
    assert (List.is_empty (replies events));
    assert (List.is_empty (Test_completion.replies events));
    Source.stop source;
    [%expect {| |}]; return ())

let%expect_test "unanswered activation expires with unknown context and rejects inventory reuse" =
  H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "instances-held"] in
    Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
    Source.send source (Query (request resource 2 1 Instances));
    let%bind _ = receive source in
    Source.send source (Query (request resource 2 2 (Activate_instance { module_name = "leaf"; hier_path = "top.narrow" })));
    let%bind reply = receive source in
    assert (match reply.result with Failed message -> String.equal message "Language query timed out" | _ -> false);
    Source.send source (Query (request resource 2 3 (Activate_instance { module_name = "leaf"; hier_path = "top.wide" })));
    let%bind reply = receive source in
    assert (match reply.result with Failed _ -> true | _ -> false);
    Source.send source (Document_saved { resource; revision = 2 });
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
    let events = Source.poll source in
    assert (List.is_empty (replies events));
    assert (List.exists events ~f:(function
      | Instance_context_changed { module_name = Some "leaf"; hier_path = Some "top.narrow"; _ } -> true
      | _ -> false));
    Source.stop source;
    [%expect {| |}]; return ())

let%expect_test "late cancelled activation still invalidates pooled context without stale acknowledgement" =
  H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "instances-held"] in
    Source.send source (Document_changed { resource; revision = 2; text = "abcdefghijk" });
    Source.send source (Query (request resource 2 1 Instances));
    let%bind _ = receive source in
    let q = request resource 2 2 (Activate_instance { module_name = "leaf"; hier_path = "top.narrow" }) in
    Source.send source (Query q);
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
    ignore (Source.poll source : Ches_error.Source_event.t list);
    Source.send source (Cancel_query q.token);
    Source.send source (Document_changed { resource; revision = 3; text = "changed" });
    Source.send source (Document_saved { resource; revision = 3 });
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 150) in
    let events = Source.poll source in
    assert (List.is_empty (replies events));
    assert (List.exists events ~f:(function
      | Instance_context_changed { module_name = Some "leaf"; hier_path = Some "top.narrow"; _ } -> true
      | _ -> false));
    Source.stop source;
    [%expect {| |}]; return ())

let%expect_test "OCaml and Slang capabilities, both preference orders, fallback and flush" =
  let cases = List.concat_map ["utf-8"; "utf-16"; "utf-32"] ~f:(fun encoding ->
    List.concat_map ["ocaml"; "slang"; "declaration"] ~f:(fun caps ->
      List.concat_map ["normal"; "null"; "empty"; "locate"; "method"; "error"; "all-null"] ~f:(fun mode ->
        List.map [Declaration; Definition] ~f:(fun kind -> encoding, caps, mode, kind)))) in
  let%bind () = Deferred.List.iter cases ~how:`Sequential ~f:(fun (encoding, caps, mode, kind) ->
    H.with_root (fun root ->
      let mode = if equal_kind kind Definition then "reverse-" ^ mode else mode in
      let log = Filename.concat root "wire.log" in
      let%bind source, resource = start root ["-navigation"; caps; "-navigation-result"; mode;
        "-encoding"; encoding; "-sync"; "incremental"; "-log"; log] in
      Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
      let q = request resource 2 1 kind in
      Source.send source (Query q);
       let%bind reply = receive source in
       assert (equal_kind reply.kind kind && Ches_completion.Model.Token.equal q.token reply.token);
       let sole_primary = (String.equal caps "slang" && equal_kind kind Definition)
         || (String.equal caps "declaration" && equal_kind kind Declaration) in
       let suffix s = String.is_suffix mode ~suffix:s in
       let failed = suffix "error" && (String.equal caps "ocaml" || sole_primary)
         || sole_primary && (suffix "locate" || suffix "method") in
       (match reply.result with
        | Locations targets ->
          assert (not failed);
          let empty = suffix "all-null" || sole_primary && (suffix "null" || suffix "empty") in
          assert (List.length targets = if empty then 0 else 1);
          List.iter targets ~f:(fun target ->
            assert (String.equal target.path resource);
            assert (Option.equal Int.equal (offset target.encoding ~text:"😀\n😀fo" target.selection.start) (Some 11)))
        | Failed _ -> assert failed
       | _ -> assert false);
      let%bind lines = Reader.file_lines log in
      let methods = List.map lines ~f:(fun line -> List.last_exn (String.split line ~on:' ')) in
      let index name = List.findi_exn methods ~f:(fun _ m -> String.equal m name) |> fst in
      let queries = List.filter methods ~f:(fun m -> List.mem
        ["textDocument/declaration"; "textDocument/definition"] m ~equal:String.equal) in
      let first = List.hd_exn queries in
      assert (index "textDocument/didChange" < index first);
      if String.equal caps "ocaml" then (
        assert (String.equal first (if equal_kind kind Declaration then "textDocument/declaration" else "textDocument/definition"));
        let one = String.is_suffix mode ~suffix:"error" || String.is_suffix mode ~suffix:"normal" in
        assert (List.length queries = if one then 1 else 2))
      else assert (List.length queries = 1);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "errors in the last fallback retain failure rather than becoming empty locations" =
  let%bind () = Deferred.List.iter [Declaration; Definition] ~how:`Sequential ~f:(fun kind ->
    Deferred.List.iter ["fallback-error"; "fallback-method"; "fallback-locate"] ~how:`Sequential ~f:(fun mode ->
      H.with_root (fun root ->
        let mode = if equal_kind kind Definition then "reverse-" ^ mode else mode in
        let log = Filename.concat root "wire.log" in
        let%bind source, resource = start root ["-navigation"; "ocaml"; "-navigation-result"; mode; "-log"; log] in
        Source.send source (Query (request resource 1 1 kind));
        let%bind reply = receive source in
        assert (equal_kind reply.kind kind);
        assert (match reply.result with Failed message -> String.equal message "genuine server error" | _ -> false);
        let%map lines = Reader.file_lines log in
        assert (List.count lines ~f:(fun line -> String.is_suffix line ~suffix:"textDocument/declaration"
          || String.is_suffix line ~suffix:"textDocument/definition") = 2);
        Source.stop source))) in
  [%expect {| |}]; return ()

let%expect_test "stale resource, revision, generation and invalid cursor never reach the wire" =
  let%bind () = H.with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let%bind source, resource = start root ["-navigation"; "ocaml"; "-log"; log] in
    let q = request resource 1 1 Hover in
    let cases = [{q with token = {q.token with resource = resource ^ ".missing"}};
      {q with token = {q.token with revision = 0}};
      {q with token = {q.token with generation = 6}};
      {q with cursor = -1}; {q with cursor = 2}; {q with cursor = 1000}] in
    let%bind () = Deferred.List.iter cases ~how:`Sequential ~f:(fun q ->
      Source.send source (Query q);
      let%map reply = receive source in
      assert (match reply.result with Failed _ -> true | _ -> false)) in
    let%map lines = Reader.file_lines log in
    assert (not (List.exists lines ~f:(String.is_suffix ~suffix:"textDocument/hover")));
    Source.stop source) in
  [%expect {| |}]; return ()

let%expect_test "escaped source URIs retain symlink roots and targets use destination encoding" =
  let%bind () = Deferred.List.iter ["utf-8"; "utf-16"; "utf-32"; "none"] ~how:`Sequential ~f:(fun encoding ->
    H.with_root (fun parent ->
      let real = Filename.concat parent "real #%é" in
      let root = Filename.concat parent "alias #%25é" in
      Core_unix.mkdir real;
      Core_unix.symlink ~target:real ~link_name:root;
      let%bind source, resource = start root ["-navigation"; "ocaml"; "-navigation-result"; "destination"; "-encoding"; encoding] in
      Source.send source (Query (request resource 1 1 Definition));
      let%bind reply = receive source in
      let target = match reply.result with Locations [target] -> target | _ -> failwith "expected destination" in
      assert (String.equal target.path (Filename.concat root "destination #%é.ml"));
      let expected = match encoding with "utf-8" -> Utf8 | "utf-32" -> Utf32 | _ -> Utf16 in
      assert (equal_encoding target.encoding expected);
      let text = "é😀chosen\n" in
      assert (Option.equal Int.equal (offset target.encoding ~text target.selection.start) (Some 6));
      assert (Option.equal Int.equal (offset target.encoding ~text target.selection.stop) (Some 12));
      assert (Option.is_none (offset target.encoding ~text:"😀\n😀fo" target.selection.start));
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "multiline hover formats and null are preserved" =
  let%bind () = Deferred.List.iter ["normal"; "all-null"] ~how:`Sequential ~f:(fun mode ->
    H.with_root (fun root ->
      let%bind source, resource = start root ["-navigation"; "ocaml"; "-navigation-result"; mode] in
      Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
      Source.send source (Query (request resource 2 1 Hover));
      let%bind reply = receive source in
      (match reply.result with
       | Hover_result None -> assert (String.equal mode "all-null")
       | Hover_result (Some hover) ->
         assert (List.length hover.contents = 3);
         assert (String.equal (List.hd_exn hover.contents).value "**type**\n\n😀\n😀fo");
         assert (String.equal (List.last_exn hover.contents).value "```ocaml\nval x : int\nval y : int\n```")
       | _ -> assert false);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "URI decoding, lexical aliases, location links, validation and bounds" =
  let p n = `Assoc ["line", `Int 0; "character", `Int n] in
  let range a b = `Assoc ["start", p a; "end", p b] in
  let link uri selection = `List [`Assoc ["targetUri", `String uri;
    "targetRange", range 0 8; "targetSelectionRange", selection]] in
  let uri = "file:///tmp/alias/../symlink/a%20%23%25%C3%A9.ml" in
  let targets = Navigation_wire.locations Utf16 (link uri (range 2 2)) |> Result.ok_or_failwith in
  assert (String.equal (List.hd_exn targets).path "/tmp/symlink/a #%é.ml");
  List.iter ["file:/tmp/a%2525%C3%A9"; "file:///tmp/a%2525%C3%A9"; "FILE://LOCALHOST/tmp/a%2525%C3%A9"] ~f:(fun uri ->
    assert (String.equal (Navigation_wire.path uri |> Result.ok_or_failwith) "/tmp/a%25é"));
  assert (String.equal (Navigation_wire.path "file://localhost/" |> Result.ok_or_failwith) "/");
  List.iter ["https://example.com/a"; "file://remote/a"; "file:///a%Q0"; "file:///a%00"; "file:///a#b";
    "file:relative"; "file://localhost"; "file:///a?b"; "file:///a%FF"] ~f:(fun uri ->
    assert (Result.is_error (Navigation_wire.locations Utf8 (link uri (range 0 0)))));
  assert (Result.is_error (Navigation_wire.locations Utf8 (link uri (range 7 9))));
  assert (Result.is_error (Navigation_wire.locations Utf8 (link uri (range 4 3))));
  assert (Result.is_error (Navigation_wire.locations Utf8 (link uri (range (-1) 3))));
  assert (Result.is_error (Navigation_wire.locations Utf8 (`List [`Assoc ["targetUri", `String uri;
    "targetRange", range 8 0; "targetSelectionRange", range 0 0]])));
  let loc = `Assoc ["uri", `String uri; "range", range 1 2] in
  assert (Result.is_ok (Navigation_wire.locations Utf8 loc));
  assert (Result.is_ok (Navigation_wire.locations Utf8 (`List [loc; loc])));
  let second = `Assoc ["uri", `String "file:///second.ml"; "range", range 0 0] in
  let ordered = Navigation_wire.locations Utf32 (`List [second; loc]) |> Result.ok_or_failwith in
  assert (List.equal String.equal (List.map ordered ~f:(fun t -> t.path))
    ["/second.ml"; "/tmp/symlink/a #%é.ml"]);
  assert (List.for_all ordered ~f:(fun t -> equal_range t.range t.selection && equal_encoding t.encoding Utf32));
  assert (Result.is_error (Navigation_wire.locations Utf8 (`List (List.init 257 ~f:(fun _ -> loc)))));
  assert (Result.is_error (Navigation_wire.locations Utf8 (link ("file:///" ^ String.make 16384 'a') (range 0 0))));
  assert (Result.is_error (Navigation_wire.hover (`Assoc ["contents", `List (List.init 129 ~f:(fun _ -> `String "a"))])));
  assert (Result.is_error (Navigation_wire.hover (`Assoc ["contents", `String (String.make 262145 'a')])));
  let plain = Navigation_wire.hover (`Assoc ["contents", `Assoc ["kind", `String "plaintext"; "value", `String "a\nb"]])
    |> Result.ok_or_failwith |> Option.value_exn in
  assert (equal_content (List.hd_exn plain.contents) {kind = Plaintext; value = "a\nb"});
  [%expect {| |}]; return ()

let%expect_test "late replies obey exact cancellation, edit, supersession, close and restart" =
  let%bind () = Deferred.List.iter ["cancel"; "edit"; "supersede"; "close"; "restart"] ~how:`Sequential ~f:(fun scenario ->
    H.with_root (fun root ->
      let%bind source, resource = start root ["-navigation"; "ocaml"; "-hold-query"] in
      Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
      let q = request resource 2 1 Hover in
      Source.send source (Query q);
      (match scenario with
       | "cancel" -> Source.send source (Cancel_query q.token)
       | "edit" -> Source.send source (Document_changed {resource; revision = 3; text = "😀\n😀fox"})
       | "supersede" ->
         Source.send source (Query (request resource 2 2 Hover));
         Source.send source (Cancel_query q.token)
       | "close" -> Source.send source (Document_closed {resource});
         Source.send source (Document_opened {resource; generation = 8});
         Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"})
       | "restart" -> Source.send source Restart
       | _ -> assert false);
      Source.send source (Document_saved {resource; revision = 2});
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 150) in
      let got = replies (Source.poll source) in
      if String.equal scenario "supersede" then (
        assert (List.length got = 1); assert ((List.hd_exn got).token.request = 2))
      else assert (List.is_empty got);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "unsupported, unattached, starting and synthetic queries fail promptly" =
  let%bind () = H.with_root (fun root ->
    let%bind () = Deferred.List.iter [ []; ["-navigation"; "disabled"];
      ["-navigation"; "ocaml"; "-encoding"; "unknown"]; ["-navigation"; "ocaml"; "-sync"; "none"] ]
      ~how:`Sequential ~f:(fun args ->
        let%bind source, resource = start root args in
        Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
        Source.send source (Query (request resource 2 1 Hover));
        let%map reply = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 1) (receive source) in
        assert (match reply with `Result {result = Failed _; _} -> true | _ -> false);
        Source.stop source) in
    let resource = Filename.concat root "a.ml" in
    let sources = [Lsp_client.start_workspace ~config_for_path:(fun _ -> None) ~cell_width:H.cell_width ();
      Workspace.start ~create:(fun _ -> None) ();
      Synthetic.start ~root ();
      Lsp_client.start ~config:(H.config ~args:["-delay-init"] ()) ~cell_width:H.cell_width ~root ()] in
    Deferred.List.iter sources ~how:`Sequential ~f:(fun source ->
      Source.send source (Query (request resource 1 1 Definition));
      let%map reply = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 1) (receive source) in
      assert (match reply with `Result {result = Failed _; _} -> true | _ -> false);
      Source.stop source)) in
  [%expect {| |}]; return ()

let%expect_test "pending queries fail on server crash independently of diagnostic events" =
  let%bind () = H.with_root (fun root ->
    let%bind source, resource = start root ["-navigation"; "ocaml"; "-hold-query"] in
    Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
    Source.send source (Query (request resource 2 1 Hover));
    (* Crash another document without invalidating the pending query's snapshot. *)
    let other = Filename.concat root "crash.ml" in
    Source.send source (Document_opened {resource = other; generation = 8});
    Source.send source (Document_changed {resource = other; revision = 1; text = "CRASH"});
    let%bind reply = receive source in
    assert (match reply.result with Failed message -> String.is_substring message ~substring:"stopped" | _ -> false);
    Source.send source (Query (request resource 2 2 Hover));
    let%map reply = receive source in
    assert (match reply.result with Failed _ -> true | _ -> false);
    Source.stop source) in
  [%expect {| |}]; return ()

let%expect_test "32 connection queries are bounded and timeout reports failure" =
  let%bind () = H.with_root (fun root ->
    let%bind source, _ = start root ["-navigation"; "ocaml"; "-hold-query"] in
    List.iter (List.range 0 33) ~f:(fun n ->
      let resource = Filename.concat root (sprintf "q%d.ml" n) in
      Source.send source (Document_opened {resource; generation = 7});
      Source.send source (Document_changed {resource; revision = 2; text = "😀\n😀fo"});
      Source.send source (Query (request resource 2 n Hover)));
    let%bind reply = receive source in
    assert (reply.token.request = 32);
    assert (match reply.result with Failed message -> String.is_substring message ~substring:"Too many" | _ -> false);
    (* Keep one timer alive to check timeout reporting; exact cancellation frees all others. *)
    List.iter (List.range 1 32) ~f:(fun n ->
      let resource = Filename.concat root (sprintf "q%d.ml" n) in
      Source.send source (Cancel_query (request resource 2 n Hover).token));
    let%bind reply = receive source in
    assert (reply.token.request = 0);
    assert (match reply.result with Failed message -> String.is_substring message ~substring:"timed out" | _ -> false);
    let resource = Filename.concat root "q32.ml" in
    Source.send source (Query (request resource 2 33 Hover));
    Source.send source (Document_saved {resource = reply.token.resource; revision = 2});
    let%map reply = receive source in
    (* Freed capacity accepts another request. Releasing the fake's entire backlog
       cannot resurrect callbacks for the 31 cancelled queries or the timeout. *)
    assert (reply.token.request = 33);
    assert (match reply.result with Hover_result (Some _) -> true | _ -> false);
    assert (List.is_empty (replies (Source.poll source)));
    Source.stop source) in
  [%expect {| |}]; return ()

let%expect_test "query results do not coalesce with diagnostics or other query results" =
  let reply : reply = {token = (request "a.ml" 1 1 Hover).token; cursor = 11;
    kind = Hover; source = "fake"; result = Hover_result None} in
  let result = Ches_error.Source_event.Query_result reply in
  let diagnostic = Ches_error.Source_event.Diagnostics {source = "fake"; resource = "a.ml";
    revision = Some 1; findings = []} in
  let queue = List.fold [result; diagnostic; result; diagnostic] ~init:Event_queue.empty ~f:Event_queue.push in
  let _, events = Event_queue.take queue ~max:10 in
  assert (List.length (replies events) = 2 && List.length events = 3);
  [%expect {| |}]; return ()
