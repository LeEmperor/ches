open! Core
open Ches_core

let text s = Text_buffer.of_string s |> Result.ok |> Option.value_exn
let snap ?(cursor = 0) s = { History.text = text s; cursor }
let add h before after = History.ensure_active h ~before |> History.commit ~after
let create steps bytes = History.create ~limits:{ max_steps = steps; max_bytes = bytes } ()
let charge a b = 128 + Text_buffer.retained_bytes a.History.text + Text_buffer.retained_bytes b.History.text
let undo h = History.undo h |> Option.value_exn
let redo h = History.redo h |> Option.value_exn
let check_snapshot actual expected =
  assert (Text_buffer.equal actual.History.text expected.History.text);
  [%test_result: int] actual.cursor ~expect:expected.cursor
;;

let%test_unit "count limit keeps exact order/cursors across both stacks without recharge" =
  let a = snap "a" and b = snap ~cursor:1 "ab" and c = snap ~cursor:2 "abc" and d = snap ~cursor:3 "abcd" in
  let h = add (add (add (create 2 Int.max_value) a b) b c) c d in
  let bytes = (History.stats h).retained_bytes in
  [%test_result: int] bytes ~expect:(charge b c + charge c d);
  let h, s = undo h in check_snapshot s c;
  let h, s = undo h in check_snapshot s b;
  assert (Option.is_none (History.undo h));
  [%test_result: int] (History.stats h).retained_bytes ~expect:bytes;
  let h, s = redo h in check_snapshot s c;
  let h, s = redo h in check_snapshot s d;
  assert (Option.is_none (History.redo h));
  let h = List.fold (List.range 0 10) ~init:h ~f:(fun h _ -> fst (redo (fst (undo h)))) in
  [%test_result: int] (History.stats h).retained_bytes ~expect:bytes
;;

let%test_unit "byte limit exact boundary, oldest eviction, oversized newest and replacement" =
  let a = snap "a" and b = snap "b" and c = snap "c" and d = snap "d" in
  let budget = charge a b + charge b c in
  let h = add (add (create 10 budget) a b) b c in
  [%test_result: int] (History.stats h).undo_steps ~expect:2;
  let h = add h c d in
  let h, s = undo h in check_snapshot s c;
  let h, s = undo h in check_snapshot s b;
  assert (Option.is_none (History.undo h));
  let big = snap (String.make 2000 'x') in
  let h = add (add (create 10 budget) a b) b big in
  [%test_result: int] (History.stats h).undo_steps ~expect:1;
  [%test_result: int] (History.stats h).retained_bytes ~expect:(charge b big);
  let h, s = undo h in check_snapshot s b;
  let h, s = redo h in check_snapshot s big;
  let h = add h c d in
  [%test_result: int] (History.stats h).retained_bytes ~expect:(charge c d);
  [%test_result: int] (History.stats h).undo_steps ~expect:1;
  let h = add (create 1 0) a b in
  [%test_result: int] (History.stats h).retained_bytes ~expect:(charge a b)
;;

let%test_unit "active transaction is protected; no-op preserves redo; branch drops it" =
  let a = snap "a" and b = snap "b" and c = snap "c" in
  let h = add (create 1 0) a b in
  let baseline = History.stats h in
  let h = History.ensure_active h ~before:b |> History.ensure_active ~before:c in
  assert (History.is_active h);
  assert (History.Stats.equal (History.stats h) baseline);
  let h = History.commit h ~after:c in
  let h, s = undo h in check_snapshot s b;
  let baseline = History.stats h in
  let h = add h b { b with cursor = 1 } in
  assert (History.Stats.equal (History.stats h) baseline);
  assert (not (History.is_active h));
  let h = add h b a in
  assert (Option.is_none (History.redo h));
  [%test_result: int] (History.stats h).retained_bytes ~expect:(charge b a);
  let _, s = undo h in check_snapshot s b
;;

let%test_unit "one within-budget commit can evict multiple old steps" =
  let a = snap "a" and b = snap "b" and c = snap "c" and d = snap "d" in
  let budget = 3 * charge a b in
  let h = add (add (add (create 10 budget) a b) b c) c d in
  let large = snap (String.make 800 'x') in
  assert (charge d large <= budget);
  let h = add h d large in
  [%test_result: int] (History.stats h).undo_steps ~expect:1;
  [%test_result: int] (History.stats h).retained_bytes ~expect:(charge d large);
  let h, s = undo h in check_snapshot s d;
  assert (Option.is_none (History.undo h))
;;

let%test_unit "warming layout caches cannot grow the deterministic history charge" =
  let a = snap "abc\ndef" and b = snap "abc\ndefg" in
  let h = add (create 2 Int.max_value) a b in
  let bytes = (History.stats h).retained_bytes in
  List.iter [a; b] ~f:(fun s ->
    for line = 0 to Text_buffer.line_count s.text - 1 do
      ignore (Cell_layout.Index.total_width (Text_buffer.line_layout s.text ~width:Cell_width.f line) : int)
    done);
  [%test_result: int] (History.stats h).retained_bytes ~expect:bytes
;;

let%test_unit "hidden identities count, differ despite same bytes, and restore exactly" =
  let a = { History.text = Text_buffer.with_identities (text "a\nb") ~scope:"dir" [0, "@ches[1]"; 2, "@ches[2]"]; cursor = 2 } in
  let b = { a with text = Text_buffer.with_identities (text "a\nb") ~scope:"dir" [0, "@ches[2]"; 2, "@ches[1]"] } in
  assert (Text_buffer.retained_bytes a.text > Text_buffer.retained_bytes (text "a\nb"));
  let h = add (create 1 0) a b in
  let h, s = undo h in check_snapshot s a;
  let _, s = redo h in check_snapshot s b;
  let stripped = Text_buffer.delete a.text ~pos:0 ~len:0 ~linewise:true in
  assert (Text_buffer.retained_bytes stripped < Text_buffer.retained_bytes a.text)
;;

let%test_unit "evicted and branched snapshots are collectible; persistent old states valid" =
  let weak = Stdlib.Weak.create 1 in
  let h =
    let a = snap (String.make 100 'a') in
    Stdlib.Weak.set weak 0 (Some a.text);
    let b = snap "b" and c = snap "c" in
    add (add (create 1 Int.max_value) a b) b c
  in
  Stdlib.Gc.full_major ();
  assert (not (Stdlib.Weak.check weak 0));
  assert ((History.stats h).undo_steps = 1);
  let weak = Stdlib.Weak.create 1 in
  let h =
    let a = snap "a" and b = snap (String.make 100 'b') in
    Stdlib.Weak.set weak 0 (Some b.text);
    let h, _ = undo (add (create 2 Int.max_value) a b) in
    add h a (snap "c")
  in
  Stdlib.Gc.full_major ();
  assert (not (Stdlib.Weak.check weak 0));
  let old = h in
  let _new = add h (snap "c") (snap "d") in
  let _, s = undo old in check_snapshot s (snap "a")
;;

let%test_unit "invalid limits rejected" =
  List.iter [0, 1; -1, 1; 1, -1] ~f:(fun (steps, bytes) ->
    assert (Exn.does_raise (fun () -> create steps bytes)))
;;
