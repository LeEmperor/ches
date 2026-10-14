open! Core
open Ches_file_picker
module Event = Ches_palette.Palette.Event

let candidate path = Model.Candidate.create ~root:"/project" ~relative_path:path |> Or_error.ok_exn
let snapshot ?(run = 1) ?(root = "/project") status paths : Model.Discovery.t =
  { request = { run_id = Model.Run_id.of_int run; root }
  ; candidates = List.map paths ~f:candidate; status }
;;

let drain t =
  let turns = ref 0 in
  while Interaction.busy t do
    incr turns;
    assert (!turns < 1000);
    Interaction.work t ~budget:2
  done
;;

let%test_unit "blank/whitespace indices are bounded, reused only for their snapshot, and dropped on close" =
  let discovery = snapshot Partial [ "z.ml"; "a\n界.ml"; "b.ml" ] in
  let t = Interaction.create ~token:() ~discovery in
  let drain_bounded () =
    while Interaction.busy t do
      let before = Interaction.indexed_count t in
      Interaction.work t ~budget:1;
      assert (Interaction.indexed_count t - before <= 1)
    done in
  Interaction.work t ~budget:1;
  assert (Interaction.indexed_count t = 1 && Interaction.prepared_count t = 0);
  assert (Model.result_count (Interaction.model t) = 0 && Interaction.busy t);
  let calls = ref 0 in
  Interaction.accept t ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
  assert (!calls = 0);
  (* Coalesce a partially built index; no abandoned result may publish. *)
  Interaction.update t (Paste " \t\n ");
  drain_bounded ();
  let model = Interaction.model t in
  assert (Interaction.prepared_count t = 0 && Model.result_count model = 3);
  assert (not (Model.For_testing.results_forced model));
  let expected = Search.rank ~query:" " (Search.prepare discovery.candidates) in
  [%test_eq: string]
    (Sexp.to_string [%sexp (Model.result_slice model ~start:0 ~length:3 : Model.Query_result.t list)])
    (Sexp.to_string [%sexp (expected : Model.Query_result.t list)]);
  Interaction.update t Next;
  assert (Option.equal Int.equal (Model.selected_index (Interaction.model t)) (Some 1));
  Interaction.update t Delete_word;
  let indexed = Interaction.indexed_count t in
  Interaction.work t ~budget:1;
  assert (not (Interaction.busy t) && Interaction.indexed_count t = indexed);
  assert (Option.equal Int.equal (Model.selected_index (Interaction.model t)) (Some 1));
  (* Filtering prepares paths; returning to blank uses its already-built index. *)
  Interaction.update t (Paste "ml"); drain_bounded ();
  assert (Interaction.prepared_count t = 3);
  Interaction.update t Delete_word;
  let indexed = Interaction.indexed_count t in
  Interaction.work t ~budget:1;
  assert (not (Interaction.busy t) && Interaction.indexed_count t = indexed);
  let next = snapshot Partial [ "0.ml"; "z.ml"; "a\n界.ml"; "b.ml" ] in
  assert (Interaction.install t next);
  drain_bounded ();
  assert (Interaction.prepared_count t = 3); (* new blank path is not prepared *)
  assert (Option.equal Int.equal (Model.selected_index (Interaction.model t)) (Some 2));
  let indexed = Interaction.indexed_count t in
  assert (Interaction.install t { next with status = Complete { truncated = false } });
  assert (not (Interaction.busy t) && Interaction.indexed_count t = indexed);
  assert (Interaction.install t (snapshot Partial [ "z.ml" ])); drain_bounded ();
  assert (Option.equal Int.equal (Model.selected_index (Interaction.model t)) (Some 0));
  Interaction.cancel t ~release:ignore;
  assert (Model.result_count (Interaction.model t) = 0);
  assert (not (Interaction.install t next));
  let reopened = Interaction.create ~token:() ~discovery:next in
  drain reopened;
  assert (Interaction.prepared_count reopened = 0);
  assert (Model.result_count (Interaction.model reopened) = 4);
  assert (Option.equal Int.equal (Model.selected_index (Interaction.model reopened)) (Some 0));
  let empty = Interaction.create ~token:() ~discovery:(snapshot Loading []) in
  Interaction.work empty ~budget:1;
  assert (not (Interaction.busy empty) && Interaction.indexed_count empty = 0)
;;

let selected t =
  Model.selected (Interaction.model t) |> Option.map ~f:Model.Candidate.Id.to_string
;;

