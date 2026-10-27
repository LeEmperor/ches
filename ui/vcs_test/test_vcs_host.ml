(* Vcs_host against a real runner: jobs from the git backend in a fixture repository,
   and small /bin/sh children where a test needs a slow or stubborn one. Every host is
   shut down and every fixture removed, even when a test fails; a deadline fails a
   test instead of hanging it. Paths under the fixture print as $DIR. *)

open! Core
open! Async
open Ches_vcs
module Vcs_host = Ches_ui.Vcs_host
module Input = Ches_screen.Ui_state.Input
module Fixture = Ches_vcs_fixture.Fixture_repo
module B = Ches_vcs_git.Backend

let ms = Time_ns.Span.of_int_ms
let id sequence = { Job.Id.generation = 1; sequence }
let job ?lane sequence steps = Job.create ~id:(id sequence) ?lane steps |> Or_error.ok_exn

let within ?(span = Time_ns.Span.of_int_sec 10) deferred =
  match%map Clock_ns.with_timeout span deferred with
  | `Result result -> result
  | `Timeout -> raise_s [%message "Test deadline passed" (span : Time_ns.Span.t)]
;;

(* A [/bin/sh -c script] step. The scripts are fixed test text. *)
let sh ?(kind = Exec.Kind.Read) ?(stream = false) ~cwd script =
  Job.Step.Run
    (Exec.Spec.create
       ~timeout:(Some (Time_ns.Span.of_int_sec 20))
       ~stream
       ~kind
       ~cwd
       "/bin/sh"
       [ "-c"; script ])
;;

(* A fixture repository with one commit, a modified file and an untracked one; the host
   inherits the fixture's isolated environment. Both are torn down whatever happens:
   the host is shut down (children reaped) before the directory is removed. *)
let with_host ?config f =
  let repo = Fixture.create () in
  Fixture.write repo "a.txt" "one\n";
  ignore (Fixture.commit_all repo "first" : string);
  Fixture.write repo "a.txt" "two\n";
  Fixture.write repo "new.txt" "new\n";
  let host = Vcs_host.create ?config ~inherited:(Fixture.environment repo) () in
  Monitor.protect
    (fun () -> f repo host)
    ~finally:(fun () ->
      let%map (_ : [ `Finished | `Timed_out ]) = within (Vcs_host.shutdown host) in
      Fixture.remove repo)
;;

let event = function
  | Input.Vcs event -> event
  | input -> raise_s [%message "Not a Vcs input" (input : Input.t)]
;;

let scrub (repo : Fixture.t) text =
  String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"
;;

let describe repo (event : Event.t) =
  match event with
  | Started { job; step; spec } ->
    [%sexp
      "started"
      , (Job.Id.to_string_hum job : string)
      , (step : int)
      , (scrub repo (Exec.Spec.to_string_hum spec) : string)]
  | Output { job; line; _ } ->
    [%sexp "output", (Job.Id.to_string_hum job : string), (line.text : string)]
  | Finished report ->
    [%sexp
      "finished"
      , (Job.Id.to_string_hum report.id : string)
      , (if report.cancelled
         then "cancelled"
         else if Job.Report.succeeded report
         then "succeeded"
         else "failed"
         : string)]
;;

let finished_report sequence events =
  List.find_map events ~f:(function
    | Event.Finished report when report.id.sequence = sequence -> Some report
    | Started _ | Output _ | Finished _ -> None)
;;

(* Pump like the frontend: one [next_inputs] at a time, until [until] holds. Returns the
   batches, oldest first. *)
let pump host ~until =
  let rec loop batches =
    let events = List.concat_map batches ~f:(List.map ~f:event) in
    if until events
    then return batches
    else (
      let%bind batch = Vcs_host.next_inputs host in
      loop (batches @ [ batch ]))
  in
  within (loop [])
;;

let events_of batches = List.concat_map batches ~f:(List.map ~f:event)
let has_finished sequence events = Option.is_some (finished_report sequence events)

let rec idle host =
  if Vcs_host.busy host
  then (
    let%bind () = Clock_ns.after (ms 10) in
    idle host)
  else return ()
;;

