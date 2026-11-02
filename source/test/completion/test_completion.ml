open! Core
open! Async
open Ches_source
module Model = Ches_completion.Model
module Event = Ches_error.Source_event

module H = struct
  let cell_width _ = 1
  let config ~args () =
    { Lsp_client.Config.ocamllsp with source = "fake"; args;
      prog = Filename.concat (Core_unix.getcwd ()) "../fake_lsp/fake_lsp.exe" }
  let with_root f =
    let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-completion" "") in
    Monitor.protect (fun () -> f root)
      ~finally:(fun () -> Process.run ~prog:"rm" ~args:["-rf"; root] () >>| ignore)
  let changed root revision text : Ches_error.Source_request.t =
    Document_changed { resource = Filename.concat root "a.ml"; revision; text }
  let rec is_diagnostics ~revision = function
    | Event.Diagnostics d -> Option.equal Int.equal d.revision (Some revision)
    | Owned { event; _ } -> is_diagnostics ~revision event
    | _ -> false
  let rec until ~quiet:_ source ~root:_ ~f =
    match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (Source.next_batch source) with
    | `Timeout -> failwith "diagnostic timeout"
    | `Result events ->
      if List.exists events ~f then return () else until ~quiet:true source ~root:"" ~f
end

let request resource generation revision request : Model.Request.t =
  { token = { resource; generation; revision; request }
  ; cursor = 11; fallback_start = 9; fallback_stop = 11; trigger = Automatic }
;;

let rec replies events =
  List.concat_map events ~f:(function
    | Event.Completion reply -> [reply]
    | Owned { event; _ } -> replies [event]
    | _ -> [])
;;

let pause () = Clock_ns.after (Time_ns.Span.of_int_ms 100)

let rec drain source =
  match Source.poll source with [] -> [] | events -> events @ drain source
;;

let%expect_test "exact wire boundaries round-trip UTF8/16/32 and CRLF" =
  let text = "a😀é\r\nz\rx\n" in
  List.iter [Completion_wire.Utf8; Utf16; Utf32] ~f:(fun encoding ->
    List.iter [0; 1; 5; 7; 9; 10; 11; 12; 13] ~f:(fun byte ->
      let p = Completion_wire.position encoding text byte |> Option.value_exn in
      assert (Option.equal Int.equal (Completion_wire.offset encoding text p) (Some byte)));
    List.iter [2; 3; 4; 6; 8; -1; 14] ~f:(fun byte ->
      assert (Option.is_none (Completion_wire.position encoding text byte)));
    assert (Option.is_none (Completion_wire.offset encoding text
      (Lsp.Types.Position.create ~line:0 ~character:99))));
  assert (Option.is_none (Completion_wire.offset Utf16 text
    (Lsp.Types.Position.create ~line:0 ~character:2)));
  assert (Option.is_none (Completion_wire.offset Utf8 text
    (Lsp.Types.Position.create ~line:0 ~character:2)));
  assert (Option.is_none (Completion_wire.position Utf16 "bad\xff" 0));
  [%expect {| |}];
  return ()
;;

