open! Core
open Ches_highlight
open Ches_highlight_ocaml

let compare_result (actual : Provider.result) (expected : Provider.result) =
  assert (Provider.Status.equal actual.status expected.status);
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges actual.snapshot)
    ~expect:(Snapshot.ranges expected.snapshot)
;;

let%test_unit "incremental sequences equal fresh normalized highlights for both grammars" =
  List.iter [ Language.Ocaml; Ocaml_interface ] ~f:(fun language ->
    let provider = Provider.create ~language in
    let fresh = Provider.create ~language in
    let document = Snapshot.Document_id.create () in
    let initial =
      if Language.equal language Ocaml then "let f x = \"é\\n\"\nlet n = 42\n"
      else "val f : int -> string\nval n : int\n"
    in
    let revision = ref 0 in
    let history = ref [] in
    let check source =
      let key = Provider.key provider ~document ~revision:!revision in
      let actual = Provider.highlight_incremental provider ~key ~source in
      compare_result actual (Provider.highlight fresh ~key ~source);
      (* Keeping old results cannot allow later Tree.edit to change their ranges. *)
      history := (actual.snapshot, Snapshot.ranges actual.snapshot) :: !history;
      incr revision
    in
    List.iter
      [ initial; "(*\n" ^ initial; "(*\n" ^ initial ^ "*)\n"
      ; "(* outer (* inner *)\n" ^ initial ^ "*)\n"
      ; "let s = \"first\né\"\n" ^ initial
      ; "let s = \"first\né\n" ^ initial; "let = )\n"; ""
      ; initial; "\n" ^ initial; initial; "\n" ^ initial ] ~f:check;
    let random = Random.State.make [| 5050 |] in
    let fragments = [ "é"; "ê"; "😀"; "\n"; "(*"; "*)"; "\""; "let x = 1"; "val f : int"; " " ] in
    let parts = ref [ initial ] in
    for i = 1 to 200 do
      let before = String.concat !parts in
      let at = Random.State.int random (List.length !parts + 1) in
      let #(left, right) = List.split_n !parts at in
      parts :=
        if i mod 3 = 0 && not (List.is_empty right) then left @ List.tl_exn right
        else left @ [ List.nth_exn fragments (Random.State.int random (List.length fragments)) ] @ right;
      let after = String.concat !parts in
      check after;
      if i mod 10 = 0 then (check before; check after);
      if i mod 25 = 0 then Gc.full_major ()
    done;
    assert (Provider.incremental_count provider = Provider.parse_count provider - 1);
    List.iter !history ~f:(fun (snapshot, ranges) ->
      [%test_result: Snapshot.Range.t list] (Snapshot.ranges snapshot) ~expect:ranges);
    Provider.close provider;
    Provider.close fresh)
;;

let%test_unit "identity changes, fresh calls and failures reset privately retained trees" =
  let provider = Provider.create ~language:Ocaml in
  let document = Snapshot.Document_id.create () in
  let key = Provider.key provider ~document ~revision:0 in
  let source = "let x = 1\n" in
  ignore (Provider.highlight_incremental provider ~key ~source : Provider.result);
  ignore (Provider.highlight_incremental provider ~key ~source : Provider.result);
  assert (Provider.incremental_count provider = 1);
  let other = Provider.key provider ~document:(Snapshot.Document_id.create ()) ~revision:0 in
  ignore (Provider.highlight_incremental provider ~key:other ~source : Provider.result);
  assert (Provider.incremental_count provider = 1);
  ignore (Provider.highlight provider ~key:other ~source : Provider.result);
  ignore (Provider.highlight_incremental provider ~key:other ~source : Provider.result);
  assert (Provider.incremental_count provider = 1);
  let invalid = Provider.highlight_incremental provider ~key:other ~source:"\xff" in
  assert (Provider.Status.equal invalid.status (Plain Invalid_utf8));
  assert (Option.is_none (Provider.last_timings provider));
  ignore (Provider.highlight_incremental provider ~key:other ~source : Provider.result);
  assert (Provider.incremental_count provider = 1);
  Provider.For_testing.fail_next_parse provider;
  let failed = Provider.highlight_incremental provider ~key:other ~source:"let x = 2" in
  assert (match failed.status with Plain (Parsing _) -> true | _ -> false);
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges failed.snapshot) ~expect:[];
  Provider.close provider;
  assert (Provider.Status.equal (Provider.highlight_incremental provider ~key ~source).status (Plain Closed))
;;