let%test_unit "compiled job reuse, no per-query string ID inserts, bounded lazy exact alignment, and immutable old queries" =
  let paths = List.init 300 ~f:(fun i -> sprintf "src/f%03d_界Model.ml" i) in
  let discovery = snapshot Partial paths in
  let t = Interaction.create ~token:() ~discovery in
  drain t;
  let blank = Interaction.model t in
  assert (Interaction.prepared_count t = 0 && Interaction.scored_count t = 0);
  let compiles = Interaction.compiled_count t in
  Interaction.update t (Paste "f");
  drain t;
  let old = Interaction.model t in
  assert (Interaction.compiled_count t = compiles + 1);
  assert (Interaction.scored_count t = 300 && Model.result_count old = 300);
  assert (Model.For_testing.string_id_insertions old = 0);
  assert (Model.For_testing.same_identity blank old);
  assert (Model.For_testing.alignment_count old = 0);
  Interaction.update t Next;
  ignore (Model.selected (Interaction.model t) : Model.Candidate.Id.t option);
  ignore (Model.accept (Interaction.model t) : unit Model.Request.t option);
  assert (Model.For_testing.alignment_count old = 0);
  let expected = Test_search.oracle "f" discovery.candidates in
  let slice = Model.result_slice old ~start:3 ~length:7 in
  [%test_eq: string]
    (Sexp.to_string [%sexp (slice : Model.Query_result.t list)])
    (Sexp.to_string [%sexp (List.take (List.drop expected 3) 7 : Model.Query_result.t list)]);
  assert (Model.For_testing.alignment_count old = 7);
  ignore (Model.result_slice old ~start:3 ~length:7 : Model.Query_result.t list);
  assert (Model.For_testing.alignment_count old = 7);
  ignore (Model.result_slice old ~start:10 ~length:200 : Model.Query_result.t list);
  assert (Model.For_testing.alignment_cache_size old = 128);
  assert (not (Model.For_testing.results_forced old));
  Interaction.update t (Paste " Model"); drain t;
  let next = Interaction.model t in
  assert (Interaction.prepared_count t = 300);
  assert (Model.For_testing.same_identity old next && Model.For_testing.string_id_insertions next = 0);
  assert (Model.For_testing.alignment_count next = 0);
  assert (Interaction.install t (snapshot Partial [ "src/f_new.ml" ]));
  drain t;
  assert (not (Model.For_testing.same_identity old (Interaction.model t)));
  Interaction.cancel t ~release:ignore;
  (* Old published alignments capture immutable query/preparation, not the session
     or reused scratch. Reading after replacement/close still has original meaning. *)
  [%test_eq: string]
    (Sexp.to_string [%sexp (Model.results old : Model.Query_result.t list)])
    (Sexp.to_string [%sexp (expected : Model.Query_result.t list)]);
  assert (Model.For_testing.alignment_cache_size old <= 128)
;;

let%expect_test "bounded preparation, coalescing, stable incremental selection and stale snapshots" =
  let first = snapshot Partial [ "a/model.ml"; "b/model.ml"; "c/test.ml" ] in
  let t = Interaction.create ~token:7 ~discovery:first in
  assert (Interaction.prepared_count t = 0);
  Interaction.work t ~budget:1;
  assert (Interaction.prepared_count t = 0);
  assert (Interaction.busy t);
  drain t; (* snapshot identity work is independent of fuzzy preparation *)
  Interaction.update t (Paste "model");
  Interaction.work t ~budget:1;
  assert (Interaction.prepared_count t = 1);
  Interaction.update t (Paste ".ml");
  assert (Interaction.prepared_count t = 1);
  drain t;
  assert (Interaction.prepared_count t = 3);
  Interaction.update t Next;
  assert ([%equal: string option] (selected t) (Some "/project/b/model.ml"));
  let next = snapshot Partial [ "0/model.ml"; "a/model.ml"; "b/model.ml"; "c/test.ml" ] in
  assert (Interaction.install t next);
  drain t;
  assert (Interaction.prepared_count t = 4);
  assert ([%equal: string option] (selected t) (Some "/project/b/model.ml"));
  assert (not (Interaction.install t (snapshot ~run:2 Loading [])));
  assert (not (Interaction.install t (snapshot ~root:"/elsewhere" Loading [])));
  assert (Interaction.install t { next with status = Complete { truncated = true } });
  assert (not (Interaction.busy t));
  assert (Interaction.install t (snapshot (Failed "rg failed") [ "a/model.ml" ]));
  drain t;
  assert ([%equal: string option] (selected t) (Some "/project/a/model.ml"));
  Interaction.update t (Paste "zzzz");
  drain t;
  assert (Option.is_none (selected t));
  let calls = ref 0 in
  Interaction.accept t ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
  assert (!calls = 0);
  assert (not (Interaction.closed t));
  [%expect {| |}]
