open! Core
open! Async
open Ches_screen
module R = Ches_file_picker_host.Runtime
module I = Ches_file_picker.Interaction
module M = Ches_file_picker.Model
let width = 100 and height = 30
let ui () = Ui_state.create (Ches_app.Controller.create
  (Ches_core.Editor.create ~cell_width:Cell_map.width Ches_core.Text_buffer.empty))
let apply ui inputs = fst (Ui_state.apply_all ui ~width ~height inputs)
let session ui = File_picker_tile.session (Option.value_exn (Ui_state.file_picker ui))
let timeout d = match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) d with
  | `Result v -> v | `Timeout -> failwith "reopen test timeout"
let drain runtime state = timeout (R.pump runtime ~current:(fun () -> !state)
  ~inject:(fun inputs -> state := apply !state inputs; return ()))
let close state = state := apply !state [ Key Escape ]
let query state text = String.iter text ~f:(fun c -> state := apply !state [ Key (Ches_input.Key.char c) ])
let remove root = Array.iter (Sys_unix.readdir root) ~f:(fun path -> Core_unix.unlink (root ^ "/" ^ path)); Core_unix.rmdir root
let with_root f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-reopen" "") in
  Out_channel.write_all (root ^ "/a.ml") ~data:"alpha\n";
  Out_channel.write_all (root ^ "/b.ml") ~data:"beta\n";
  Monitor.protect (fun () -> f root) ~finally:(fun () -> remove root; return ())
let open_picker r state root = state := R.open_picker r !state ~root ~width ~height |> Or_error.ok_exn
let names state = M.results (I.model (session !state)) |> List.map ~f:(fun r -> M.Candidate.relative_path r.M.Query_result.candidate)

let%expect_test "runtime reopen instantly reuses blank/preparation/query data, then validates and commits deletions" =
  with_root (fun root ->
    let runtime = R.create () and state = ref (ui ()) in
    open_picker runtime state root; let%bind () = drain runtime state in
    query state "a"; let%bind () = drain runtime state in
    let old = session !state in
    let old_request = M.discovery_request (I.model old) in
    let old_candidate = Option.value_exn (M.selected_candidate (I.model old)) in
    close state; let%bind () = timeout (R.finished runtime) in
    assert (R.cache_entries runtime = 1);
    open_picker runtime state root;
    let replacement = session !state in
    assert (R.cache_hits runtime = 1 && M.result_count (I.model replacement) = 2);
    assert (String.is_empty (I.query replacement)); (* original blank/first selection UX *)
    assert (I.acceptance_blocked replacement && I.refreshing replacement && I.indexed_count replacement = 0);
    let ignored = ref 0 in
    I.accept replacement ~release:(fun () -> incr ignored) ~consume:(fun _ -> incr ignored);
    assert (!ignored = 0);
    assert (String.is_substring (Frame.to_string (Frame.render !state ~width ~height)) ~substring:"Loading / refreshing");
    state := apply !state [ File_picker_work old_request ];
    assert (I.indexed_count replacement = 0);
    let%bind () = drain runtime state in
    assert (not (I.acceptance_blocked replacement));
    assert (I.indexed_count replacement = 0 && I.prepared_count replacement = 0);
    assert (phys_equal old_candidate (Option.value_exn (M.selected_candidate (I.model replacement))));
    query state "a"; let%bind () = drain runtime state in
    assert (I.cache_hits replacement = 1 && I.scored_count replacement = 0);
    close state; let%bind () = timeout (R.finished runtime) in
    Core_unix.unlink (root ^ "/b.ml"); Out_channel.write_all (root ^ "/c.ml") ~data:"new\n";
    open_picker runtime state root;
    assert (List.mem (names state) "b.ml" ~equal:String.equal);
    let%bind () = drain runtime state in
    [%test_eq: string list] (names state) [ "a.ml"; "c.ml" ];
    query state "ml"; let%bind () = drain runtime state in
    assert (I.prepared_count (session !state) = 1); (* only c needs preparation *)
    close state; let%map () = timeout (R.finished runtime) in
    R.cancel runtime; assert (R.cache_entries runtime = 0))
;;