let%expect_test "fake completion flushes didChange first, normalizes edits, rejects unsupported items" =
  let%bind () = Deferred.List.iter ["utf-8"; "utf-16"; "utf-32"] ~how:`Sequential ~f:(fun encoding ->
    H.with_root (fun root ->
      let log = Filename.concat root "wire.log" in
      let source = Lsp_client.start ~config:(H.config ~args:["-encoding"; encoding; "-log"; log] ())
        ~cell_width:H.cell_width ~root () in
      let resource = Filename.concat root "a.ml" in
      Source.send source (Document_opened { resource; generation = 7 });
      Source.send source (H.changed root 1 "😀\n😀f");
      let%bind () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
      Source.send source (H.changed root 2 "😀\n😀fo");
      let trigger = match encoding with "utf-8" -> Model.Request.Automatic
        | "utf-16" -> Character "." | _ -> Incomplete in
      let query = { (request resource 7 2 10) with trigger } in
      Source.send source (Complete query);
      let rec receive () =
        match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (Source.next_batch source) with
        | `Timeout -> failwith "completion timeout"
        | `Result events -> match replies events with [] -> receive () | reply :: _ -> return reply in
      let%bind reply = receive () in
      assert (Model.Token.equal reply.token query.token && reply.incomplete);
      assert (List.length reply.candidates = 2);
      let candidate = List.hd_exn reply.candidates in
      let kind = match encoding with "utf-8" -> "1" | "utf-16" -> "2" | _ -> "3" in
      assert (Option.equal String.equal candidate.detail (Some kind));
      assert (String.equal candidate.label "😀\n😀fo");
      assert (Ches_core.Text_edit.equal candidate.primary { start = 5; stop = 11; text = "format" });
      assert ([%equal: Ches_core.Text_edit.t list] candidate.additional [{ start = 0; stop = 4; text = "import\n" }]);
      let fallback = List.nth_exn reply.candidates 1 in
      assert (Ches_core.Text_edit.equal fallback.primary { start = 9; stop = 11; text = "fallback_text" });
      let%bind lines = Reader.file_lines log in
      let methods = List.map lines ~f:(fun line -> List.last_exn (String.split line ~on:' ')) in
      let index name = List.findi_exn methods ~f:(fun _ m -> String.equal m name) |> fst in
      assert (index "textDocument/didChange" < index "textDocument/completion");
      Source.stop source;
      return ())) in
  [%expect {| |}];
  return ()
;;

let%expect_test "late replies cannot cross cancellation, revision, request identity or document lifetime" =
  let%bind () = Deferred.List.iter ["cancel"; "revision"; "request"; "lifetime"] ~how:`Sequential ~f:(fun scenario ->
    H.with_root (fun root ->
      let log = Filename.concat root "wire.log" in
      let source = Lsp_client.start
        ~config:(H.config ~args:["-hold-completion"; "-log"; log] ()) ~cell_width:H.cell_width ~root () in
      let resource = Filename.concat root "a.ml" in
      Source.send source (Document_opened { resource; generation = 7 });
      Source.send source (H.changed root 1 "😀\n😀fo");
      let%bind () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
      let query = request resource 7 1 1 in
      Source.send source (Complete query);
      let expected = match scenario with
        | "cancel" -> Source.send source (Cancel_completion query.token); None
        | "revision" -> Source.send source (H.changed root 2 "😀\n😀fox"); None
        | "request" ->
          let next = request resource 7 1 2 in
          Source.send source (Complete next);
          (* An obsolete cancel must not cancel the new request. *)
          Source.send source (Cancel_completion query.token);
          Source.send source (Complete (request resource 6 1 3));
          Source.send source (Complete (request resource 7 0 4));
          Some next.token
        | "lifetime" ->
          Source.send source (Document_closed { resource });
          Source.send source (Document_opened { resource; generation = 8 });
          Source.send source (H.changed root 1 "😀\n😀fo"); None
        | _ -> assert false in
      (* The fake deliberately ignores cancellation and releases all held replies. *)
      Source.send source (Document_saved { resource; revision = 1 });
      let%bind () = pause () in
      let got = replies (Source.poll source) in
      (match expected with
       | None -> assert (List.is_empty got)
       | Some token -> assert (List.length got = 1 && Model.Token.equal (List.hd_exn got).token token));
      let%bind lines = Reader.file_lines log in
      assert (List.exists lines ~f:(String.is_suffix ~suffix:"textDocument/completion"));
      assert (List.exists lines ~f:(String.is_suffix ~suffix:"$/cancelRequest"));
      Source.stop source;
      return ())) in
  [%expect {| |}];
  return ()
;;

let%expect_test "completion events do not coalesce with diagnostics or each other" =
  let reply : Model.Reply.t = { token = (request "a.ml" 1 1 1).token;
    source = "fake"; candidates = []; incomplete = false } in
  let diagnostic = Event.Diagnostics { source = "fake"; resource = "a.ml"; revision = Some 1; findings = [] } in
  let queue = List.fold [diagnostic; Event.Completion reply; diagnostic; Event.Completion reply]
    ~init:Event_queue.empty ~f:Event_queue.push in
  assert (Event_queue.length queue = 3 && Event_queue.dropped queue = 1);
  let _, events = Event_queue.take queue ~max:64 in
  assert (List.length (replies events) = 2);
  [%expect {| |}];
  return ()
