open! Core
open Ches_core
module D = Directory_identity
module B = Text_buffer

let entries = [ { D.Entry.id = 1; name = "alpha"; kind = File }
              ; { D.Entry.id = 2; name = "beta"; kind = File } ]
let baseline = D.create entries |> Or_error.ok_exn
let initial = D.text ~scope:"directory-one" baseline
let insert text at s = B.insert text ~at s |> Result.ok |> Option.value_exn
let rows text = D.parse baseline text |> Or_error.ok_exn
let run editor commands = List.fold commands ~init:editor ~f:(fun editor command -> fst (Editor.dispatch editor command))
let editor () = Editor.create ~cell_width:Cell_width.f initial

let%test_unit "hidden metadata preserves whole-name replacements and real cursor columns" =
  assert (String.equal (B.to_string initial) "alpha\nbeta");
  let blank = B.delete initial ~pos:0 ~len:5 in
  assert (Result.is_error (D.parse baseline blank));
  let renamed = insert blank 0 "new" in
  assert (D.Row.equal_identity (List.hd_exn (rows renamed)).identity (Existing 1));
  let plan = Directory_plan.plan entries renamed |> Or_error.ok_exn in
  assert (List.length plan = 1);
  let e = run (editor ()) [ Enter_insert Before_cursor; Insert_text "new"; Exit_insert ] in
  assert (String.equal (B.to_string (Editor.text e)) "newalpha\nbeta");
  assert (B.equal (Editor.text (run e [ Undo ])) initial);
  assert (B.equal (Editor.text (run (run e [ Undo ]) [ Redo ])) (Editor.text e))
;;

let%test_unit "Visual line change replaces a name without adopting the next row" =
  let e = run (editor ()) [ Enter_visual `Linewise; Visual_change; Insert_text "new"; Exit_insert ] in
  assert (String.equal (B.to_string (Editor.text e)) "new\nbeta");
  assert ([%equal: D.Row.identity list] (List.map (rows (Editor.text e)) ~f:(fun row -> row.identity)) [ Existing 1; Existing 2 ]);
  assert (B.equal (Editor.text (run e [ Undo ])) initial)
;;

let%test_unit "Visual characterwise whole-name change keeps the row separator" =
  let e = run (editor ()) [ Enter_visual `Characterwise; Move { motion = Line_end; count = None }; Visual_change; Insert_text "new"; Exit_insert ] in
  assert (String.equal (B.to_string (Editor.text e)) "new\nbeta");
  assert ([%equal: D.Row.identity list] (List.map (rows (Editor.text e)) ~f:(fun row -> row.identity)) [ Existing 1; Existing 2 ])
;;

let%test_unit "row deletion reordering duplication and explicit copies retain identity" =
  let moved = run (editor ()) [ Delete_lines 1; Paste { before = false; count = 1 } ] in
  assert (List.is_empty (Directory_plan.plan entries (Editor.text moved) |> Or_error.ok_exn));
  let duplicated = run (editor ()) [ Yank_lines 1; Paste { before = false; count = 1 } ] in
  assert (Result.is_error (D.parse baseline (Editor.text duplicated)));
  let copied = run duplicated [ Enter_insert Before_cursor; Insert_text "@copy "; Exit_insert ] in
  let copied_text = Editor.text copied in
  let line = Editor.cursor_line copied in
  let start = B.line_start copied_text line in
  let copied_text = B.delete copied_text ~pos:(start + 6) ~len:5 |> fun text -> insert text (start + 6) "copy" in
  assert (List.exists (rows copied_text) ~f:(fun row -> D.Row.equal_identity row.identity (Copy 1)));
  assert (List.length (Directory_plan.plan entries copied_text |> Or_error.ok_exn) = 1);
  let last = B.delete ~linewise:true initial ~pos:6 ~len:4 in
  assert ([%equal: int list] (D.missing_ids baseline (rows last)) [ 2 ])
;;

