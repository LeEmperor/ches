open! Core
open! Async
open Ches_file_discovery
module Model = Ches_file_picker.Model
module Candidate = Model.Candidate
module Discovery = Model.Discovery

let fake_rg = Filename_unix.realpath "fake_rg/fake_rg.exe"
let temp () = Filename_unix.realpath (Filename_unix.temp_dir "ches-picker" "")
let write root path data =
  let path = Filename.concat root path in
  Core_unix.mkdir_p (Filename.dirname path);
  Out_channel.write_all path ~data
;;

(* Clean only each test's newly allocated tree, including its deliberately odd
   filenames. Do not follow directory symlinks out of the fixture. *)
let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Array.iter (Sys_unix.readdir path) ~f:(fun name -> remove (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let with_root f =
  let root = temp () in
  Monitor.protect (fun () -> f root) ~finally:(fun () -> remove root; return ())
;;

let pause () = Clock_ns.after (Time_ns.Span.of_int_ms 1)
let timeout deferred =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) deferred with
  | `Result result -> result
  | `Timeout -> failwith "file discovery test timed out"
;;

let rec complete provider =
  ignore (Provider.poll provider ~max_batches:1 : Discovery.t option);
  let snapshot = Option.value_exn (Provider.snapshot provider) in
  match snapshot.status with
  | Loading | Partial -> let%bind () = pause () in complete provider
  | Complete _ | Failed _ | Cancelled -> return snapshot
;;

let run ?prog ?limits root =
  let provider = Provider.create ?prog ?limits () in
  let run = Provider.start provider ~root |> Or_error.ok_exn in
  let%bind snapshot = timeout (complete provider) in
  let%map () = timeout (Provider.finished run) in
  snapshot
;;

let paths snapshot = List.map snapshot.Discovery.candidates ~f:Candidate.relative_path
let is_complete snapshot ~truncated =
  assert (Discovery.equal_status snapshot.Discovery.status (Complete { truncated }))
;;

let%expect_test "nearest project marker, worktree file, canonicalization and fallback" =
  with_root (fun root ->
    write root "outer/.git/config" "";
    write root "outer/nested/dune-project" "";
    write root "outer/nested/deep/main.ml" "";
    [%test_eq: string] (Project_root.find (root ^ "/outer/nested/deep/main.ml"))
      (root ^ "/outer/nested");
    write root "outer/nested/deep/.git" "gitdir: somewhere";
    [%test_eq: string] (Project_root.find (root ^ "/outer/nested/deep/main.ml"))
      (root ^ "/outer/nested/deep");
    Core_unix.mkdir_p (root ^ "/loose/deep");
    [%test_eq: string] (Project_root.find (root ^ "/loose/deep/missing.ml"))
      (root ^ "/loose/deep");
    [%test_eq: string] (Project_root.find (root ^ "/absent/missing.ml")) (root ^ "/absent");
    Core_unix.symlink ~target:(root ^ "/outer/nested/deep") ~link_name:(root ^ "/alias");
    [%test_eq: string] (Project_root.find (root ^ "/alias/main.ml")) (root ^ "/outer/nested/deep");
    return ())
;;

let%expect_test "real rg includes untracked, respects ignores, omits hidden and directory symlinks" =
  with_root (fun root ->
    write root ".git/config" "";
    write root ".gitignore" "ignored.txt\nignored-dir/\n";
    write root ".ignore" "local-ignore.txt\n";
    List.iter [ "untracked.ml"; "space name"; "line\nbreak"; "bad\255"; "sub/main.ml"
              ; "ignored.txt"; "ignored-dir/a"; "local-ignore.txt"; ".hidden"; ".secret/a" ]
      ~f:(fun path -> write root path "");
    Core_unix.symlink ~target:(root ^ "/sub") ~link_name:(root ^ "/alias");
    let%map snapshot = run root in
    is_complete snapshot ~truncated:false;
    [%test_eq: string list] (paths snapshot)
      [ "bad\255"; "line\nbreak"; "space name"; "sub/main.ml"; "untracked.ml" ];
    List.iter snapshot.candidates ~f:(fun candidate ->
      [%test_eq: string] (Candidate.path candidate) (root ^ "/" ^ Candidate.relative_path candidate);
      assert (Stdlib.String.is_valid_utf_8 (Candidate.display_path candidate))))
;;

let%expect_test "empty rg project and empty exit code are complete not failed" =
  with_root (fun root ->
    let%bind snapshot = run root in
    is_complete snapshot ~truncated:false;
    assert (List.is_empty snapshot.candidates);
    write root "mode" "empty";
    let%map snapshot = run ~prog:fake_rg root in
    is_complete snapshot ~truncated:false;
    assert (List.is_empty snapshot.candidates))
;;

let%expect_test "NUL path spanning reader buffers retains bytes and strips only rg dot prefix" =
  with_root (fun root ->
    write root "mode" "fragmented";
    let limits = { Provider.Limits.default with max_path_bytes = 8192 } in
    let%map snapshot = run ~prog:fake_rg ~limits root in
    is_complete snapshot ~truncated:false;
    [%test_eq: string list] (paths snapshot)
      [ "dir/" ^ String.make 3000 'a' ^ "/" ^ String.make 3000 'b' ^ "\n\255" ])
;;

let%expect_test "bounded batches, deduplication, ordering and raw bytes" =
  with_root (fun root ->
    write root "mode" "ordered";
    let limits = { Provider.Limits.default with batch_size = 1 } in
    let provider = Provider.create ~prog:fake_rg ~limits () in
    let run = Provider.start provider ~root |> Or_error.ok_exn in
    assert (Discovery.equal_status (Option.value_exn (Provider.snapshot provider)).status Loading);
    let rec first () =
      match Provider.poll provider ~max_batches:1 with
      | None -> let%bind () = pause () in first ()
      | Some snapshot -> return snapshot
    in
    let%bind first = timeout (first ()) in
    [%test_eq: string list] (paths first) [ "z" ];
    assert (Discovery.equal_status first.status Partial);
    let result candidate : Model.Query_result.t = { candidate; score = 0; positions = [] } in
    let model = Model.create ~token:() ~discovery:first in
    let model = Model.with_results model ~query:"" (List.map first.candidates ~f:result) in
    let selected = Model.selected model in
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
    assert (not (Deferred.is_determined (Provider.finished run)));
    let%bind snapshot = timeout (complete provider) in
    let%map () = timeout (Provider.finished run) in
    is_complete snapshot ~truncated:false;
    [%test_eq: string list] (paths snapshot) [ "a\n\255"; "a/main.ml"; "b/main.ml"; "z" ];
    let model = Model.with_results model ~query:"" (List.map snapshot.candidates ~f:result) in
    [%test_eq: Candidate.Id.t option] (Model.selected model) selected)
;;

let%expect_test "terminal-only delivery preserves candidates and does not reschedule filtering" =
  with_root (fun root ->
    write root "mode" "ordered";
    let limits = { Provider.Limits.default with batch_size = 1 } in
    let provider = Provider.create ~prog:fake_rg ~limits () in
    let run = Provider.start provider ~root |> Or_error.ok_exn in
    let session = Ches_file_picker.Interaction.create ~token:()
      ~discovery:(Option.value_exn (Provider.snapshot provider)) in
    let rec drain () =
      if Ches_file_picker.Interaction.busy session then (
        Ches_file_picker.Interaction.work session ~budget:8;
        drain ())
    in
    drain ();
    let rec poll previous =
      match Provider.poll provider ~max_batches:1 with
      | None -> let%bind () = pause () in poll previous
      | Some snapshot ->
        assert (Ches_file_picker.Interaction.install session snapshot);
        (match snapshot.status with
         | Complete _ ->
           assert (phys_equal previous.Discovery.candidates snapshot.candidates);
           assert (not (Ches_file_picker.Interaction.busy session));
           return ()
         | Partial -> drain (); poll snapshot
         | _ -> assert false)
    in
    let%bind () = timeout (poll (Option.value_exn (Provider.snapshot provider))) in
    timeout (Provider.finished run))
;;

let%expect_test "failures are actionable bounded safe messages and retain partial results" =
  with_root (fun root ->
    let%bind missing = run ~prog:"/no-such-ches-rg" root in
    (match missing.status with
     | Failed message -> assert (String.is_substring message ~substring:"Install ripgrep")
     | _ -> assert false);
    let%bind bad_root = run ~prog:fake_rg (root ^ "/does-not-exist") in
    (match bad_root.status with Failed _ -> () | _ -> assert false);
    write root "mode" "partial-failure";
    let%bind failed = run ~prog:fake_rg root in
    [%test_eq: string list] (paths failed) [ "before" ];
    (match failed.status with
     | Failed message ->
       assert (String.length message < 34_000);
       assert (not (String.exists message ~f:(fun c -> Char.to_int c < 32)))
     | _ -> assert false);
    Deferred.List.iter ~how:`Sequential [ "missing-nul"; "invalid" ] ~f:(fun mode ->
      write root "mode" mode;
      let%map snapshot = run ~prog:fake_rg root in
      match snapshot.status with Failed _ -> () | _ -> assert false))
;;

let%expect_test "count path retained-byte and stream-byte limits disclose truncation" =
  with_root (fun root ->
    let cases =
      [ "ordered", { Provider.Limits.default with max_candidates = 2 }
      ; "ordered", { Provider.Limits.default with
          max_total_path_bytes = (2 * String.length root) + 6 }
      ; "long", { Provider.Limits.default with max_path_bytes = 8 }
      ; "duplicates", { Provider.Limits.default with max_output_bytes = 32 }
      ]
    in
    Deferred.List.iter ~how:`Sequential cases ~f:(fun (mode, limits) ->
      write root "mode" mode;
      let%map snapshot = run ~prog:fake_rg ~limits root in
      is_complete snapshot ~truncated:true;
      assert (List.length snapshot.candidates <= limits.max_candidates);
      let payload = List.sum (module Int) snapshot.candidates ~f:(fun candidate ->
        String.length (Candidate.root candidate) + String.length (Candidate.path candidate)
        + String.length (Candidate.relative_path candidate)
        + String.length (Candidate.display_path candidate))
      in
      assert (payload <= limits.max_total_path_bytes);
      if limits.max_total_path_bytes <> Provider.Limits.default.max_total_path_bytes
      then [%test_eq: string list] (paths snapshot) [ "z" ]))
;;

let%expect_test "invalid request preserves active run; roots normalize and limits validate" =
  with_root (fun root ->
    write root "mode" "ordered";
    let provider = Provider.create ~prog:fake_rg () in
    let current = Provider.start provider ~root:(root ^ "///") |> Or_error.ok_exn in
    [%test_eq: string] (Provider.request current).root root;
    List.iter [ "relative"; "/nul\000root"; "/" ^ String.make 4096 'a' ] ~f:(fun invalid ->
      assert (Or_error.is_error (Provider.start provider ~root:invalid)));
    let%bind snapshot = timeout (complete provider) in
    assert (Model.Run_id.equal snapshot.request.run_id (Provider.request current).run_id);
    let%map () = timeout (Provider.finished current) in
    match Provider.create ~limits:{ Provider.Limits.default with batch_size = 0 } () with
    | exception Invalid_argument _ -> ()
    | _ -> assert false)
;;

let wait_pid root =
  let rec loop () =
    if Sys_unix.file_exists_exn (root ^ "/pid") then return ()
    else let%bind () = pause () in loop ()
  in
  timeout (loop ())
;;

let assert_reaped root =
  let pid = In_channel.read_all (root ^ "/pid") |> String.strip |> Pid.of_string in
  (* A reaped direct child is no longer ours to wait for. *)
  match Core_unix.wait_nohang (`Pid pid) with
  | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
  | _ -> failwith "discovery child was not reaped"
;;

let%expect_test "cancel reaps blocked subprocess and rejects stale batches on reopen/root change" =
  with_root (fun root ->
    with_root (fun other ->
      write root "mode" "pushback";
      write other "mode" "ordered";
      let limits = { Provider.Limits.default with batch_size = 1 } in
      let provider = Provider.create ~prog:fake_rg ~limits () in
      let old = Provider.start provider ~root |> Or_error.ok_exn in
      let%bind () = wait_pid root in
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
      Provider.cancel provider;
      assert (Discovery.equal_status (Option.value_exn (Provider.snapshot provider)).status Cancelled);
      let fresh = Provider.start provider ~root:other |> Or_error.ok_exn in
      assert (not (Model.Run_id.equal (Provider.request old).run_id (Provider.request fresh).run_id));
      let%bind () = timeout (Provider.finished old) in
      assert_reaped root;
      let%bind snapshot = timeout (complete provider) in
      let%bind () = timeout (Provider.finished fresh) in
      [%test_eq: string] snapshot.request.root other;
      [%test_eq: string list] (paths snapshot) [ "a\n\255"; "a/main.ml"; "b/main.ml"; "z" ];
      (* Cancel during process creation; only the newest request may deliver. *)
      let abandoned = Provider.start provider ~root |> Or_error.ok_exn in
      let newest = Provider.start provider ~root:other |> Or_error.ok_exn in
      let%bind () = timeout (Provider.finished abandoned) in
      let%bind snapshot = timeout (complete provider) in
      let%map () = timeout (Provider.finished newest) in
      assert (Model.Run_id.equal snapshot.request.run_id (Provider.request newest).run_id)))
;;

let%expect_test "timeout bounds stalled children and delivery backpressure without polling" =
  with_root (fun root ->
    Deferred.List.iter ~how:`Sequential [ "stall"; "pushback" ] ~f:(fun mode ->
      write root "mode" mode;
      let limits =
        { Provider.Limits.default with batch_size = 1; timeout = Time_ns.Span.of_int_ms 100 }
      in
      let provider = Provider.create ~prog:fake_rg ~limits () in
      let run = Provider.start provider ~root |> Or_error.ok_exn in
      let%bind () = timeout (Provider.finished run) in
      assert_reaped root;
      let%map snapshot = timeout (complete provider) in
      match snapshot.status with
      | Failed message -> assert (String.is_substring message ~substring:"timed out")
      | _ -> assert false))
;;
