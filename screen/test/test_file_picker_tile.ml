open! Core
open Ches_screen
open Ches_file_picker

let snapshot status paths : Model.Discovery.t =
  { request = { run_id = Model.Run_id.of_int 1; root = "/project\nroot" }
  ; candidates = List.map paths ~f:(fun relative_path ->
      Model.Candidate.create ~root:"/project\nroot" ~relative_path |> Or_error.ok_exn)
  ; status }
;;

let drain t =
  while Interaction.busy (File_picker_tile.session t) do File_picker_tile.work t ~budget:2 done
;;

let row_text row = String.concat (List.map row ~f:(fun (s : Span.t) -> s.text))

let%expect_test "file tile exposes root, status, partial results, errors, limits, empty and no-match" =
  List.iter
    [ Model.Discovery.Loading, [], "Loading files..."
    ; Partial, [ "a.ml" ], "Discovering files (partial)"
    ; Complete { truncated = false }, [], "Discovery complete"
    ; Complete { truncated = true }, [ "a.ml" ], "TRUNCATED: discovery limit reached; not all files shown"
    ; Complete { truncated = true }, [], "TRUNCATED: discovery limit reached; not all files shown"
    ; Failed "bad\n\027\000stderr", [ "a.ml" ], "Discovery failed: bad\\x0A\\x1B\\x00stderr"
    ; Cancelled, [], "Discovery cancelled"
    ] ~f:(fun (status, paths, expected) ->
      let t = File_picker_tile.create ~token:() ~discovery:(snapshot status paths) in
      drain t;
      let content = File_picker_tile.render t ~width:180 ~rows:4 in
      assert (String.equal content.title "Files | /project\\x0Aroot");
      assert (String.is_prefix (row_text (List.nth_exn content.body 1)) ~prefix:expected);
      assert (String.is_substring (Option.value_exn content.footer).text ~substring:expected);
      assert (not (String.is_substring (Option.value_exn content.footer).text ~substring:"Tab/Shift-Tab"));
      assert (not (String.is_substring (Option.value_exn content.footer).text ~substring:"Enter, Esc"));
      (match status with
       | Complete { truncated = false } ->
         assert (String.is_prefix (row_text (List.nth_exn content.body 2)) ~prefix:"No project files")
       | _ -> ());
      File_picker_tile.update t ~rows:4 (Paste "zzzz");
      drain t;
      let content = File_picker_tile.render t ~width:180 ~rows:4 in
      assert (List.is_empty (Model.results (Interaction.model (File_picker_tile.session t))));
      assert (String.is_substring (Option.value_exn content.footer).text ~substring:"0/0 matches"));
  [%expect {| |}]
;;

let%expect_test "relative paths, matched styles, safe escapes, scrolling and small dimensions" =
  let t = File_picker_tile.create ~token:() ~discovery:(snapshot Partial
    [ "a/model.ml"; "b/model.ml"; "c/model.ml"; "界/模型.ml"; "odd/line\nfile.ml" ]) in
  drain t;
  File_picker_tile.update t ~rows:4 (Paste "model");
  drain t;
  let content = File_picker_tile.render t ~width:30 ~rows:4 in
  let row = List.nth_exn content.body 2 in
  assert (String.is_prefix (row_text row) ~prefix:"> a/model.ml");
  assert (List.exists row ~f:(fun s -> Style.equal s.style Pending && String.equal s.text "model"));
  File_picker_tile.update t ~rows:4 Next;
  File_picker_tile.update t ~rows:4 Next;
  assert ((File_picker_tile.view t).top = 1);
  let content = File_picker_tile.render t ~width:30 ~rows:4 in
  assert (String.is_prefix (row_text (List.nth_exn content.body 3)) ~prefix:"> c/model.ml");
  File_picker_tile.update t ~rows:4 Delete_word;
  File_picker_tile.update t ~rows:4 (Paste "模型");
  drain t;
  let content = File_picker_tile.render t ~width:30 ~rows:4 in
  assert (String.is_prefix (row_text (List.nth_exn content.body 2)) ~prefix:"> 界/模型.ml");
  File_picker_tile.update t ~rows:4 Delete_word;
  File_picker_tile.update t ~rows:4 (Paste "line");
  drain t;
  let content = File_picker_tile.render t ~width:40 ~rows:4 in
  assert (String.is_substring (row_text (List.nth_exn content.body 2)) ~substring:"line\\x0Afile.ml");
  File_picker_tile.update t ~rows:4 (Paste " a very long 界 query");
  List.iter [ -1; 0; 1; 2; 3; 4; 10; 30 ] ~f:(fun width ->
    List.iter [ -1; 0; 1; 2; 3; 4; 8 ] ~f:(fun rows ->
      let content = File_picker_tile.render t ~width ~rows in
      assert (List.length content.body <= Int.max 0 rows);
      List.iter content.body ~f:(fun row -> assert (Span.total_width row = Int.max 0 width));
      let cursor = File_picker_tile.cursor t ~width in
      if width > 0 then assert (cursor.row = 0 && cursor.column >= 0 && cursor.column < width)));
  [%expect {| |}]
;;

let%expect_test "headless tile input and fake acceptance consumer, no live dispatch" =
  let t = File_picker_tile.create ~token:99 ~discovery:(snapshot Partial [ "a.ml" ]) in
  drain t;
  List.iter [ Ches_input.Key.char 'j'; Ches_input.Key.char ' '; Ches_input.Key.Backspace
            ; Ches_input.Key.Ctrl 'w'; Ches_input.Key.Ctrl 'h'; Ches_input.Key.Ctrl 'n'; Ches_input.Key.Ctrl 'p' ]
    ~f:(fun key -> match File_picker_tile.interpret [ key ] with
      | Action (Event _) -> () | _ -> assert false);
  assert (match File_picker_tile.interpret [ Enter ] with Action Accept -> true | _ -> false);
  assert (match File_picker_tile.interpret [ Escape ] with Unbound -> true | _ -> false);
  let released = ref false in
  let calls = ref 0 in
  let release () = released := true in
  let consume (request : int Model.Request.t) =
    assert (!released && request.token = 99 && String.equal request.path "/project\nroot/a.ml");
    incr calls
  in
  File_picker_tile.accept t ~release ~consume;
  File_picker_tile.accept t ~release ~consume;
  assert (!calls = 1);
  let t = File_picker_tile.create ~token:99 ~discovery:(snapshot Loading []) in
  File_picker_tile.cancel t ~release;
  File_picker_tile.accept t ~release ~consume;
  assert (!calls = 1);
  [%expect {| |}]
;;
