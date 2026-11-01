open! Core
open Ches_core
open Command

let buffer s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

let create ?indentation s =
  Editor.create ?indentation ~cell_width:Cell_width.f (buffer s)
;;

let run t commands =
  List.fold commands ~init:t ~f:(fun t command ->
    let t, effects = Editor.dispatch t command in
    (* Indentation and navigation must not copy to the clipboard or perform IO. *)
    assert (List.is_empty effects);
    t)
;;

let text t = Text_buffer.to_string (Editor.text t)
let move ?count motion = Move { motion; count }
let right count = Shift_lines { right = true; count }
let left count = Shift_lines { right = false; count }
let visual ?(right = true) count = Visual_shift { right; count }
let insert_shift right = Insert_shift { right }
let assert_text t expected = [%test_result: string] (text t) ~expect:expected
let assert_cursor t expected =
  [%test_result: int] (Editor.cursor t) ~expect:expected;
  assert (Text_buffer.is_boundary (Editor.text t) (Editor.cursor t))
;;

let assert_oldest t =
  let revision = Editor.revision t in
  let undone = run t [ Undo ] in
  [%test_result: int] (Editor.revision undone) ~expect:revision;
  assert ([%equal: Editor.Message.t option] (Editor.message undone)
            (Some (Info "Already at oldest change")))
;;

let%test_unit "Normal count selects lines, clamps at EOF, and is one cleanly undoable edit" =
  let original = "header\n  let café = 1\n\tprint café\nfooter\n" in
  let register = Register.Text { text = "keep me"; kind = Characterwise } in
  let t = create original |> fun t -> Editor.set_unnamed_register t register in
  let t = run t [ move Down; move ~count:4 Right ] in
  let before_cursor = Editor.cursor t in
  let shifted = run t [ right 2 ] in
  assert_text shifted "header\n    let café = 1\n          print café\nfooter\n";
  assert_cursor shifted 11;
  [%test_result: int] (Editor.revision shifted) ~expect:1;
  assert (Editor.is_dirty shifted);
  assert ([%equal: Register.t option] (Editor.unnamed_register shifted) (Some register));
  let restored = run shifted [ Undo ] in
  assert_text restored original;
  assert_cursor restored before_cursor;
  assert (not (Editor.is_dirty restored));
  assert_oldest restored;
  let redone = run restored [ Redo ] in
  assert_text redone (text shifted);
  assert_cursor redone (Editor.cursor shifted);
  let bounded = run (create "a\nb\n") [ move Down; right Command.max_count ] in
  assert_text bounded "a\n  b\n";
  [%test_result: int] (Editor.revision bounded) ~expect:1
;;

let%test_unit "no-op shifts retain clean state, redo, revision and register" =
  let t = run (create "alpha\n \t\n") [ right 1; Undo ] in
  let revision = Editor.revision t in
  let t = run t [ left 1 ] in
  assert_text t "alpha\n \t\n";
  [%test_result: int] (Editor.revision t) ~expect:revision;
  assert (not (Editor.is_dirty t));
  let t = run t [ Redo ] in
  assert_text t "  alpha\n \t\n";
  let blank = run (create " \t\n\n") [ right Command.max_count ] in
  assert_text blank " \t\n\n";
  [%test_result: int] (Editor.revision blank) ~expect:0;
  assert (not (Editor.is_dirty blank));
  assert_oldest blank
;;

let%test_unit "mixed whitespace uses TAB display columns and left shifts clamp" =
  let original = " \t  λ()\n \t\nend" in
  let t = run (create original) [ left 2 ] in
  assert_text t "        λ()\n      \nend";
  assert_cursor t 8;
  let t = run t [ left 2; left 2; left 2; left 2; left 2 ] in
  assert_text t "λ()\n\nend";
  let revision = Editor.revision t in
  let t = run t [ left 2 ] in
  [%test_result: int] (Editor.revision t) ~expect:revision;
  assert_cursor t 0;
  assert_text (run (create original) [ right 1 ]) "            λ()\n \t\nend"
;;