;;

let%expect_test "sanitized edits and chunked ranking equal Search, stable ties and Unicode highlights" =
  let discovery = snapshot (Complete { truncated = false })
    [ "a/model.ml"; "b/model.ml"; "src/模型.ml"; "odd/line\nfile.ml"; "src/module.ml" ] in
  let t = Interaction.create ~token:() ~discovery in
  List.iter [ ""; "m"; "model"; "src mod"; "模型"; "ml"; "zzzz" ] ~f:(fun query ->
    Interaction.update t Delete_word;
    (* A prior multiword query needs more than one word deletion. *)
    while not (String.is_empty (Interaction.query t)) do Interaction.update t Delete_word done;
    Interaction.update t (Paste query);
    drain t;
    let expected = Search.rank ~query (Search.prepare discovery.candidates) in
    assert (String.equal
      (Sexp.to_string [%sexp (expected : Model.Query_result.t list)])
      (Sexp.to_string [%sexp (Model.results (Interaction.model t) : Model.Query_result.t list)])));
  assert (Interaction.prepared_count t = 5);
  Interaction.update t Delete_word;
  Interaction.update t (Paste "a\r\nb\tc\000\027");
  assert (String.equal (Interaction.query t) "a b c");
  Interaction.update t Delete_word;
  assert (String.equal (Interaction.query t) "a b ");
  Interaction.update t Delete_word;
  assert (String.equal (Interaction.query t) "a ");
  Interaction.update t (Paste "模型");
  Interaction.update t Backspace;
  assert (String.equal (Interaction.query t) "a 模");
  [%expect {| |}]
;;

let%expect_test "acceptance closes before fake consumer once, pending/no selection/cancel have no intent" =
  let discovery = snapshot Partial [ "odd/line\nfile.ml" ] in
  let t = Interaction.create ~token:42 ~discovery in
  let released = ref false in
  let received = ref [] in
  let release () = assert (Interaction.closed t); released := true in
  let consume request =
    assert (!released);
    received := request :: !received;
    Interaction.accept t ~release ~consume:(fun _ -> assert false)
  in
  Interaction.accept t ~release ~consume;
  assert (not !released);
  drain t;
  Interaction.accept t ~release ~consume;
  Interaction.accept t ~release ~consume;
  assert (List.length !received = 1);
  let request = List.hd_exn !received in
  assert (request.token = 42 && String.equal request.path "/project/odd/line\nfile.ml");
  assert (Model.result_count (Interaction.model t) = 0);
  assert (not (Interaction.install t discovery));
  let cancelled = Interaction.create ~token:42 ~discovery in
  let releases = ref 0 in
  Interaction.cancel cancelled ~release:(fun () -> incr releases);
  Interaction.cancel cancelled ~release:(fun () -> incr releases);
  Interaction.work cancelled ~budget:1;
  Interaction.update cancelled (Paste "late paste");
  Interaction.accept cancelled ~release ~consume;
  assert (!releases = 1 && List.length !received = 1);
  [%expect {| |}]
;;

let%expect_test "new query discards a partially emitted ranking without rebuilding decoded paths" =
  let discovery = snapshot Partial [ "a.ml"; "b.ml"; "c.ml" ] in
  let t = Interaction.create ~token:() ~discovery in
  drain t;
  Interaction.update t (Paste "ml");
  Interaction.work t ~budget:4;
  Interaction.work t ~budget:1;
  assert (Interaction.busy t);
  assert (Model.result_count (Interaction.model t) = 3 && String.is_empty (Model.query (Interaction.model t)));
  Interaction.update t Delete_word;
  Interaction.update t (Paste "b");
  drain t;
  assert (Interaction.prepared_count t = 3);
  assert (List.length (Model.results (Interaction.model t)) = 1);
  assert ([%equal: string option] (selected t) (Some "/project/b.ml"));
  Interaction.update t Backspace;
  drain t;
  Interaction.update t Previous;
  assert ([%equal: string option] (selected t) (Some "/project/a.ml"));
  Interaction.update t Previous;
  assert ([%equal: string option] (selected t) (Some "/project/a.ml"));
  List.iter [ Event.Next; Next; Next; Next ] ~f:(Interaction.update t);
  assert ([%equal: string option] (selected t) (Some "/project/c.ml"));
  [%expect {| |}]
;;
