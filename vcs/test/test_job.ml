open! Core
open Ches_vcs

let spec ?(kind = Exec.Kind.Read) ?(cwd = "/repo") args =
  Exec.Spec.create ~kind ~cwd "git" args
;;

let result ?(status = Exec.Status.Exited 0) ?(timed_out = false) ?(cancelled = false) () =
  { Exec.Result.status
  ; stdout = ""
  ; stdout_truncated = false
  ; stderr = ""
  ; stderr_truncated = false
  ; timed_out
  ; cancelled
  ; elapsed = Time_ns.Span.of_int_sec 30
  }
;;

let%expect_test "spec defaults, argv and the command line for display" =
  let read = spec [ "status"; "--porcelain=v2"; "-z" ] in
  print_s
    [%sexp
      { argv = (Exec.Spec.argv read : string list)
      ; timeout = (read.timeout : Time_ns.Span.t option)
      ; network_timeout =
          ((spec ~kind:Network [ "fetch" ]).timeout : Time_ns.Span.t option)
      ; limits = ((read.stdout_limit, read.stderr_limit) : int * int)
      }];
  [%expect
    {|
    ((argv (git status --porcelain=v2 -z)) (timeout (30s))
     (network_timeout (10m)) (limits (33554432 65536)))
    |}];
  print_endline
    (Exec.Spec.to_string_hum
       (spec [ "commit"; "-m"; "it's done"; ""; "a b"; "x\ny"; "-c"; "color.ui=false" ]));
  [%expect {| git commit -m 'it'\''s done' '' 'a b' 'x\x0Ay' -c color.ui=false |}];
  print_s
    [%sexp
      ((Exec.Spec.create ~timeout:None ~kind:Mutate ~cwd:"/r" "git" []).timeout
       : Time_ns.Span.t option)];
  [%expect {| () |}]
;;

let%expect_test "result predicates and status lines" =
  let show r =
    print_s
      [%sexp
        { succeeded = (Exec.Result.succeeded r : bool)
        ; exit_0_or_1 = (Exec.Result.exited_with r [ 0; 1 ] : bool)
        ; status = (Exec.Result.status_hum r : string)
        }]
  in
  show (result ());
  show (result ~status:(Exited 1) ());
  show (result ~status:(Signaled "sigterm") ~timed_out:true ());
  show (result ~status:(Signaled "sigterm") ~cancelled:true ());
  show (result ~status:(Signaled "sigkill") ());
  show (result ~status:(Not_started "No such file or directory") ());
  [%expect
    {|
    ((succeeded true) (exit_0_or_1 true) (status "exit 0"))
    ((succeeded false) (exit_0_or_1 true) (status "exit 1"))
    ((succeeded false) (exit_0_or_1 false) (status "timed out after 30s"))
    ((succeeded false) (exit_0_or_1 false) (status cancelled))
    ((succeeded false) (exit_0_or_1 false) (status "killed by sigkill"))
    ((succeeded false) (exit_0_or_1 false)
     (status "could not start: No such file or directory"))
    |}];
  let cut = { (result ~status:(Signaled "sigterm") ()) with stdout_truncated = true } in
  print_s [%sexp (Exec.Result.cut_at_limit cut : bool)];
  print_s [%sexp (Exec.Result.cut_at_limit { cut with timed_out = true } : bool)];
  [%expect
    {|
    true
    false
    |}]
;;

let id sequence = { Job.Id.generation = 0; sequence }
let read_file path = Job.Step.Read_file { path; limit = 4096 }

let%expect_test "job validation and kind" =
  let show ?lane steps =
    match Job.create ~id:(id 1) ?lane steps with
    | Ok job -> print_s [%sexp (Job.kind job : Exec.Kind.t), (job.lane : string option)]
    | Error error -> print_s [%sexp (error : Error.t)]
  in
  show [ Run (spec [ "status" ]); read_file "/repo/.git/MERGE_HEAD" ] ~lane:"refresh";
  show [ Run (spec [ "add" ] ~kind:Mutate); Run (spec [ "status" ]) ];
  show [ Run (spec [ "push" ] ~kind:Network); Run (spec [ "add" ] ~kind:Mutate) ];
  show [];
  show [ Run (spec [ "add" ] ~kind:Mutate) ] ~lane:"diff";
  show [ Run (spec [ "status" ]) ] ~lane:"";
  show [ Run (spec [ "status" ] ~cwd:"repo") ];
  show [ Run { (spec [ "status" ]) with stdout_limit = 0 } ];
  show [ Run { (spec [ "status" ]) with prog = "" } ];
  show [ read_file "MERGE_HEAD" ];
  show [ Read_file { path = "/x"; limit = 0 } ];
  [%expect
    {|
    (Read (refresh))
    (Mutate ())
    (Network ())
    "Job has no steps"
    ("Only read jobs may have a lane" (lane diff))
    "Job lane is empty"
    ("Command cwd is not absolute" (spec.cwd repo))
    "Command output limits must be positive"
    "Command has no program"
    ("File read path is not absolute" (path MERGE_HEAD))
    "File read limit must be positive"
    |}]
;;

let%expect_test "reports: success, first failure, never started" =
  let job =
    Job.create
      ~id:(id 7)
      [ Run (spec [ "add" ] ~kind:Mutate); read_file "/r/x"; Run (spec [ "commit" ] ~kind:Mutate) ]
    |> Or_error.ok_exn
  in
  let report outcomes : Job.Report.t =
    { id = job.id
    ; lane = None
    ; kind = Job.kind job
    ; steps =
        List.map2_exn job.steps outcomes ~f:(fun step outcome -> { Job.Step_report.step; outcome })
    ; cancelled = false
    }
  in
  let show (r : Job.Report.t) =
    print_s
      [%sexp
        { succeeded = (Job.Report.succeeded r : bool)
        ; first_failure =
            (Option.map (Job.Report.first_failure r) ~f:(fun s -> s.outcome)
             : Job.Step.Outcome.t option)
        }]
  in
  let ok = Job.Step.Outcome.Ran (result ()) in
  show (report [ ok; Read Missing; ok ]);
  show (report [ ok; Read (Failed "EACCES"); Skipped ]);
  show (report [ Ran (result ~status:(Exited 128) ()); Skipped; Skipped ]);
  show { (report [ ok; Read Missing; ok ]) with cancelled = true };
  [%expect
    {|
    ((succeeded true) (first_failure ()))
    ((succeeded false) (first_failure ((Read (Failed EACCES)))))
    ((succeeded false)
     (first_failure
      ((Ran
        ((status (Exited 128)) (stdout "") (stdout_truncated false) (stderr "")
         (stderr_truncated false) (timed_out false) (cancelled false)
         (elapsed 30s))))))
    ((succeeded false) (first_failure ()))
    |}];
  let never = Job.never_started job in
  print_s
    [%sexp
      (never.cancelled : bool)
    , (List.map never.steps ~f:(fun s -> s.outcome) : Job.Step.Outcome.t list)
    , (Job.Report.succeeded never : bool)];
  [%expect {| (true (Skipped Skipped Skipped) false) |}]
;;

let%expect_test "stamps: generations and lanes decide what is current" =
  let stamps = Stamps.create () in
  let stamps, refresh1 = Stamps.issue stamps ~lane:"refresh" in
  let stamps, mutation = Stamps.issue stamps in
  let stamps, refresh2 = Stamps.issue stamps ~lane:"refresh" in
  let stamps, diff = Stamps.issue stamps ~lane:"diff" in
  let current stamps ?lane id = Stamps.is_current stamps ?lane id in
  print_s
    [%sexp
      { ids = ([ refresh1; mutation; refresh2; diff ] : Job.Id.t list)
      ; refresh1 = (current stamps ~lane:"refresh" refresh1 : bool)
      ; refresh2 = (current stamps ~lane:"refresh" refresh2 : bool)
      ; mutation = (current stamps mutation : bool)
      ; diff = (current stamps ~lane:"diff" diff : bool)
      ; diff_in_wrong_lane = (current stamps ~lane:"refresh" diff : bool)
      ; latest = (Stamps.latest stamps ~lane:"refresh" : Job.Id.t option)
      }];
  [%expect
    {|
    ((ids
      (((generation 0) (sequence 1)) ((generation 0) (sequence 2))
       ((generation 0) (sequence 3)) ((generation 0) (sequence 4))))
     (refresh1 false) (refresh2 true) (mutation true) (diff true)
     (diff_in_wrong_lane false) (latest (((generation 0) (sequence 3)))))
    |}];
  let stamps = Stamps.invalidate stamps in
  let stamps, next = Stamps.issue stamps ~lane:"refresh" in
  print_s
    [%sexp
      { generation = (Stamps.generation stamps : int)
      ; next = (Job.Id.to_string_hum next : string)
      ; old_mutation = (current stamps mutation : bool)
      ; old_diff = (current stamps ~lane:"diff" diff : bool)
      ; next_current = (current stamps ~lane:"refresh" next : bool)
      ; diff_latest = (Stamps.latest stamps ~lane:"diff" : Job.Id.t option)
      }];
  [%expect
    {|
    ((generation 1) (next g1.5) (old_mutation false) (old_diff false)
     (next_current true) (diff_latest ()))
    |}];
  let report : Job.Report.t =
    { id = next; lane = Some "refresh"; kind = Read; steps = []; cancelled = false }
  in
  print_s
    [%sexp
      (Stamps.accepts stamps report : bool)
    , (Stamps.accepts stamps { report with lane = None; id = refresh2 } : bool)];
  [%expect {| (true false) |}]
;;

let%expect_test "events name their job" =
  let job = id 3 in
  print_s
    [%sexp
      (List.map
         [ Event.Started { job; step = 0; spec = spec [ "fetch" ] }
         ; Output
             { job
             ; step = 0
             ; stream = Stderr
             ; line = { text = "Receiving objects: 45%"; transient = true }
             }
         ; Finished
             { id = job; lane = None; kind = Network; steps = []; cancelled = true }
         ]
         ~f:(fun event -> Job.Id.to_string_hum (Event.job event))
       : string list)];
  [%expect {| (g0.3 g0.3 g0.3) |}]
;;