let%test_unit "tabs policy emits whole tabs and remainder spaces without rounding shifts" =
  let indentation = { Indentation.Policy.shift_width = 3; use_tabs = true } in
  let t = run (create ~indentation "     value\n\t x\n") [ right 2 ] in
  assert_text t "\tvalue\n\t    x\n";
  assert_cursor t 1;
  let t = run t [ left 2 ] in
  assert_text t "     value\n\t x\n";
  let t = run (create ~indentation "x\ny")
      [ Enter_visual `Linewise; move Down; visual 3 ] in
  assert_text t "\t x\n\t y";
  assert_cursor t 2;
  assert (Mode.equal (Editor.mode t) Normal);
  assert (Option.is_none (Editor.selection t));
  assert_text (run t [ Undo ]) "x\ny"
;;

let%test_unit "characterwise shifts full intersected lines, excluding next-line start" =
  let original = "first\nsecond\nthird\n" in
  let t = run (create original)
      [ move ~count:2 Right; Enter_visual `Characterwise; move Down; visual 2 ] in
  assert_text t "    first\n    second\nthird\n";
  assert_cursor t 4;
  assert_text (run t [ Undo ]) original;
  (* The later endpoint is exactly column zero, forwards and backwards. *)
  let forward = run (create original)
      [ Enter_visual `Characterwise; move Down; visual 1 ] in
  assert_text forward "  first\nsecond\nthird\n";
  let backward = run (create original)
      [ move Down; Enter_visual `Characterwise; move Up; visual 1 ] in
  assert_text backward (text forward);
  (* A single selected character at a line start still touches that line. *)
  assert_text
    (run (create original) [ move Down; Enter_visual `Characterwise; visual 1 ])
    "first\n  second\nthird\n";
  (* Selecting through the LF includes its own line, never the following line. *)
  assert_text
    (run (create original) [ Enter_visual `Characterwise; move Line_end; visual 1 ])
    "  first\nsecond\nthird\n";
  assert_text
    (run (create original)
       [ Enter_visual `Characterwise; move Down; move Line_end; visual 1 ])
    "  first\n  second\nthird\n"
;;

let%test_unit "line and block selections include both endpoint lines and all their text" =
  let original = "  abcdef\n\n xyz\nlast" in
  List.iter [ `Linewise; `Blockwise ] ~f:(fun kind ->
    let t = run (create original)
        [ move ~count:4 Right; Enter_visual kind; move ~count:2 Down; visual 2 ] in
    assert_text t "      abcdef\n\n     xyz\nlast";
    assert_cursor t 6;
    assert (Mode.equal (Editor.mode t) Normal);
    [%test_result: int] (Editor.revision t) ~expect:1;
    let t = run t [ Undo ] in
    assert_text t original;
    assert (not (Editor.is_dirty t));
    assert_oldest t);
  let t = run (create "a\nb\nc")
      [ move ~count:2 Down; Enter_visual `Blockwise; move ~count:2 Up; visual 1 ] in
  assert_text t "  a\n  b\n  c";
  assert_cursor t 2
;;

let%test_unit "Insert shifts preserve Unicode text-relative cursor and join typing undo" =
  let original = "  αβ tail\nnext\n" in
  let t = run (create original)
      [ move First_nonblank; Enter_insert Before_cursor; move Right ] in
  (* Move closes any previous Insert transaction; all following edits join. *)
  let before_cursor = Editor.cursor t in
  let t = run t [ Insert_text "λ"; insert_shift true; Insert_text "!"; insert_shift false ] in
  assert_text t "  αλ!β tail\nnext\n";
  assert_cursor t 7;
  assert (Mode.equal (Editor.mode t) Insert);
  [%test_result: int] (Editor.revision t) ~expect:4;
  let t = run t [ Exit_insert; Undo ] in
  assert_text t original;
  assert_cursor t before_cursor;
  assert (not (Editor.is_dirty t));
  assert_oldest t
;;

let%test_unit "Insert can build empty-line indentation and track a cursor inside a TAB" =
  let t = run (create "")
      [ Enter_insert Before_cursor; insert_shift true; insert_shift true; Insert_text "x" ] in
  assert_text t "    x";
  assert_cursor t 5;
  assert_text (run t [ Exit_insert; Undo ]) "";
  let indentation = { Indentation.Policy.shift_width = 2; use_tabs = true } in
  let t = run (create ~indentation " \tα")
      [ move Right; Enter_insert Before_cursor; insert_shift true ] in
  assert_text t "\t  α";
  (* Old column 1 becomes column 3, inside the newly emitted TAB. *)
  assert_cursor t 0;
  let t = run t [ insert_shift false ] in
  assert_text t "\tα";
  assert_cursor t 0
;;

let%test_unit "whitespace-only lines, final LF and preferred column are preserved sensibly" =
  List.iter [ "a\n \t\n"; "a\n \t"; "a\n\n"; "a\n"; "a" ] ~f:(fun original ->
    let t = run (create original) [ right Command.max_count ] in
    assert_text t ("  " ^ original);
    assert_text (run t [ Undo ]) original);
  let t = run (create "\t\n") [ left 1 ] in
  assert_text t "      \n";
  let t = run (create "a\nabcdefgh") [ right 1; move Down ] in
  (* The shift reset preferred column from zero to the new first nonblank. *)
  [%test_result: int] (Editor.cursor_column t) ~expect:2;
  let t = run (create "  a\n")
      [ Enter_visual `Linewise; move Down; visual ~right:false Command.max_count ] in
  assert_text t "a\n";
  assert_cursor t 0
;;

let invalid f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> failwith "expected Invalid_argument"
;;

let%test_unit "invalid policy/counts are rejected, large left step arithmetic clamps" =
  List.iter [ 0; -1; Int.min_value ] ~f:(fun shift_width ->
    invalid (fun () -> create ~indentation:{ shift_width; use_tabs = false } "a"));
  List.iter [ 0; -1; Command.max_count + 1; Int.max_value ] ~f:(fun count ->
    invalid (fun () -> run (create "a") [ right count ]);
    invalid (fun () -> run (create "a") [ left count ]);
    invalid (fun () -> run (create "a") [ Enter_visual `Blockwise; visual count ]));
  let indentation = { Indentation.Policy.shift_width = Int.max_value; use_tabs = false } in
  assert_text (run (create ~indentation " \tvalue")
                 [ Enter_visual `Linewise; visual ~right:false Command.max_count ]) "value";
  invalid (fun () -> run (create ~indentation "value") [ right 1 ])
;;

let%test_unit "indentation commands apply only in their respective modes" =
  let t = create "abc" in
  assert (phys_equal t (run t [ insert_shift true; visual 1 ]));
  let t = run t [ Enter_insert Before_cursor ] in
  assert (phys_equal t (run t [ right 1; visual 1 ]));
  let t = run (create "abc") [ Enter_visual `Characterwise ] in
  assert (phys_equal t (run t [ right 1; insert_shift true ]))
;;

let%test_unit "no-op Visual exits, and no-op Insert does not create undo history" =
  let t = run (create "abc\ndef")
      [ Enter_visual `Linewise; move Down; visual ~right:false 4 ] in
  assert (Mode.equal (Editor.mode t) Normal);
  assert (Option.is_none (Editor.selection t));
  assert_cursor t 0;
  [%test_result: int] (Editor.revision t) ~expect:0;
  assert_oldest t;
  let t = run (create "abc")
      [ Enter_insert Before_cursor; insert_shift false; Exit_insert ] in
  [%test_result: int] (Editor.revision t) ~expect:0;
  assert_oldest t
;;

let%test_unit "Insert shift keeps prior block typing in the same undo transaction" =
  let t = run (create "one\ntwo")
      [ Enter_visual `Blockwise; move Down
      ; Visual_insert { append = false; count = 1 }; Insert_text "X"
      ; insert_shift true; Insert_text "Y"; Exit_insert
      ] in
  assert_text t "  XYone\nXtwo";
  assert (List.is_empty (Editor.block_insert_points t));
  let t = run t [ Undo ] in
  assert_text t "one\ntwo";
  assert_oldest t
;;

let%test_unit "custom indentation policy survives history reset and reload" =
  let indentation = { Indentation.Policy.shift_width = 3; use_tabs = true } in
  let t = create ~indentation "old" in
  let t = Editor.rebase_text t ~saved:(buffer "     rebased") ~text:(buffer "     rebased") in
  assert_text (run t [ right 1 ]) "\trebased";
  let t = Editor.handle_outcome t
      (Effect.Outcome.Read_file_finished { path = "f.txt"; result = Ok (buffer "     loaded") }) in
  assert_text (run t [ right 1 ]) "\tloaded"
;;
