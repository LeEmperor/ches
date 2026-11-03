open! Core
open! Async
open Ches_source
open Ches_error.Language_query
module H = Test_completion.H
module N = Test_navigation

let help ?(automatic = true) ?character ?(retrigger = false) () =
  Signature_help { automatic; character; retrigger }

let%expect_test "signature metadata uses exact UTF16 label offsets, stable slots and overload defaults" =
  let decode s = Signature_wire.decode (Yojson.Safe.from_string s) |> Result.ok_or_failwith in
  assert (equal_result (decode "null") (Signature_result None));
  assert (equal_result (decode {|{"signatures":[]}|}) (Signature_result None));
  let result = decode {|{"signatures":[
    {"label":"f 😀 é x x", "documentation":{"kind":"markdown","value":"**f**"},
     "activeParameter":2,"parameters":[
       {"label":[2,4],"documentation":"emoji"}, {"label":[3,4]},
       {"label":"é"}, {"label":"x"}, {"label":[99,100]}]},
    {"label":"g y", "parameters":[{"label":"y"}]}],
    "activeSignature":99,"activeParameter":1}|} in
  (match result with
   | Signature_result (Some h) ->
     assert (h.active_signature = 0 && Option.equal Int.equal h.active_parameter (Some 1));
     let s = List.hd_exn h.signatures in
     assert (Option.equal Int.equal s.active_parameter (Some 2));
     assert ([%equal: (int * int) list]
       (List.map s.parameters ~f:(fun p -> p.label_start, p.label_stop))
       [2,6; -1,-1; 7,9; -1,-1; -1,-1]);
     assert (equal_content (List.hd_exn s.documentation) {kind=Markdown;value="**f**"});
     assert (equal_content (List.hd_exn (List.hd_exn s.parameters).documentation)
       {kind=Plaintext;value="emoji"})
   | _ -> assert false);
  (match decode {|{"signatures":[{"label":"a","parameters":[{"label":"a"}],"activeParameter":99}],"activeParameter":-1}|} with
   | Signature_result (Some h) -> assert (Option.equal Int.equal h.active_parameter (Some 0));
     assert (Option.equal Int.equal (List.hd_exn h.signatures).active_parameter (Some 0))
   | _ -> assert false);
  (match decode {|{"signatures":[{"label":"a"}]}|} with
   | Signature_result (Some h) -> assert (Option.is_none h.active_parameter)
   | _ -> assert false);
  List.iter ["{}"; {|{"signatures":false}|}; {|{"signatures":[{"label":null}]}|};
    {|{"signatures":[{"label":"a","documentation":false}]}|}]
    ~f:(fun s -> assert (Result.is_error (Signature_wire.decode (Yojson.Safe.from_string s))));
  assert (Result.is_error (Signature_wire.decode (`Assoc ["signatures", `List
    (List.init 65 ~f:(fun _ -> `Assoc ["label", `String "a"]))])));
  assert (Result.is_error (Signature_wire.decode (`Assoc ["signatures", `List
    [`Assoc ["label", `String (String.make 65537 'a')]]])));
  assert (Result.is_error (Signature_wire.decode (`Assoc ["signatures", `List
    [`Assoc ["label", `String "bad\xff"]]])));
  assert (Result.is_error (Signature_wire.decode (`Assoc ["signatures", `List
    [`Assoc ["label", `String "a"; "parameters", `List (List.init 257 ~f:(fun _ -> `Assoc ["label", `String "a"]))]]])));
  assert (Result.is_error (Signature_wire.decode (`Assoc ["signatures", `List
    (List.init 5 ~f:(fun _ -> `Assoc ["label", `String (String.make 65536 'a')]))])));
  [%expect {| |}]; return ()

let%expect_test "companion URI decoder is bounded lexical and does no existence I/O" =
  let decode xs = Signature_wire.companions (`List (List.map xs ~f:(fun s -> `String s))) in
  assert (equal_result (Result.ok_or_failwith (decode [])) (Companions []));
  assert (equal_result (Result.ok_or_failwith (decode ["file:///missing/a.mli"]))
    (Companions ["/missing/a.mli"]));
  assert (equal_result (Result.ok_or_failwith (decode ["file:///missing/a/../b%20%23.mli";
    "file://localhost/missing/c.ml"; "file:///missing/c.ml"]))
    (Companions ["/missing/b #.mli"; "/missing/c.ml"]));
  List.iter ["https://example/a"; "relative.mli"; "file://remote/a";
    "file:///bad%"; "file:///bad%00"; "file:///bad%FF"; "file:///a#b"; "file:///a b";
    "file:///a\nb"; "file:///a\\b"]
    ~f:(fun uri -> assert (Result.is_error (decode [uri])));
  assert (Result.is_error (Signature_wire.companions (`List (List.init 257 ~f:(fun _ -> `String "file:///a")))));
  List.iter ["{}"; {|{"experimental":{"handleSwitchImplIntf":false}}|};
    {|{"experimental":{"handleSwitchImplIntf":"true"}}|};
    {|{"experimental":{"ocamllsp":{"handleSwitchImplIntf":false}}}|}]
    ~f:(fun s -> assert (not (Signature_wire.companion_capability (Yojson.Safe.from_string s))));
  List.iter [{|{"experimental":{"handleSwitchImplIntf":true}}|};
    {|{"experimental":{"ocamllsp":{"handleSwitchImplIntf":true}}}|}]
    ~f:(fun s -> assert (Signature_wire.companion_capability (Yojson.Safe.from_string s)));
  [%expect {| |}]; return ()

let%expect_test "automatic filtering, whitespace triggers, manual and active update contexts on wire" =
  let%bind () = Deferred.List.iter ["utf-8"; "utf-16"; "utf-32"] ~how:`Sequential ~f:(fun encoding ->
    H.with_root (fun root ->
      let log = Filename.concat root "payload.jsonl" in
      let%bind source, resource = N.start root ["-signatures"; "-companions";
        "-encoding"; encoding; "-query-payload-log"; log] in
      Source.send source (H.changed root 2 "😀\n😀fox");
      let ask id kind =
        Source.send source (Query {token={resource;generation=7;revision=2;request=id};cursor=12;kind});
        N.receive source >>| fun r -> r.result in
      let%bind silent = ask 1 (help ~character:"x" ()) in
      assert (equal_result silent (Signature_result None));
      let%bind silent = ask 2 (help ()) in
      assert (equal_result silent (Signature_result None));
      let%bind () = Deferred.List.iteri [" "; "~"; "?"; ":"; "("] ~how:`Sequential ~f:(fun i c ->
        let%map r = ask (3+i) (help ~character:c ()) in
        assert (match r with Signature_result (Some _) -> true | _ -> false)) in
      let%bind _ = ask 8 (help ~retrigger:true ()) in
      let%bind _ = ask 9 (help ~character:"x" ~retrigger:true ()) in
      let%bind _ = ask 10 (help ~character:"," ~retrigger:true ()) in
      let%bind _ = ask 11 (help ~automatic:false ~character:"x" ()) in
      let%bind r = ask 12 Companion_files in
      assert (equal_result r (Companions [resource; "/missing/companion #.mli"]));
      let%bind lines = Reader.file_lines log in
      let packets = List.map lines ~f:Yojson.Safe.from_string in
      let method_is p s = Option.equal String.equal (Completion_wire.string_field p "method") (Some s) in
      let sigs = List.filter packets ~f:(fun p -> method_is p "textDocument/signatureHelp") in
      assert (List.length sigs = 9);
      let contexts = List.map sigs ~f:(fun p -> Completion_wire.field p "params" |> Option.value_exn
        |> fun p -> Completion_wire.field p "context" |> Option.value_exn) in
      let get i = List.nth_exn contexts i in
      List.iteri [" "; "~"; "?"; ":"; "("] ~f:(fun i c ->
        assert (Poly.equal (get i) (`Assoc ["triggerKind", `Int 2; "isRetrigger", `Bool false; "triggerCharacter", `String c])));
      List.iter [5;6] ~f:(fun i -> assert (Poly.equal (get i)
        (`Assoc ["triggerKind", `Int 3; "isRetrigger", `Bool true])));
      assert (Poly.equal (get 7) (`Assoc ["triggerKind", `Int 2; "isRetrigger", `Bool true; "triggerCharacter", `String ","]));
      assert (Poly.equal (get 8) (`Assoc ["triggerKind", `Int 1; "isRetrigger", `Bool false]));
      let index s = List.findi_exn packets ~f:(fun _ p -> method_is p s) |> fst in
      assert (index "textDocument/didChange" < index "textDocument/signatureHelp");
      let companion = List.find_exn packets ~f:(fun p -> method_is p "ocamllsp/switchImplIntf") in
      assert (Poly.equal (Completion_wire.field companion "params")
        (Some (`List [`String (Lsp.Uri.to_string (Lsp.Uri.of_path resource))])));
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "unsupported providers never receive signature or companion RPC" =
  H.with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let%bind source, resource = N.start root ["-log"; log] in
    let ask id kind = Source.send source (Query (N.request resource 1 id kind)); N.receive source in
    let%bind r = ask 1 (help ~character:" " ()) in
    assert (equal_result r.result (Signature_result None));
    let%bind r = ask 2 (help ~automatic:false ()) in
    assert (match r.result with Failed _ -> true | _ -> false);
    let%bind r = ask 3 Companion_files in
    assert (match r.result with Failed _ -> true | _ -> false);
    let%bind lines = Reader.file_lines log in
    assert (not (List.exists lines ~f:(fun s -> String.is_suffix s ~suffix:"textDocument/signatureHelp"
      || String.is_suffix s ~suffix:"ocamllsp/switchImplIntf")));
    Source.stop source; [%expect {| |}]; return ())

let%expect_test "held signatures have exact cancellation and preserve concurrent completion" =
  let%bind () = Deferred.List.iter ["supersede"; "cancel"; "edit"; "close"] ~how:`Sequential ~f:(fun scenario ->
    H.with_root (fun root ->
      let%bind source, resource = N.start root ["-signatures"; "-hold-query"; "-hold-completion"] in
      let q = N.request resource 1 1 (help ~automatic:false ()) in
      Source.send source (Query q);
      Source.send source (Complete (Test_completion.request resource 7 1 40));
      let expected = match scenario with
        | "supersede" ->
          Source.send source (Query {q with token={q.token with request=2}});
          Source.send source (Cancel_query q.token); true
        | "cancel" -> Source.send source (Cancel_query q.token); false
        | "edit" -> Source.send source (H.changed root 2 "😀\n😀fox"); false
        | "close" -> Source.send source (Document_closed {resource}); false
        | _ -> assert false in
      Source.send source (Document_saved {resource;revision=1});
      let%bind () = Test_completion.pause () in
      let events = Test_completion.drain source in
      let replies = N.replies events in
      assert (List.length replies = Bool.to_int expected);
      if expected then assert ((List.hd_exn replies).token.request = 2);
      if String.equal scenario "supersede" || String.equal scenario "cancel" then
        assert (List.length (Test_completion.replies events) = 1);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "signature server failures and malformed replies clear automatic help but explain manual failures" =
  let%bind () = Deferred.List.iter ["signature-error"; "signature-malformed"] ~how:`Sequential ~f:(fun mode ->
    H.with_root (fun root ->
      let%bind source, resource = N.start root ["-signatures"; "-navigation-result"; mode] in
      let ask id kind = Source.send source (Query (N.request resource 1 id kind)); N.receive source in
      let%bind automatic = ask 1 (help ~character:" " ()) in
      assert (equal_result automatic.result (Signature_result None));
      let%bind manual = ask 2 (help ~automatic:false ()) in
      assert (match manual.result with Failed _ -> true | _ -> false);
      Source.stop source; return ())) in
  [%expect {| |}]; return ()

let%expect_test "a saturated completion lane still admits signature queries without cancelling completion" =
  H.with_root (fun root ->
    let%bind source, resource = N.start root ["-signatures"; "-hold-completion"] in
    let resources = List.init 32 ~f:(fun i -> Filename.concat root (sprintf "held%d.ml" i)) in
    List.iteri resources ~f:(fun i resource ->
      Source.send source (Document_opened {resource; generation = 7});
      Source.send source (Document_changed {resource; revision = 1; text = "😀\n😀fo"});
      Source.send source (Complete (Test_completion.request resource 7 1 (100 + i))));
    Source.send source (Query (N.request resource 1 1 (help ~automatic:false ())));
    let%bind reply = N.receive source in
    assert (match reply.result with Signature_result (Some _) -> true | _ -> false);
    Source.send source (Document_saved {resource; revision = 1});
    let%bind () = Test_completion.pause () in
    assert (List.length (Test_completion.replies (Test_completion.drain source)) = 32);
    Source.stop source; [%expect {| |}]; return ())

let%expect_test "signature deadline cancels pending RPC and silently clears automatic help" =
  H.with_root (fun root ->
    let%bind source, resource = N.start root ["-signatures"; "-hold-query"] in
    Source.send source (Query (N.request resource 1 1 (help ~character:" " ())));
    let%bind reply = N.receive source in
    assert (equal_result reply.result (Signature_result None));
    Source.send source (Document_saved {resource;revision=1});
    let%bind () = Test_completion.pause () in
    assert (List.is_empty (N.replies (Test_completion.drain source)));
    Source.stop source; [%expect {| |}]; return ())
