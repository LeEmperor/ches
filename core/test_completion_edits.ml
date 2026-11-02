open! Core
module B = Text_buffer

let text s = B.of_string s |> Result.ok |> Option.value_exn
let command editor cmd = fst (Editor.dispatch editor cmd)
let inserting s =
  Editor.create ~cell_width:(fun _ -> 1) (text s)
  |> fun e -> command e (Enter_insert Line_end)
;;
let apply e edits cursor =
  Editor.apply_insert_edits e ~expected_revision:(Editor.revision e) ~edits ~cursor
  |> Or_error.ok_exn
;;

let%test_unit "inverse batches restore UTF, adjacent deletions and empty insertions" =
  let base = text "éabc🐹" in
  let edits = [ { Text_edit.start = 0; stop = 2; text = "" }
              ; { start = 2; stop = 3; text = "" }
              ; { start = 4; stop = 4; text = "日" } ] in
  let changed = Text_edit.apply base [ edits ] |> Or_error.ok_exn in
  let inverse = Text_edit.inverse base edits |> Or_error.ok_exn in
  let restored = Text_edit.apply changed [ inverse ] |> Or_error.ok_exn in
  assert (B.equal base restored)
;;

let%test_unit "atomic failures leave revision text cursor and undo intact" =
  let e = inserting "é" in
  let revision = Editor.revision e in
  let valid = { Text_edit.start = 0; stop = 2; text = "foo" } in
  let bad = { Text_edit.start = 1; stop = 4; text = "x" } in
  List.iter
    [ Editor.apply_insert_edits e ~expected_revision:(revision + 1) ~edits:[ [ valid ] ] ~cursor:3
    ; Editor.apply_insert_edits e ~expected_revision:revision ~edits:[ [ valid ]; [ bad ] ] ~cursor:3
    ; Editor.apply_insert_edits e ~expected_revision:revision ~edits:[ [ valid ] ] ~cursor:4
    ; Editor.apply_insert_edits e ~expected_revision:revision
        ~edits:[ [ { valid with text = "\r" } ] ] ~cursor:0 ]
    ~f:(fun r -> assert (Result.is_error r));
  assert (Editor.revision e = revision);
  assert (String.equal (B.to_string (Editor.text e)) "é");
  assert (Editor.cursor e = 2);
  let normal = command e Exit_insert in
  assert (Result.is_error (Editor.apply_insert_edits normal ~expected_revision:revision
    ~edits:[ [ valid ] ] ~cursor:3))
;;

let%test_unit "typed prefix cycles and deferred imports share one undo and redo" =
  let e = inserting "\n" |> fun e -> command e (Insert_text "f") in
  let a = { Text_edit.start = 0; stop = 1; text = "foo" } in
  let e = apply e [ [ a ] ] 3 in
  let b = { a with text = "foobar" } in
  let inverse_a = Text_edit.inverse (text "f") [ a ] |> Or_error.ok_exn in
  let before = Editor.revision e in
  let e = apply e [ inverse_a; [ b ] ] 6 in
  assert (Editor.revision e = before + 1);
  let inverse_b = Text_edit.inverse (text "f") [ b ] |> Or_error.ok_exn in
  let extra = { Text_edit.start = 2; stop = 2; text = "import" } in
  let e = apply e [ inverse_b; [ b; extra ] ] 6 in
  assert (String.equal (B.to_string (Editor.text e)) "foobar\nimport");
  let e = command e Exit_insert |> fun e -> command e Undo in
  assert (String.equal (B.to_string (Editor.text e)) "\n");
  assert (not (Editor.is_dirty e));
  let e = command e Redo in
  assert (String.equal (B.to_string (Editor.text e)) "foobar\nimport")
;;

let%test_unit "net no-op sequential batches do not increment revision" =
  let e = inserting "f" in
  let a = { Text_edit.start = 0; stop = 1; text = "foo" } in
  let inverse = Text_edit.inverse (text "f") [ a ] |> Or_error.ok_exn in
  let after = apply e [ [ a ]; inverse ] 1 in
  assert (Editor.revision e = Editor.revision after);
  assert (not (Editor.is_dirty after))
;;

let%test_unit "batch edits and inverses agree with independent string oracle" =
  let rng = Stdlib.Random.State.make [| 912; 44 |] in
  let chunks = [| ""; "é"; "🐹"; "\n"; "abc\n日" |] in
  for _ = 1 to 200 do
    let a = chunks.(Stdlib.Random.State.int rng (Array.length chunks)) in
    let b = chunks.(Stdlib.Random.State.int rng (Array.length chunks)) in
    let c = chunks.(Stdlib.Random.State.int rng (Array.length chunks)) in
    let base = text "a-b-c" in
    let edits =
      [ { Text_edit.start = 0; stop = 1; text = a }
      ; { start = 2; stop = 3; text = b }
      ; { start = 4; stop = 5; text = c } ]
    in
    let after = Text_edit.apply base [ List.rev edits ] |> Or_error.ok_exn in
    assert (String.equal (B.to_string after) (a ^ "-" ^ b ^ "-" ^ c));
    let inverse = Text_edit.inverse base edits |> Or_error.ok_exn in
    let restored = Text_edit.apply after [ inverse ] |> Or_error.ok_exn in
    assert (B.equal base restored)
  done
;;

let%test_unit "external completion edits cannot bypass block insert replication" =
  let e = Editor.create ~cell_width:(fun _ -> 1) (text "abc\ndef") in
  let e = command e (Enter_visual `Blockwise)
    |> fun e -> command e (Visual_insert { append = false; count = 1 }) in
  assert (not (List.is_empty (Editor.block_insert_points e)));
  assert (Result.is_error (Editor.apply_insert_edits e ~expected_revision:0
    ~edits:[ [ { start = 0; stop = 0; text = "completion" } ] ] ~cursor:10))
;;
