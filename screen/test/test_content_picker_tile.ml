open! Core
open Ches_screen
open Ches_content_picker
let snapshot status : Model.snapshot =
  let candidate = Model.Candidate.create ~root:"/root\n" ~relative_path:"odd\n\255" |> Or_error.ok_exn in
  { request = { run_id = Model.Run_id.of_int 1; root = "/root\n"; query = "needle" }
  ; status
  ; hits = List.init 5 ~f:(fun i ->
      { Model.candidate; line = i + 1; start_byte = 4; end_byte = 10; text = "界\tneedle\255\n" }) }
;;
let row_text row = String.concat (List.map row ~f:(fun (span : Span.t) -> span.text))
let%expect_test "on-disk literal label safe paths byte columns highlight status errors and truncation" =
  List.iter
    [ Model.Status.Loading, "Searching on disk..."
    ; Partial, "Searching on disk (partial)"
    ; Complete { truncated = false }, "On-disk literal search complete"
    ; Complete { truncated = true }, "TRUNCATED"
    ; Failed "denied\n\027\000", "Search failed: denied\\x0A\\x1B\\x00"
    ; Cancelled, "Search cancelled" ] ~f:(fun (status, expected) ->
      let t = Content_picker_tile.create ~token:() ~snapshot:(snapshot status) in
      let c = Content_picker_tile.render t ~width:120 ~rows:4 in
      assert (String.is_substring c.title ~substring:"ON DISK (excludes unsaved edits)");
      assert (String.is_suffix c.title ~suffix:"/root\\x0A");
      assert (String.is_prefix (row_text (List.nth_exn c.body 1)) ~prefix:expected);
      assert (String.is_substring (Option.value_exn c.footer).text ~substring:"BYTES, not cells");
      assert (String.is_substring (Option.value_exn c.footer).text ~substring:expected);
      assert (not (String.is_substring (Option.value_exn c.footer).text ~substring:"Tab/Shift-Tab"));
      let row = List.nth_exn c.body 2 in
      assert (String.is_prefix (row_text row) ~prefix:"> odd\\x0A\\xFF:1:5 | 界\\x09needle\\xFF");
      assert (List.exists row ~f:(fun s -> String.equal s.Span.text "needle" && Style.equal s.style Pending)));
  [%expect {| |}]
;;
let%expect_test "tile scrolling bounded sizes query editing stale request and fake acceptance" =
  let s = snapshot (Complete { truncated = false }) in
  let t = Content_picker_tile.create ~token:42 ~snapshot:s in
  Content_picker_tile.update t ~rows:4 Next;
  Content_picker_tile.update t ~rows:4 Next;
  assert ((Content_picker_tile.view t).top = 1);
  let c = Content_picker_tile.render t ~width:60 ~rows:4 in
  assert (String.is_prefix (row_text (List.nth_exn c.body 3)) ~prefix:"> odd\\x0A\\xFF:3:5");
  Content_picker_tile.update t ~rows:4 (Paste "\r\n界\027");
  assert (String.equal (Model.query (Content_picker_tile.session t)) "needle 界");
  assert (not (Content_picker_tile.install t s));
  let calls = ref 0 and releases = ref 0 in
  let release () = incr releases in
  let consume (intent : int Model.intent) =
    assert (!releases = 1 && intent.token = 42 && intent.line = 3 && intent.byte_column = 4);
    assert (String.equal intent.path "/root\n/odd\n\255");
    incr calls in
  Content_picker_tile.accept t ~release ~consume;
  assert (!calls = 0 && !releases = 0);
  Content_picker_tile.update t ~rows:4 Delete_word;
  Content_picker_tile.update t ~rows:4 Backspace;
  assert (String.equal (Model.query (Content_picker_tile.session t)) "needle");
  List.iter [ -1; 0; 1; 2; 4; 30 ] ~f:(fun width ->
    List.iter [ -1; 0; 1; 2; 3; 4; 8 ] ~f:(fun rows ->
      let c = Content_picker_tile.render t ~width ~rows in
      assert (List.length c.body <= Int.max 0 rows);
      List.iter c.body ~f:(fun row -> assert (Span.total_width row = Int.max 0 width));
      let cursor = Content_picker_tile.cursor t ~width in
      if width > 0 then assert (cursor.column >= 0 && cursor.column < width)));
  Content_picker_tile.accept t ~release ~consume;
  Content_picker_tile.accept t ~release ~consume;
  assert (!calls = 1 && !releases = 1);
  assert (match Content_picker_tile.interpret [ Ches_input.Key.Enter ] with Action Accept -> true | _ -> false);
  assert (match Content_picker_tile.interpret [ Ches_input.Key.Escape ] with Unbound -> true | _ -> false);
  let empty = { s with hits = []; request = { s.request with query = "" } } in
  let t = Content_picker_tile.create ~token:() ~snapshot:empty in
  let c = Content_picker_tile.render t ~width:100 ~rows:3 in
  assert (String.is_prefix (row_text (List.nth_exn c.body 1)) ~prefix:"Type a literal; empty query does not search");
  Content_picker_tile.accept t ~release:(fun () -> assert false) ~consume:(fun _ -> assert false);
  Content_picker_tile.cancel t ~release:(fun () -> ());
  Content_picker_tile.accept t ~release:(fun () -> assert false) ~consume:(fun _ -> assert false);
  let t = Content_picker_tile.create ~token:() ~snapshot:empty in
  Content_picker_tile.update t ~rows:3 (Paste (String.make 5000 'a'));
  let c = Content_picker_tile.render t ~width:100 ~rows:3 in
  assert (String.is_prefix (row_text (List.nth_exn c.body 1)) ~prefix:"QUERY TRUNCATED at 4 KiB");
  [%expect {| |}]
;;
