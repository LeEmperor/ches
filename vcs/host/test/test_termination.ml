open! Core
open! Async
open Ches_vcs
open Helpers

let first_output events sequence =
  List.find_map events ~f:(function
    | Event.Output { job; line; _ } when job.sequence = sequence -> Some line.text
    | Started _ | Output _ | Finished _ -> None)
;;

let has_output sequence events = Option.is_some (first_output events sequence)

(* Prints its pid (its process group, as the leader), then waits; its background
   grandchild ignores SIGTERM and keeps stdout open, so only SIGKILL to the group ends the
   step. *)
let stubborn = "echo $$; (trap '' TERM; exec sleep 10) & exec sleep 10"

let%expect_test "timeout: SIGTERM to the group, SIGKILL after the grace, nothing left" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let log = new_log () in
      Runner.submit
        runner
        (job 1 [ run (sh ~kind:Read ~cwd:dir ~timeout:(Some (ms 300)) stubborn) ]);
      let%bind () = collect runner log ~until:(fun events -> finished events 1) in
      let result = result log.events 1 ~step:0 in
      print_s
        [%sexp
          { status = (result.status : Exec.Status.t)
          ; timed_out = (result.timed_out : bool)
          ; cancelled = (result.cancelled : bool)
          ; succeeded = (Exec.Result.succeeded result : bool)
          ; cut_at_limit = (Exec.Result.cut_at_limit result : bool)
          ; within_timeout_and_grace =
              (Time_ns.Span.( < ) result.elapsed (Time_ns.Span.of_int_sec 3) : bool)
          }];
      [%expect
        {|
        ((status (Signaled sigterm)) (timed_out true) (cancelled false)
         (succeeded false) (cut_at_limit false) (within_timeout_and_grace true))
        |}];
      let%map alive = group_alive (Int.of_string (String.strip result.stdout)) in
      print_s [%sexp { group_alive = (alive : bool) }];
      [%expect {| ((group_alive false)) |}]))
;;

let%expect_test "cancel a running mutation and a queued one" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let log = new_log () in
      Runner.submit
        runner
        (job
           1
           [ run (sh ~cwd:dir ~stream:true "echo $$; exec sleep 10")
           ; run (sh ~cwd:dir "echo after")
           ]);
      Runner.submit runner (job 2 [ run (sh ~cwd:dir "echo queued") ]);
      Runner.submit runner (job 3 [ run (sh ~cwd:dir "echo third") ]);
      let%bind () = collect runner log ~until:(has_output 1) in
      let pgid = Int.of_string (Option.value_exn (first_output log.events 1)) in
      (* Queued: reported at once as never started. *)
      Runner.cancel runner (id 2);
      print_events (Runner.poll runner);
      [%expect {| (finished g1.2 cancelled skipped) |}];
      Runner.cancel runner (id 1);
      (* Unknown and already finished ids are ignored. *)
      Runner.cancel runner (id 2);
      Runner.cancel runner (id 99);
      let%bind () = collect runner log ~until:(all_finished [ 1; 3 ]) in
      List.iter
        (of_job log.events 1 @ of_job log.events 3)
        ~f:(fun event ->
          print_endline
            (String.substr_replace_all
               (Sexp.to_string_hum (event_sexp event))
               ~pattern:(Int.to_string pgid)
               ~with_:"<pid>"));
      [%expect
        {|
        (started g1.1 0 "/bin/sh -c 'echo $$; exec sleep 10'")
        (output g1.1 0 Stdout <pid> line)
        (finished g1.1 cancelled (ran (cancelled (stdout "<pid>\n") cancelled))
         skipped)
        (started g1.3 0 "/bin/sh -c 'echo third'")
        (finished g1.3 complete (ran ("exit 0" (stdout "third\n"))))
        |}];
      let%map alive = group_alive pgid in
      print_s [%sexp { group_alive = (alive : bool); busy = (Runner.busy runner : bool) }];
      [%expect {| ((group_alive false) (busy false)) |}]))
;;

let%expect_test "stop with work in flight: children reaped, no more events" =
  with_dir (fun dir ->
    let runner = Runner.create ~config:test_config () in
    let log = new_log () in
    Runner.submit
      runner
      (job 1 [ run (sh ~cwd:dir ~stream:true "echo $$; exec sleep 10") ]);
    Runner.submit runner (job 2 [ run (sh ~cwd:dir "echo queued") ]);
    Runner.submit
      runner
      (job 3 [ run (sh ~kind:Read ~cwd:dir ~stream:true "echo $$; exec sleep 10") ]);
    let%bind () =
      collect runner log ~until:(fun events -> has_output 1 events && has_output 3 events)
    in
    let pgids =
      List.map [ 1; 3 ] ~f:(fun sequence ->
        Int.of_string (Option.value_exn (first_output log.events sequence)))
    in
    print_s [%sexp { busy = (Runner.busy runner : bool) }];
    [%expect {| ((busy true)) |}];
    let next = Runner.next_batch runner in
    Runner.stop runner;
    Runner.stop runner;
    Runner.submit runner (job 4 [ run (sh ~cwd:dir "echo after stop") ]);
    let%bind () = within (Runner.finished runner) in
    let%bind alive =
      Deferred.List.map ~how:`Sequential pgids ~f:(fun pgid -> group_alive pgid)
    in
    let%map late = Clock_ns.with_timeout (ms 100) next in
    print_s
      [%sexp
        { busy = (Runner.busy runner : bool)
        ; poll = (Runner.poll runner : Event.t list)
        ; next_batch_determined =
            ((match late with
              | `Result _ -> true
              | `Timeout -> false)
             : bool)
        ; groups_alive = (alive : bool list)
        }];
    [%expect
      {|
      ((busy false) (poll ()) (next_batch_determined false)
       (groups_alive (false false)))
      |}])
;;

let%expect_test "streaming: carriage-return progress is transient" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let _ : string = gate dir "gate" in
      let log = new_log () in
      Runner.submit
        runner
        (job
           1
           [ run
               (sh
                  ~cwd:dir
                  ~stream:true
                  (String.concat
                     [ {|printf 'Receiving objects:  50%%\r'; read line < gate; |}
                     ; {|printf 'Receiving objects: 100%%\r|}
                     ; {|Receiving objects: 100%%, done.\r\nTo origin'; |}
                     ; {|printf 'remote: one\nremote: two' >&2|}
                     ]))
           ]);
      (* The first progress line arrives while the child runs. *)
      let%bind () = collect runner log ~until:(has_output 1) in
      Runner.submit runner (job 2 [ run (sh ~kind:Read ~cwd:dir "echo go > gate") ]);
      let%map () = settle runner log in
      print_events
        ~dir
        (List.filter (of_job log.events 1) ~f:(function
          | Started _ -> false
          | Output _ | Finished _ -> true));
      (* The pending "100%" and the transient copy of the CRLF line were replaced before
         they were taken; the stderr lines are a stream of their own. *)
      [%expect
        {|
        (output g1.1 0 Stdout "Receiving objects:  50%" transient)
        (output g1.1 0 Stdout "Receiving objects: 100%, done." line)
        (output g1.1 0 Stdout "To origin" line)
        (output g1.1 0 Stderr "remote: one" line)
        (output g1.1 0 Stderr "remote: two" line)
        (finished g1.1 complete
         (ran
          ("exit 0"
           (stdout
             "Receiving objects:  50%\rReceiving objects: 100%\rReceiving objects: 100%, done.\r\
            \nTo origin")
           (stderr  "remote: one\
                   \nremote: two"))))
        |}]))
;;
