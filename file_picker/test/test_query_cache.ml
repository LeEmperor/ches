open! Core
open Ches_file_picker
module I = Interaction
module M = Model

let paths = [ "src/z_model.ml"; "b/model.ml"; "a/model.ml"; "src/mode.ml"
            ; "src/other.ml"; "src/模型.ml"; "lib/MODEL99.ml"; "docs/README.md"
            ; "odd/line\nfile.ml"; "tmp/x.ml"; "é/École.ml"; "raw/a\xffb.ml" ]
let snapshot ?(run = 1) paths : M.Discovery.t =
  { request = { run_id = M.Run_id.of_int run; root = "/project" }
  ; candidates = List.map paths ~f:(fun relative_path ->
      M.Candidate.create ~root:"/project" ~relative_path |> Or_error.ok_exn)
  ; status = Partial }
let disabled = { I.Cache_limits.max_entries = 0; max_bytes = 0 }
let drain t =
  let turns = ref 0 in
  while I.busy t do
    incr turns; assert (!turns < 1000);
    let examined = I.scored_count t and indexed = I.indexed_count t in
    I.work t ~budget:2;
    assert (I.scored_count t - examined <= 2 && I.indexed_count t - indexed <= 2)
  done
let set_query t query =
  while not (String.is_empty (I.query t)) do I.update t Delete_word done;
  drain t;
  I.update t (Paste query); drain t
let records t = Sexp.to_string [%sexp (M.results (I.model t) : M.Query_result.t list)]
let assert_equal cached cold discovery =
  [%test_eq: string] (records cached) (records cold);
  [%test_eq: string] (records cached)
    (Sexp.to_string [%sexp (Test_search.oracle (I.query cached) discovery.M.Discovery.candidates : M.Query_result.t list)]);
  [%test_eq: M.Candidate.Id.t option] (M.selected (I.model cached)) (M.selected (I.model cold))

let%test_unit "exact hits/backspace and safe complete-survivor extensions equal cold full ranking and preserve selection" =
  let discovery = snapshot paths in
  let cached = I.create ~token:() ~discovery in
  let cold = I.create_with_cache_limits ~cache_limits:disabled ~token:() ~discovery in
  drain cached; drain cold;
  let step event = I.update cached event; I.update cold event; drain cached; drain cold;
    assert_equal cached cold discovery in
  step (Paste "m"); step (Paste "o");
  let survivors = M.result_count (I.model cached) in
  assert (survivors > 0 && survivors < List.length paths);
  let narrowed = I.narrowed_count cached in
  step (Paste "del");
  assert (I.narrowed_count cached = narrowed + 1 && I.last_examined_count cached = survivors);
  assert (I.last_examined_count cold = List.length paths);
  step Next; step Next;
  step Backspace; (* uncached mode can safely narrow from complete cached mo *)
  step Backspace;
  let hits = I.cache_hits cached and scored = I.scored_count cached and indexed = I.indexed_count cached in
  I.update cached (Paste "el"); I.update cold (Paste "el");
  assert (I.busy cached); (* old query cannot be accepted before one reuse turn *)
  let calls = ref 0 in
  I.accept cached ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
  assert (!calls = 0);
  I.work cached ~budget:1; drain cold;
  assert (not (I.busy cached) && I.cache_hits cached = hits + 1);
  assert (I.scored_count cached = scored && I.indexed_count cached = indexed && I.last_examined_count cached = 0);
  assert_equal cached cold discovery;
  let hits = I.cache_hits cached in
  step Backspace;
  assert (I.cache_hits cached = hits + 1 && I.last_examined_count cached = 0);
  step Backspace;
  assert (I.last_examined_count cached = 0);
  let hits = I.cache_hits cached in
  set_query cached "MODEL "; set_query cold "MODEL "; assert_equal cached cold discovery;
  assert (I.cache_hits cached = hits + 1 && I.last_examined_count cached = 0);
  List.iter [ "model"; "model src"; "model src "; "model s"; "model\tsrc"; "MODEl"
            ; "mXd"; "mo del"; "del mo"; "模"; "模型"; "É"; "é"; "�"; "zzzz"; "zzzzz" ]
    ~f:(fun query -> set_query cached query; set_query cold query; assert_equal cached cold discovery);
  assert (I.cache_bytes cached <= I.Cache_limits.default.max_bytes);
  assert (I.cache_entries cached <= I.Cache_limits.default.max_entries)
;;

