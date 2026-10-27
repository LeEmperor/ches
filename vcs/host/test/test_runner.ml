open! Core
open! Async
open Ches_vcs
open Helpers

let%expect_test "a multi-step mutation stops at its first failure; a read runs every step"
  =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let log = new_log () in
      Runner.submit
        runner
        (job
           1
           [ run (sh ~cwd:dir ~stream:true "echo one; echo oops >&2")
           ; run (sh ~cwd:dir "echo partial; exit 3")
           ; run (sh ~cwd:dir "echo never")
           ; Read_file { path = dir ^/ "absent"; limit = 10 }
           ]);
      let%bind () = collect runner log ~until:(fun events -> finished events 1) in
      print_events log.events;
      [%expect
        {|
        (started g1.1 0 "/bin/sh -c 'echo one; echo oops >&2'")
        (output g1.1 0 Stdout one line)
        (output g1.1 0 Stderr oops line)
        (started g1.1 1 "/bin/sh -c 'echo partial; exit 3'")
        (finished g1.1 complete (ran ("exit 0" (stdout "one\n") (stderr "oops\n")))
         (ran ("exit 3" (stdout "partial\n"))) skipped skipped)
        |}];
      let report = report log.events 1 in
      print_s
        [%sexp
          { succeeded = (Job.Report.succeeded report : bool)
          ; kind = (report.kind : Exec.Kind.t)
          ; first_failure =
              (Option.map (Job.Report.first_failure report) ~f:(fun step ->
                 Exec.Spec.to_string_hum
                   (match step.step with
                    | Run spec -> spec
                    | Read_file _ -> assert false))
               : string option)
          }];
      [%expect
        {|
        ((succeeded false) (kind Mutate)
         (first_failure ("/bin/sh -c 'echo partial; exit 3'")))
        |}];
      (* A read job: the failing first step does not stop the others. *)
      let log = new_log () in
      Runner.submit
        runner
        (job
           2
           [ run (sh ~kind:Read ~cwd:dir "exit 3")
           ; run (sh ~kind:Read ~cwd:dir "echo two")
           ; Read_file { path = dir ^/ "absent"; limit = 10 }
           ]);
      let%map () = collect runner log ~until:(fun events -> finished events 2) in
      print_events
        (List.filter log.events ~f:(function
          | Finished _ -> true
          | Started _ | Output _ -> false));
      [%expect
        {|
        (finished g1.2 complete (ran ("exit 3")) (ran ("exit 0" (stdout "two\n")))
         (read Missing))
        |}];
      print_s [%sexp (Runner.busy runner : bool)];
      [%expect {| false |}]))
;;

let%expect_test "reads run alongside a mutation; mutations run one at a time" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let _ : string = gate dir "gate" in
      let log = new_log () in
      (* 1 holds the mutation queue until something writes to the gate. *)
      Runner.submit
        runner
        (job 1 [ run (sh ~cwd:dir "read line < gate; echo got $line") ]);
      Runner.submit runner (job 2 [ run (sh ~cwd:dir "echo second") ]);
      Runner.submit runner (job 3 [ run (sh ~kind:Read ~cwd:dir "echo read") ]);
      print_s [%sexp (Runner.busy runner : bool)];
      [%expect {| true |}];
      let%bind () = collect runner log ~until:(fun events -> finished events 3) in
      (* The read finished while mutation 1 still runs, and 2 has not started. *)
      print_events (of_job log.events 1);
      print_events (of_job log.events 2);
      [%expect {| (started g1.1 0 "/bin/sh -c 'read line < gate; echo got $line'") |}];
      (* A read opens the gate. *)
      Runner.submit runner (job 4 [ run (sh ~kind:Read ~cwd:dir "echo go > gate") ]);
      let%map () = collect runner log ~until:(all_finished [ 1; 2; 4 ]) in
      print_events (of_job log.events 1);
      print_events (of_job log.events 2);
      [%expect
        {|
        (started g1.1 0 "/bin/sh -c 'read line < gate; echo got $line'")
        (finished g1.1 complete (ran ("exit 0" (stdout "got go\n"))))
        (started g1.2 0 "/bin/sh -c 'echo second'")
        (finished g1.2 complete (ran ("exit 0" (stdout "second\n"))))
        |}];
      print_s
        [%sexp
          { read_before_mutation =
              (finished_at log.events 3 < finished_at log.events 1 : bool)
          ; second_after_first =
              (finished_at log.events 1 < started_at log.events 2 : bool)
          ; busy = (Runner.busy runner : bool)
          }];
      [%expect {| ((read_before_mutation true) (second_after_first true) (busy false)) |}]))