let%test_unit "split anchors are deterministic and joins refuse ambiguous identities" =
  let before = insert initial 0 "fresh\n" in
  assert ([%equal: D.Row.identity list] (List.map (rows before) ~f:(fun row -> row.identity)) [ Fresh; Existing 1; Existing 2 ]);
  let split = insert initial 2 "\n" in
  assert ([%equal: D.Row.identity list] (List.map (rows split) ~f:(fun row -> row.identity)) [ Existing 1; Fresh; Existing 2 ]);
  assert (Result.is_error (D.parse baseline (B.delete initial ~pos:5 ~len:1)));
  let joined_fresh = B.delete before ~pos:5 ~len:1 in
  assert ([%equal: (int * string) list] (B.identities joined_fresh) [ 0, "@ches[1]"; 11, "@ches[2]" ]);
  assert (Result.is_error (D.parse baseline (insert initial 0 "@ches[2]\t")))
;;

let%test_unit "registers protect directory ownership and keep clipboard names only" =
  let source = run (editor ()) [ Yank_lines 1 ] in
  let register = Editor.unnamed_register source |> Option.value_exn in
  assert (String.equal (Register.to_string register) "alpha\n");
  let other_text = D.text ~scope:"directory-two" baseline in
  let other = Editor.create ~cell_width:Cell_width.f other_text |> fun e -> Editor.set_unnamed_register e register in
  let other = run other [ Paste { before = false; count = 1 } ] in
  assert (B.equal (Editor.text other) other_text);
  let file = Editor.create ~cell_width:Cell_width.f (B.of_string "file" |> Result.ok |> Option.value_exn)
    |> fun e -> Editor.set_unnamed_register e register in
  let file = run file [ Paste { before = true; count = 1 } ] in
  assert (String.equal (B.to_string (Editor.text file)) "alpha\nfile");
  assert (Option.is_none (B.identity_scope (Editor.text file)))
;;

let%test_unit "cut paste round trips are clean regardless of anchor insertion order" =
  let unchanged = run (editor ()) [ Delete_lines 1; Paste { before = true; count = 1 } ] in
  assert (B.equal (Editor.text unchanged) initial);
  assert (not (Editor.is_dirty unchanged));
  let baseline = D.create (entries @ [ { D.Entry.id = 3; name = "gamma"; kind = File } ]) |> Or_error.ok_exn in
  let text = D.text ~scope:"three-rows" baseline in
  let e = Editor.create ~cell_width:Cell_width.f text in
  let moved = run e [ Delete_lines 1; Paste { before = false; count = 1 } ] in
  assert (String.equal (B.to_string (Editor.text moved)) "beta\nalpha\ngamma");
  assert (Editor.is_dirty moved);
  let restored = run moved [ Delete_lines 1; Move { motion = First_line; count = None }; Paste { before = true; count = 1 } ] in
  assert (B.equal (Editor.text restored) text && not (Editor.is_dirty restored));
  assert (not (Editor.is_dirty (run restored [ Undo; Redo ])));
  let reordered = B.with_identities initial ~scope:"directory-one" (List.rev (B.identities initial)) in
  assert (B.equal reordered initial);
  let duplicated = B.with_identities initial ~scope:"directory-one" ((0, "@ches[1]") :: B.identities initial) in
  assert (not (B.equal duplicated initial));
  assert (Result.is_error (D.parse baseline duplicated))
;;