let%expect_test "TTL, root/config policy and byte limits bound runtime data independently of child cleanup" =
  with_root (fun root ->
    let now = ref Time_ns.epoch in
    let runtime = R.create ~now:(fun () -> !now)
      ~cache_limits:{ max_roots = 1; max_bytes = 128 * 1024 * 1024; ttl = Time_ns.Span.of_int_sec 5 } () in
    let state = ref (ui ()) in
    open_picker runtime state root; let%bind () = drain runtime state in
    close state; let%bind () = timeout (R.finished runtime) in
    now := Time_ns.add !now (Time_ns.Span.of_int_sec 6);
    assert (R.cache_entries runtime = 0);
    open_picker runtime state root; assert (R.cache_hits runtime = 0);
    let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    state := R.open_picker_with_policy runtime !state ~root ~policy:"changed-discovery-config" ~width ~height |> Or_error.ok_exn;
    assert (R.cache_hits runtime = 0);
    let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    let tiny = R.create ~cache_limits:{ R.Cache_limits.default with max_bytes = 1 } () in
    open_picker tiny state root; let%bind () = drain tiny state in close state;
    let%map () = timeout (R.finished tiny) in
    assert (R.cache_entries tiny = 0 && R.cache_bytes tiny = 0);
    R.cancel tiny; R.cancel runtime)
;;

let%expect_test "ignore-rule refresh prunes old names and a cancelled refresh cannot export cancellation state" =
  with_root (fun root ->
    let runtime = R.create () and state = ref (ui ()) in
    open_picker runtime state root; let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    open_picker runtime state root; assert (I.refreshing (session !state));
    close state; let%bind () = timeout (R.finished runtime) in
    assert (R.cache_entries runtime = 1);
    Out_channel.write_all (root ^ "/.ignore") ~data:"b.ml\n";
    open_picker runtime state root; let%bind () = drain runtime state in
    [%test_eq: string list] (names state) [ "a.ml" ];
    close state; let%map () = timeout (R.finished runtime) in R.cancel runtime)
;;

let%expect_test "failed and truncated cached refreshes are explicit, nonaccepting and not retained" =
  with_root (fun root ->
    Out_channel.write_all (root ^ "/mode") ~data:"ordered";
    let fake = Filename_unix.realpath "fake_rg/fake_rg.exe" in
    let runtime = R.create ~prog:fake () and state = ref (ui ()) in
    open_picker runtime state root; let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    Out_channel.write_all (root ^ "/mode") ~data:"partial-failure";
    open_picker runtime state root; let%bind () = drain runtime state in
    assert (I.acceptance_blocked (session !state) && R.cache_entries runtime = 0);
    assert (String.is_substring (Frame.to_string (Frame.render !state ~width ~height)) ~substring:"Refresh failed");
    let calls = ref 0 in
    I.accept (session !state) ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
    assert (!calls = 0);
    close state; let%map () = timeout (R.finished runtime) in R.cancel runtime)
  >>= fun () ->
  with_root (fun root ->
    let runtime = R.create ~limits:{ Ches_file_discovery.Provider.Limits.default with max_candidates = 2 } () in
    let state = ref (ui ()) in
    open_picker runtime state root; let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    Out_channel.write_all (root ^ "/c.ml") ~data:"third";
    open_picker runtime state root; let%bind () = drain runtime state in
    assert (M.Discovery.equal_status (M.discovery_status (I.model (session !state))) (Complete { truncated = true }));
    assert (I.acceptance_blocked (session !state) && R.cache_entries runtime = 0);
    close state; let%map () = timeout (R.finished runtime) in R.cancel runtime)
;;

let%expect_test "root cap evicts data, and cached data has no reference to the retired UI/session" =
  with_root (fun first -> with_root (fun second ->
    let runtime = R.create ~cache_limits:{ R.Cache_limits.default with max_roots = 1 } () in
    let state = ref (ui ()) in
    open_picker runtime state first; let%bind () = drain runtime state in
    let weak = Stdlib.Weak.create 1 in
    Stdlib.Weak.set weak 0 (Some (session !state));
    close state; let%bind () = timeout (R.finished runtime) in
    Gc.full_major ();
    assert (Option.is_none (Stdlib.Weak.get weak 0) && R.cache_entries runtime = 1);
    open_picker runtime state second; assert (R.cache_hits runtime = 0);
    let%bind () = drain runtime state in close state;
    let%bind () = timeout (R.finished runtime) in
    assert (R.cache_entries runtime = 1 && R.cache_evictions runtime = 1);
    open_picker runtime state first; assert (R.cache_hits runtime = 0);
    let%bind () = drain runtime state in close state;
    let%map () = timeout (R.finished runtime) in R.cancel runtime))
;;