;;

let%expect_test "read slots bound concurrent read children" =
  with_dir (fun dir ->
    (* Step 0 waits on the gate that step 1 opens: possible only with two slots. *)
    let gated_job sequence =
      job
        sequence
        [ run (sh ~kind:Read ~timeout:(Some (ms 300)) ~cwd:dir "read line < gate")
        ; run (sh ~kind:Read ~timeout:(Some (ms 300)) ~cwd:dir "echo go > gate")
        ]
    in
    let _ : string = gate dir "gate" in
    let attempt max_concurrent_reads =
      with_runner ~config:{ test_config with max_concurrent_reads } (fun runner ->
        let log = new_log () in
        Runner.submit runner (gated_job 1);
        let%map () = collect runner log ~until:(fun events -> finished events 1) in
        print_events
          (of_job log.events 1
           |> List.filter ~f:(function
             | Finished _ -> true
             | Started _ | Output _ -> false)))
    in
    let%bind () = attempt 2 in
    [%expect {| (finished g1.1 complete (ran ("exit 0")) (ran ("exit 0"))) |}];
    let%map () = attempt 1 in
    [%expect
      {|
      (finished g1.1 complete (ran ("timed out" timed_out))
       (ran ("timed out" timed_out)))
      |}])
;;

let%expect_test "lanes supersede earlier reads; a reused id is never started" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let log = new_log () in
      let slow = sh ~kind:Read ~cwd:dir "exec sleep 5" in
      Runner.submit runner (job ~lane:"diff" 1 [ run slow ]);
      let%bind () =
        collect
          runner
          log
          ~until:
            (List.exists ~f:(function
              | Event.Started _ -> true
              | Output _ | Finished _ -> false))
      in
      Runner.submit
        runner
        (job ~lane:"diff" 2 [ run (sh ~kind:Read ~cwd:dir "echo new") ]);
      Runner.submit runner (job 1 [ run (sh ~cwd:dir "echo duplicate") ]);
      let%map () =
        collect runner log ~until:(fun events ->
          List.count events ~f:(function
            | Finished _ -> true
            | Started _ | Output _ -> false)
          = 3)
      in
      (* Per job: whether 2 or the superseded 1 finishes first is a race. *)
      print_events
        (List.filter
           (of_job log.events 1 @ of_job log.events 2)
           ~f:(function
             | Finished _ -> true
             | Started _ | Output _ -> false));
      [%expect
        {|
        (finished g1.1 cancelled skipped)
        (finished g1.1 cancelled (ran (cancelled cancelled)))
        (finished g1.2 complete (ran ("exit 0" (stdout "new\n"))))
        |}]))
;;

let%expect_test "batches hold at most max_batch events, oldest first" =
  with_dir (fun dir ->
    with_runner ~config:{ test_config with max_batch = 2 } (fun runner ->
      Runner.submit
        runner
        (job 1 [ run (sh ~cwd:dir ~stream:true "printf 'a\\nb\\nc\\n'") ]);
      let%bind () = within (idle runner) in
      let rec batches () =
        match Runner.poll runner with
        | [] -> []
        | batch -> batch :: batches ()
      in
      List.iter (batches ()) ~f:(fun batch ->
        print_endline "batch:";
        print_events batch);
      [%expect
        {|
          batch:
          (started g1.1 0 "/bin/sh -c 'printf '\\''a\\nb\\nc\\n'\\'''")
          (output g1.1 0 Stdout a line)
          batch:
          (output g1.1 0 Stdout b line)
          (output g1.1 0 Stdout c line)
          batch:
          (finished g1.1 complete (ran ("exit 0" (stdout  "a\
                                                         \nb\
                                                         \nc\
                                                         \n"))))
          |}];
      (* Nothing pending: [next_batch] waits for the next event. *)
      let next = Runner.next_batch runner in
      print_s [%sexp (Deferred.is_determined next : bool)];
      Runner.submit runner (job 2 [ run (sh ~cwd:dir "true") ]);
      let%map batch = within next in
      print_events batch;
      [%expect
        {|
          false
          (started g1.2 0 "/bin/sh -c true")
          |}]))
;;