let%test_unit "opening above and below empty protected rows keeps their identity on the old row" =
  List.iter [ false; true ] ~f:(fun last ->
    let blank = if last then B.delete initial ~pos:6 ~len:4 else B.delete initial ~pos:0 ~len:5 in
    List.iter [ false; true ] ~f:(fun below ->
      let e = Editor.create ~cell_width:Cell_width.f blank in
      let e = if last then run e [ Move { motion = Last_line; count = None } ] else e in
      let e = run e [ (if below then Open_line_below else Open_line_above); Insert_text "fresh"; Exit_insert ] in
      let text = Editor.text e in
      assert (Result.is_error (D.parse baseline text));
      let id = if last then "@ches[2]" else "@ches[1]" in
      let offset = List.find_map_exn (B.identities text) ~f:(fun (offset, token) -> if String.equal token id then Some offset else None) in
      assert (String.is_empty (B.line_text text (B.line_of_offset text offset)));
      let repaired = insert text offset (if last then "beta" else "alpha") in
      let parsed = rows repaired in
      let fresh = List.find_exn parsed ~f:(fun row -> D.Row.equal_identity row.identity Fresh) in
      assert (String.equal fresh.name "fresh");
      let e = run e [ Undo ] in
      assert (B.equal (Editor.text e) blank && not (Editor.is_dirty e))))
;;

let%test_unit "linewise pastes above and below empty protected rows do not fill or adopt them" =
  let register = Register.Text { text = "fresh"; kind = Linewise } in
  List.iter [ false; true ] ~f:(fun last ->
    let blank = if last then B.delete initial ~pos:6 ~len:4 else B.delete initial ~pos:0 ~len:5 in
    List.iter [ false; true ] ~f:(fun before ->
      let e = Editor.create ~cell_width:Cell_width.f blank |> fun e -> Editor.set_unnamed_register e register in
      let e = if last then run e [ Move { motion = Last_line; count = None } ] else e in
      let e = run e [ Paste { before; count = 1 } ] in
      let text = Editor.text e in
      assert (Result.is_error (D.parse baseline text));
      let id = if last then "@ches[2]" else "@ches[1]" in
      let offset = List.find_map_exn (B.identities text) ~f:(fun (offset, token) -> if String.equal token id then Some offset else None) in
      assert (String.is_empty (B.line_text text (B.line_of_offset text offset)));
      let repaired = insert text offset (if last then "beta" else "alpha") in
      assert (List.exists (rows repaired) ~f:(fun row -> D.Row.equal_identity row.identity Fresh && String.equal row.name "fresh"));
      assert (B.equal (Editor.text (run e [ Undo ])) blank)))
;;

let%test_unit "Visual line delete removes an empty protected final row with zero visible bytes" =
  let blank = B.delete initial ~pos:6 ~len:4 in
  let e = Editor.create ~cell_width:Cell_width.f blank in
  let e = run e [ Move { motion = Last_line; count = None }; Enter_visual `Linewise; Visual_delete ] in
  assert ([%equal: int list] (D.missing_ids baseline (rows (Editor.text e))) [ 2 ]);
  assert (Editor.is_dirty e);
  assert (B.equal (Editor.text (run e [ Undo ])) blank);
  let e = run (Editor.create ~cell_width:Cell_width.f blank)
    [ Move { motion = Last_line; count = None }; Enter_visual `Linewise; Visual_change; Insert_text "renamed"; Exit_insert ] in
  assert (D.Row.equal_identity (List.last_exn (rows (Editor.text e))).identity (Existing 2));
  assert (String.equal (B.to_string (Editor.text e)) "alpha\nrenamed")
;;

let%test_unit "protected row pastes next to an empty final identity keep both owners separate" =
  List.iter [ false; true ] ~f:(fun before ->
    let cut = run (editor ()) [ Delete_lines 1 ] in
    let register = Editor.unnamed_register cut |> Option.value_exn in
    let e = run cut [ Delete_chars_forward 4 ] |> fun e -> Editor.set_unnamed_register e register in
    let e = run e [ Paste { before; count = 1 } ] in
    let text = Editor.text e in
    assert (Result.is_error (D.parse baseline text));
    let old = List.find_map_exn (B.identities text) ~f:(fun (offset, token) ->
      if String.equal token "@ches[2]" then Some offset else None) in
    assert (String.is_empty (B.line_text text (B.line_of_offset text old)));
    let repaired = insert text old "beta" in
    assert (List.length (rows repaired) = 2);
    assert (List.is_empty (Directory_plan.plan entries repaired |> Or_error.ok_exn)))
;;
