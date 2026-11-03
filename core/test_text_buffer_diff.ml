open! Core
module B = Text_buffer

let text s = B.of_string s |> Result.ok |> Option.value_exn
let replace t ~pos ~len s = B.replace t ~pos ~len s |> Result.ok |> Option.value_exn
let check before after =
  match B.changed_range ~before ~after with
  | None -> [%test_eq: string] (B.to_string before) (B.to_string after)
  | Some (start, old_stop, new_stop) ->
    let inserted = B.slice after ~pos:start ~len:(new_stop - start) in
    let result = replace before ~pos:start ~len:(old_stop - start) inserted in
    [%test_eq: string] (B.to_string result) (B.to_string after)
;;

let%test_unit "bounded metadata forward/reverse, identity-only, fallback Unicode boundaries" =
  let a = text "éclair alpha beta 中华" in
  let b = replace a ~pos:8 ~len:5 "alphabet" in
  let c = replace b ~pos:0 ~len:0 "中 " in
  let d = replace c ~pos:0 ~len:4 "🐹\n" in
  let e = replace d ~pos:(B.length d - 6) ~len:6 "école" in
  List.iter [ a; b; c; d; e ] ~f:(fun before ->
    List.iter [ a; b; c; d; e ] ~f:(fun after -> check before after));
  [%test_eq: (int * int * int) option] (B.changed_range ~before:b ~after:c)
    (Some (0, 0, 4));
  assert (match B.recent_changed_range ~before:b ~after:c with
    | `Changed (0, 0, 4) -> true | _ -> false);
  assert (match B.recent_changed_range ~before:c ~after:b with
    | `Changed (0, 4, 0) -> true | _ -> false);
  let metadata = B.with_identities e ~scope:"rows" [ 0, "one" ] in
  assert (Option.is_none (B.changed_range ~before:e ~after:metadata));
  let old = text "aé🐹z" and fresh = text "aê🐻z" in
  assert (match B.recent_changed_range ~before:old ~after:fresh with
    | `Unknown -> true | _ -> false);
  check old fresh;
  check fresh old;
  let long = List.fold (List.init 80 ~f:Fn.id) ~init:a ~f:(fun t i ->
    replace t ~pos:(if i % 2 = 0 then 0 else B.length t) ~len:0 "é ") in
  assert (match B.recent_changed_range ~before:a ~after:long with
    | `Unknown -> true | _ -> false);
  check a long;
  check long a;
  let branch = replace a ~pos:0 ~len:2 "中" in
  check branch long
;;

let%test_unit "edit metadata does not retain ancestor snapshot strings" =
  let weak = Stdlib.Weak.create 1 in
  let next =
    let old = text (String.make 100000 'a') in
    Stdlib.Weak.set weak 0 (Some old);
    replace old ~pos:50000 ~len:1 "b"
  in
  Stdlib.Gc.full_major ();
  assert (not (Stdlib.Weak.check weak 0));
  assert (B.length next = 100000)
;;

let%test_unit "edit metadata saturates at 64 descriptors and releases the whole ancestor chain" =
  let weak = Stdlib.Weak.create 201 in
  let initial_charge = ref 0 in
  let current =
    let initial = text (String.make 100000 'a') in
    initial_charge := B.retained_bytes initial;
    Stdlib.Weak.set weak 0 (Some initial);
    List.fold (List.init 200 ~f:Fn.id) ~init:initial ~f:(fun previous i ->
      let next = replace previous ~pos:50000 ~len:1 (if i % 2 = 0 then "b" else "c") in
      Stdlib.Weak.set weak (i + 1) (Some next);
      if i >= 63 then
        [%test_eq: int] (B.retained_bytes next) (!initial_charge + (64 * 80));
      next)
  in
  Stdlib.Gc.full_major ();
  for i = 0 to 199 do
    assert (not (Stdlib.Weak.check weak i))
  done;
  assert (B.length current = 100000 && Stdlib.Weak.check weak 200)
;;

let%test_unit "bounded undo history charges edit metadata, restores snapshots and clears branched redo" =
  let initial = text "alpha beta" in
  let per_step_bound = 128 + (2 * (B.retained_bytes initial + (64 * 80))) in
  let limits = { History.Limits.max_steps = 3; max_bytes = 3 * per_step_bound } in
  let history, current =
    List.fold (List.init 100 ~f:Fn.id) ~init:(History.create ~limits (), initial)
      ~f:(fun (history, before) i ->
        let after = replace before ~pos:0 ~len:1 (if i % 2 = 0 then "A" else "a") in
        let history = History.ensure_active history ~before:{ text = before; cursor = 0 }
          |> fun h -> History.commit h ~after:{ text = after; cursor = 1 } in
        let stats = History.stats history in
        assert (stats.undo_steps <= 3 && stats.retained_bytes <= limits.max_bytes);
        history, after)
  in
  let original_stats = History.stats history in
  assert (original_stats.undo_steps = 3);
  let undone, before = History.undo history |> Option.value_exn in
  assert (before.cursor = 0 && not (B.equal before.text current));
  check current before.text;
  [%test_eq: int] (History.stats undone).retained_bytes original_stats.retained_bytes;
  let redone, after = History.redo undone |> Option.value_exn in
  assert (phys_equal after.text current && after.cursor = 1);
  assert (History.Stats.equal (History.stats redone) original_stats);
  let branch = replace before.text ~pos:0 ~len:1 "z" in
  let branched = History.ensure_active undone ~before
    |> fun h -> History.commit h ~after:{ text = branch; cursor = 0 } in
  assert (Option.is_none (History.redo branched));
  assert ((History.stats branched).undo_steps = 3);
  (* Metadata alone cannot create an undo step or clear redo. *)
  let same = replace before.text ~pos:0 ~len:1 (B.slice before.text ~pos:0 ~len:1) in
  let no_change = History.ensure_active undone ~before
    |> fun h -> History.commit h ~after:{ text = same; cursor = 0 } in
  assert (History.Stats.equal (History.stats no_change) (History.stats undone))
;;

let%test_unit "composed random ranges reconstruct both snapshots exactly" =
  let random = Random.State.make [| 604; 932 |] in
  let pieces = [| "a"; "éclair"; "中华"; "🐹"; ""; "\n"; "abc def" |] in
  let points t =
    let rec loop at acc =
      match B.next_boundary t at with
      | None -> Array.of_list (at :: acc)
      | Some next -> loop next (at :: acc)
    in
    loop 0 []
  in
  let current = ref (text "éclair alpha 中华🐹 abc def") in
  let ancestor = ref !current in
  for i = 0 to 999 do
    let boundaries = points !current in
    let a = boundaries.(Random.State.int random (Array.length boundaries)) in
    let b = boundaries.(Random.State.int random (Array.length boundaries)) in
    let pos = Int.min a b and stop = Int.max a b in
    current := replace !current ~pos ~len:(stop - pos)
      pieces.(Random.State.int random (Array.length pieces));
    check !ancestor !current;
    check !current !ancestor;
    if i % 80 = 0 then ancestor := !current
  done
;;