;;

let%expect_test "array and null responses use plain-text fallback semantics" =
  let query = request "a.ml" 7 1 1 in
  let normalize = Completion_wire.candidates ~encoding:Utf16 ~text:"😀\n😀fo"
    ~request:query ~source:"fake" in
  let reply = normalize (`List
    [ `Assoc ["label", `String "label"; "textEdit", `Null; "insertText", `String "inserted"]
    ; `Assoc ["label", `String "label-only"] ]) in
  assert (not reply.incomplete && List.length reply.candidates = 2);
  assert (String.equal (List.nth_exn reply.candidates 0).primary.text "inserted");
  assert (String.equal (List.nth_exn reply.candidates 1).primary.text "label-only");
  assert (List.is_empty (normalize `Null).candidates);
  [%expect {| |}];
  return ()
;;

let%expect_test "capability and encoding guards suppress unsupported completion RPCs" =
  let%bind () = Deferred.List.iter
    [["-no-completion"]; ["-encoding"; "unknown"]; ["-sync"; "none"]]
    ~how:`Sequential ~f:(fun args -> H.with_root (fun root ->
      let log = Filename.concat root "wire.log" in
      let source = Lsp_client.start ~config:(H.config ~args:(args @ ["-log"; log]) ())
        ~cell_width:H.cell_width ~root () in
      let resource = Filename.concat root "a.ml" in
      Source.send source (Document_opened { resource; generation = 7 });
      Source.send source (H.changed root 1 "😀\n😀fo");
      let%bind () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
      Source.send source (H.changed root 2 "😀\n😀fo");
      Source.send source (Complete (request resource 7 2 1));
      let%bind () = pause () in
      assert (List.is_empty (replies (Source.poll source)));
      let%bind lines = Reader.file_lines log in
      assert (not (List.exists lines ~f:(String.is_suffix ~suffix:"textDocument/completion")));
      Source.stop source;
      return ())) in
  [%expect {| |}];
  return ()
;;

let%expect_test "pooled completion remains bounded across documents and restart clears in-flight work" =
  H.with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let config = H.config ~args:["-hold-completion"; "-log"; log] () in
    let source = Lsp_client.start_workspace ~config_for_path:(fun _ -> Some config)
      ~cell_width:H.cell_width () in
    let resource n = Filename.concat root (sprintf "a%d.ml" n) in
    Source.send source (Document_opened { resource = resource 0; generation = 7 });
    Source.send source (Document_changed { resource = resource 0; revision = 1; text = "😀\n😀fo" });
    let%bind () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
    List.iter (List.range 0 40) ~f:(fun n ->
      if n > 0 then (
        Source.send source (Document_opened { resource = resource n; generation = 7 });
        Source.send source (Document_changed { resource = resource n; revision = 1; text = "😀\n😀fo" }));
      Source.send source (Complete (request (resource n) 7 1 n)));
    Source.send source (Document_saved { resource = resource 0; revision = 1 });
    let%bind () = pause () in
    let got = replies (drain source) in
    assert (List.length got = 32);
    assert (List.for_all got ~f:(fun reply -> String.equal reply.source "fake#1"));
    let%bind lines = Reader.file_lines log in
    let count method_ = List.count lines ~f:(String.is_suffix ~suffix:(" " ^ method_)) in
    assert (count "spawn" = 1 && count "textDocument/completion" = 40 && count "$/cancelRequest" = 8);
    Source.send source (Complete (request (resource 0) 7 1 99));
    Source.send source Restart;
    let%bind () = H.until ~quiet:true source ~root ~f:(H.is_diagnostics ~revision:1) in
    assert (List.is_empty (replies (Source.poll source)));
    Source.stop source;
    [%expect {| |}];
    return ())
;;