let%test_unit "interruption, partial output and candidate replacement cannot provide stale reuse/narrowing sets" =
  let discovery = snapshot paths in
  let t = I.create ~token:() ~discovery in
  drain t; set_query t "mo";
  let narrowed = I.narrowed_count t in
  I.update t (Paste "del"); I.work t ~budget:1;
  assert (I.busy t && I.narrowed_count t = narrowed + 1);
  assert (not (List.mem (I.cache_queries t) "model" ~equal:String.equal));
  let selected = M.selected (I.model t) in
  I.update t Next;
  [%test_eq: M.Candidate.Id.t option] (M.selected (I.model t)) selected;
  let calls = ref 0 in
  I.accept t ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
  assert (!calls = 0);
  I.update t Backspace; (* cancel model mid-score: mode is not yet cached *)
  drain t;
  assert (I.last_examined_count t = List.length paths);
  assert (I.narrowed_count t = narrowed + 1);
  assert (not (List.mem (I.cache_queries t) "model" ~equal:String.equal));
  set_query t "mo";
  I.update t (Paste "del");
  while Poly.equal (I.work_phase t) `Score do I.work t ~budget:1 done;
  I.work t ~budget:1; assert (I.busy t); (* incomplete output is still not cacheable *)
  let entries = I.cache_entries t in
  I.update t (Paste "x"); drain t;
  assert (not (List.mem (I.cache_queries t) "model" ~equal:String.equal));
  assert (I.last_examined_count t = List.length paths);
  assert (I.cache_entries t <= entries + 1);
  let next = snapshot [ "new/model.ml"; "new/mode.ml" ] in
  assert (I.install t next);
  assert (I.cache_entries t = 0 && I.cache_bytes t = 0);
  drain t; set_query t "model";
  let hits = I.cache_hits t in
  assert (I.last_examined_count t = 2 && I.cache_hits t = hits);
  assert (I.install t { next with status = Complete { truncated = false } });
  let entries = I.cache_entries t in
  assert (not (I.install t (snapshot ~run:2 paths)) && I.cache_entries t = entries);
  let replacement = snapshot [ "new/model.ml"; "new/mode.ml" ] in
  assert (I.install t replacement); (* same bytes, NEW immutable list generation *)
  assert (I.cache_entries t = 0); drain t;
  assert (I.last_examined_count t = 2);
  I.cancel t ~release:ignore;
  assert (I.cache_entries t = 0 && I.cache_bytes t = 0);
  let reopened = I.create ~token:() ~discovery:replacement in
  drain reopened; assert (I.cache_entries reopened = 0 && I.prepared_count reopened = 0)
;;

let%test_unit "extensions rescore survivors rather than preserve the old rank order or assign rank ordinals" =
  let discovery = snapshot [ "src/z_model.ml"; "b/model.ml"; "a/model.ml"; "other.txt" ] in
  let t = I.create ~token:() ~discovery in
  drain t; set_query t "model";
  let names () = M.results (I.model t) |> List.map ~f:(fun r -> M.Candidate.relative_path r.M.Query_result.candidate) in
  [%test_eq: string list] (names ()) [ "src/z_model.ml"; "b/model.ml"; "a/model.ml" ];
  I.update t (Paste ".ml"); drain t;
  assert (I.last_examined_count t = 3 && I.narrowed_count t = 1);
  [%test_eq: string list] (names ()) [ "b/model.ml"; "a/model.ml"; "src/z_model.ml" ]
;;

let%test_unit "byte and entry eviction account shared corpus, query/index arrays and future alignment, not only keys" =
  let discovery = snapshot paths in
  let t = I.create_with_cache_limits
    ~cache_limits:{ max_entries = 4; max_bytes = 750 * 1024 } ~token:() ~discovery in
  drain t; set_query t "mo";
  assert (I.cache_entries t = 1 && I.cache_bytes t > 256 * 1024);
  let bytes = I.cache_bytes t in
  ignore (M.results (I.model t) : M.Query_result.t list);
  assert (I.cache_bytes t = bytes); (* alignment growth was reserved up front *)
  set_query t "model";
  assert (I.cache_entries t = 1 && I.cache_evictions t = 1 && I.cache_bytes t <= 750 * 1024);
  let hits = I.cache_hits t in
  set_query t "mo";
  assert (I.cache_hits t = hits && I.last_examined_count t = List.length paths);
  let tiny = I.create_with_cache_limits
    ~cache_limits:{ max_entries = 4; max_bytes = 1024 } ~token:() ~discovery in
  drain tiny; set_query tiny "zzzz";
  assert (I.cache_entries tiny = 0 && I.cache_bytes tiny = 0); (* even empty results own prepared corpus *)
  set_query tiny "zzzzz";
  assert (I.last_examined_count tiny = List.length paths && I.narrowed_count tiny = 0);
  let capped = I.create_with_cache_limits
    ~cache_limits:{ max_entries = 1; max_bytes = 96 * 1024 * 1024 } ~token:() ~discovery in
  drain capped; set_query capped "mo"; set_query capped "model";
  assert (I.cache_entries capped = 1 && I.cache_evictions capped = 1)
;;

let%test_unit "cache hits retain current selection rather than the cached visit's selection, with normal fallback" =
  let discovery = snapshot [ "a/model.ml"; "b/model.ml"; "c/modular.txt"; "x/runner.txt" ] in
  let t = I.create ~token:() ~discovery in
  drain t; set_query t "model";
  let first = M.selected (I.model t) in
  set_query t "mod"; I.update t Next;
  let current = M.selected (I.model t) in
  assert (not (Option.equal M.Candidate.Id.equal first current));
  let hits = I.cache_hits t in
  set_query t "model";
  assert (I.cache_hits t = hits + 1);
  [%test_eq: M.Candidate.Id.t option] (M.selected (I.model t)) current;
  set_query t "runner"; set_query t "model";
  [%test_eq: M.Candidate.Id.t option] (M.selected (I.model t)) first
;;

let%test_unit "a replacement generation's cache/preparation does not retain old candidate objects" =
  let setup () =
    let old = snapshot [ "a/model.ml" ] in
    let t = I.create ~token:() ~discovery:old in
    drain t; set_query t "model";
    let weak = Stdlib.Weak.create 1 in
    Stdlib.Weak.set weak 0 (Some (List.hd_exn old.candidates));
    let current = snapshot [ "a/model.ml" ] in
    assert (I.install t current); drain t;
    t, weak in
  let t, weak = setup () in
  Gc.full_major ();
  assert (Option.is_none (Stdlib.Weak.get weak 0));
  assert (I.cache_entries t = 1);
  assert (String.equal (M.Candidate.relative_path (Option.value_exn (M.selected_candidate (I.model t)))) "a/model.ml")
;;