let group_alive pid =
  let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_int_sec 2) in
  let rec loop () =
    match Signal_unix.send Signal.zero (`Group (Pid.of_int pid)) with
    | `No_such_process -> return false
    | `Ok when Time_ns.( > ) (Time_ns.now ()) deadline -> return true
    | `Ok ->
      let%bind () = Clock_ns.after (ms 20) in
      loop ()
  in
  loop ()
;;

let output_pid sequence events =
  List.find_map events ~f:(function
    | Event.Output { job; line; _ } when job.sequence = sequence ->
      Some (Int.of_string (String.strip line.text))
    | Started _ | Output _ | Finished _ -> None)
;;

let%expect_test "submit and pump: the git backend's detect and refresh, as Vcs inputs" =
  with_host (fun repo host ->
    Vcs_host.submit host [ job ~lane:"detect" 1 (B.detect ~cwd:repo.work) ];
    let%bind batches = pump host ~until:(has_finished 1) in
    let events = events_of batches in
    List.iter events ~f:(fun event -> print_s (describe repo event));
    let report = Option.value_exn (finished_report 1 events) in
    let repository =
      match B.detected ~cwd:repo.work report.steps with
      | Found repository -> repository
      | detection ->
        raise_s
          [%message
            "not found" (detection : Ches_vcs_git.Repository.t Backend.Detection.t)]
    in
    print_s [%sexp (scrub repo (B.Repository.root repository) : string)];
    [%expect
      {|
      (started g1.1 0
       "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --show-toplevel --absolute-git-dir")
      (finished g1.1 succeeded)
      $DIR/work
      |}];
    let refresh = Backend.Refresh.default in
    Vcs_host.submit host [ job ~lane:"refresh" 2 (B.refresh repository refresh) ];
    let%map batches = pump host ~until:(has_finished 2) in
    let events = events_of batches in
    let report = Option.value_exn (finished_report 2 events) in
    let snapshot = ok_exn (B.snapshot repository refresh report.steps) in
    print_s
      [%sexp
        { started =
            (List.count events ~f:(function
               | Started _ -> true
               | Output _ | Finished _ -> false)
             : int)
        ; steps = (List.length report.steps : int)
        ; succeeded = (Job.Report.succeeded report : bool)
        ; summary = (B.summary snapshot : Backend.Summary.t)
        ; files =
            (List.map (List.hd_exn (B.panels snapshot)).sections ~f:(fun section ->
               section.title, List.map section.items ~f:(fun item -> item.key))
             : (string * string list) list)
        ; busy = (Vcs_host.busy host : bool)
        }];
    [%expect {|
      ((started 3) (steps 12) (succeeded true)
       (summary
        ((branch (main)) (revision (20ef33d)) (upstream ()) (operations ())))
       (files (("Untracked files" (new.txt)) ("Unstaged changes" (a.txt))))
       (busy false))
      |}])
;;

let%expect_test "batching: pending events come in one batch, at most max_batch, in order" =
  let rev_parse ~cwd =
    [ Job.Step.Run (Ches_vcs_git.Cli.read ~cwd [ "rev-parse"; "--show-toplevel" ]) ]
  in
  let submit_three (repo : Fixture.t) host =
    Vcs_host.submit
      host
      (List.map [ 1; 2; 3 ] ~f:(fun sequence -> job sequence (rev_parse ~cwd:repo.work)))
  in
  (* Each job's Started comes before its Finished, whatever order the reads end in. *)
  let ordered events =
    List.for_all [ 1; 2; 3 ] ~f:(fun sequence ->
      let index kind =
        List.findi events ~f:(fun _ (event : Event.t) ->
          (Event.job event).sequence = sequence
          &&
          match event, kind with
          | Started _, `Started | Finished _, `Finished -> true
          | _ -> false)
        |> Option.value_exn
        |> fst
      in
      index `Started < index `Finished)
  in
  let%bind () =
    with_host (fun repo host ->
      submit_three repo host;
      let%bind () = within (idle host) in
      let%map batch = within (Vcs_host.next_inputs host) in
      let events = List.map batch ~f:event in
      print_s
        [%sexp
          { batch = (List.length batch : int)
          ; finished = (List.filter [ 1; 2; 3 ] ~f:(Fn.flip has_finished events) : int list)
          ; ordered = (ordered events : bool)
          }];
      [%expect {| ((batch 6) (finished (1 2 3)) (ordered true)) |}])
  in
  with_host
    ~config:{ Ches_vcs_host.Runner.Config.default with max_batch = 2 }
    (fun repo host ->
      submit_three repo host;
      let%bind () = within (idle host) in
      let%bind batches = pump host ~until:(fun events -> List.length events = 6) in
      (* Nothing is pending now: the next batch waits. *)
      let next = Vcs_host.next_inputs host in
      let%map () = Clock_ns.after (ms 50) in
      print_s
        [%sexp
          { batches = (List.map batches ~f:List.length : int list)
          ; ordered = (ordered (events_of batches) : bool)
          ; next_determined = (Deferred.is_determined next : bool)
          }];
      [%expect {| ((batches (2 2 2)) (ordered true) (next_determined false)) |}])
;;

let%expect_test "a job superseded in its lane is cancelled; a reused id never starts" =
  with_host (fun repo host ->
    Vcs_host.submit
      host
      [ job ~lane:"refresh" 1 [ sh ~stream:true ~cwd:repo.work "echo $$; exec sleep 10" ]
      ];
    let%bind batches =
      pump host ~until:(fun events -> Option.is_some (output_pid 1 events))
    in
    let pid = Option.value_exn (output_pid 1 (events_of batches)) in
    Vcs_host.submit
      host
      [ job
          ~lane:"refresh"
          2
          [ Run (Ches_vcs_git.Cli.read ~cwd:repo.work [ "rev-parse"; "HEAD" ]) ]
      ];
    let%bind more =
      pump host ~until:(fun events -> has_finished 1 events && has_finished 2 events)
    in
    let%bind alive = group_alive pid in
    (* By id: the two may finish in either order. *)
    List.iter [ 1; 2 ] ~f:(fun sequence ->
      print_s
        (describe repo (Finished (Option.value_exn (finished_report sequence (events_of more))))));
    print_s [%sexp { superseded_child_alive = (alive : bool) }];
    [%expect {|
      (finished g1.1 cancelled)
      (finished g1.2 succeeded)
      ((superseded_child_alive false))
      |}];
    (* The id of a finished job, submitted again: answered at once, never run. *)
    Vcs_host.submit host [ job 2 [ sh ~cwd:repo.work "echo again" ] ];
    let%map batches = pump host ~until:(has_finished 2) in
    List.iter (events_of batches) ~f:(fun event -> print_s (describe repo event));
    print_s
      [%sexp
        (List.map (Option.value_exn (finished_report 2 (events_of batches))).steps
           ~f:(fun step -> step.outcome)
         : Job.Step.Outcome.t list)];
    [%expect {|
      (finished g1.2 cancelled)
      (Skipped)
      |}])
;;

let%expect_test "shutdown with work in flight: children terminated and reaped, then silence" =
  with_host (fun repo host ->
    (* A running read, a running mutation, and a mutation queued behind it. *)
    Vcs_host.submit
      host
      [ job 1 [ sh ~stream:true ~cwd:repo.work "echo $$; exec sleep 30" ]
      ; job 2 [ sh ~kind:Mutate ~stream:true ~cwd:repo.work "echo $$; exec sleep 30" ]
      ; job 3 [ sh ~kind:Mutate ~cwd:repo.work "echo queued" ]
      ];
    let%bind batches =
      pump host ~until:(fun events ->
        Option.is_some (output_pid 1 events) && Option.is_some (output_pid 2 events))
    in
    let events = events_of batches in
    let pids = List.map [ 1; 2 ] ~f:(fun sequence -> Option.value_exn (output_pid sequence events)) in
    (* The frontend's pump is waiting when the editor exits. *)
    let pending = Vcs_host.next_inputs host in
    let start = Time_ns.now () in
    let%bind result = Vcs_host.shutdown host in
    let elapsed = Time_ns.diff (Time_ns.now ()) start in
    let%bind alive = Deferred.List.map ~how:`Sequential pids ~f:group_alive in
    (* After stop: submissions are ignored and nothing more is delivered. *)
    Vcs_host.submit host [ job 4 [ sh ~cwd:repo.work "echo late" ] ];
    let%map () = Clock_ns.after (ms 100) in
    print_s
      [%sexp
        { result : [ `Finished | `Timed_out ]
        ; within_cap = (Time_ns.Span.( < ) elapsed (Time_ns.Span.of_int_sec 3) : bool)
        ; children_alive = (alive : bool list)
        ; busy = (Vcs_host.busy host : bool)
        ; pump_woken = (Deferred.is_determined pending : bool)
        ; index_lock =
            (Sys_unix.file_exists_exn (Fixture.path repo ".git/index.lock") : bool)
        }];
    [%expect {|
      ((result Finished) (within_cap true) (children_alive (false false))
       (busy false) (pump_woken false) (index_lock false))
      |}])
;;

let%expect_test "shutdown's cap: a child that ignores SIGTERM outlasts it until SIGKILL" =
  with_host
    ~config:{ Ches_vcs_host.Runner.Config.default with termination_grace = ms 500 }
    (fun repo host ->
      Vcs_host.submit
        host
        [ job
            1
            [ sh
                ~stream:true
                ~cwd:repo.work
                "trap '' TERM; echo $$; while :; do sleep 0.1; done"
            ]
        ];
      let%bind batches =
        pump host ~until:(fun events -> Option.is_some (output_pid 1 events))
      in
      let pid = Option.value_exn (output_pid 1 (events_of batches)) in
      let%bind first = Vcs_host.shutdown ~cap:(ms 100) host in
      let%bind second = Vcs_host.shutdown host in
      let%map alive = group_alive pid in
      print_s
        [%sexp
          { first : [ `Finished | `Timed_out ]
          ; second : [ `Finished | `Timed_out ]
          ; child_alive = (alive : bool)
          }];
      [%expect {| ((first Timed_out) (second Finished) (child_alive false)) |}])
;;
