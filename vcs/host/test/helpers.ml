(* Shared by the runner tests: specs built by hand (never via Ches_vcs_git), a scratch
   directory, a runner that is always stopped and reaped, event collection with a
   deadline, and printing without timings or temp paths. *)
open! Core
open! Async
open Ches_vcs
module Runner = Ches_vcs_host.Runner
module Fixture = Ches_vcs_fixture.Fixture_repo

let id sequence = { Job.Id.generation = 1; sequence }
let ms = Time_ns.Span.of_int_ms

(* A [/bin/sh -c script] command. The scripts are fixed test text, never user input. *)
let sh
  ?(kind = Exec.Kind.Mutate)
  ?env
  ?stdin
  ?(timeout = Some (Time_ns.Span.of_int_sec 5))
  ?stdout_limit
  ?stderr_limit
  ?stream
  ~cwd
  script
  =
  Exec.Spec.create
    ?env
    ?stdin
    ~timeout
    ?stdout_limit
    ?stderr_limit
    ?stream
    ~kind
    ~cwd
    "/bin/sh"
    [ "-c"; script ]
;;

let job ?lane sequence steps = Job.create ~id:(id sequence) ?lane steps |> Or_error.ok_exn
let run spec = Job.Step.Run spec

(* Fails the test instead of hanging it. *)
let within ?(span = Time_ns.Span.of_int_sec 10) deferred =
  match%map Clock_ns.with_timeout span deferred with
  | `Result result -> result
  | `Timeout -> raise_s [%message "Test deadline passed" (span : Time_ns.Span.t)]
;;

let rec remove_tree path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Array.iter (Sys_unix.readdir path) ~f:(fun name ->
      remove_tree (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let with_dir f =
  let dir = Filename_unix.realpath (Filename_unix.temp_dir "ches-vcs-host" "") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      remove_tree dir;
      return ())
;;

let test_config = { Runner.Config.default with termination_grace = ms 200 }

(* The runner is stopped and every child reaped even when [f] raises. *)
let with_runner ?(config = test_config) ?inherited f =
  let runner = Runner.create ~config ?inherited () in
  Monitor.protect
    (fun () -> f runner)
    ~finally:(fun () ->
      Runner.stop runner;
      within (Runner.finished runner))
;;

(* Events received so far, oldest first. *)
type log = { mutable events : Event.t list }

let new_log () = { events = [] }

let rec collect runner log ~until =
  if until log.events
  then return ()
  else (
    let%bind batch = Runner.next_batch runner in
    log.events <- log.events @ batch;
    collect runner log ~until)
;;

let collect runner log ~until = within (collect runner log ~until)

(* Wait until no job is queued or running without taking any event (so no pending
   transient line is taken before a later one could replace it), then take them all. *)
let rec idle runner =
  if Runner.busy runner
  then (
    let%bind () = Clock_ns.after (ms 10) in
    idle runner)
  else return ()
;;

let settle runner log =
  let%map () = within (idle runner) in
  let rec take () =
    match Runner.poll runner with
    | [] -> ()
    | batch ->
      log.events <- log.events @ batch;
      take ()
  in
  take ()
;;

let finished events sequence =
  List.exists events ~f:(function
    | Event.Finished report -> report.id.sequence = sequence
    | Started _ | Output _ -> false)
;;

let all_finished sequences events = List.for_all sequences ~f:(finished events)

let report events sequence =
  List.find_map_exn events ~f:(function
    | Event.Finished report when report.id.sequence = sequence -> Some report
    | Started _ | Output _ | Finished _ -> None)
;;

let result events sequence ~step =
  match (List.nth_exn (report events sequence).steps step).outcome with
  | Ran result -> result
  | (Read _ | Skipped) as outcome ->
    raise_s [%message "Not a command outcome" (outcome : Job.Step.Outcome.t)]
;;

let scrub ~dir text =
  if String.is_empty dir
  then text
  else String.substr_replace_all text ~pattern:dir ~with_:"$DIR"
;;

let result_sexp ?(dir = "") (result : Exec.Result.t) =
  let text s = Sexp.Atom (scrub ~dir s) in
  let flags =
    List.filter_map
      [ "stdout_truncated", result.stdout_truncated
      ; "stderr_truncated", result.stderr_truncated
      ; "timed_out", result.timed_out
      ; "cancelled", result.cancelled
      ]
      ~f:(fun (name, set) -> Option.some_if set (Sexp.Atom name))
  in
  Sexp.List
    ([ (* Without the elapsed time, which varies. *)
       text (if result.timed_out then "timed out" else Exec.Result.status_hum result)
     ]
     @ (if String.is_empty result.stdout
        then []
        else [ Sexp.List [ Atom "stdout"; text result.stdout ] ])
     @ (if String.is_empty result.stderr
        then []
        else [ Sexp.List [ Atom "stderr"; text result.stderr ] ])
     @ flags)
;;

let outcome_sexp ?dir (outcome : Job.Step.Outcome.t) =
  match outcome with
  | Ran result -> Sexp.List [ Atom "ran"; result_sexp ?dir result ]
  | Read read -> Sexp.List [ Atom "read"; [%sexp (read : Job.File_read.Result.t)] ]
  | Skipped -> Atom "skipped"
;;

let event_sexp ?(dir = "") (event : Event.t) =
  match event with
  | Started { job; step; spec } ->
    [%sexp
      "started"
      , (Job.Id.to_string_hum job : string)
      , (step : int)
      , (scrub ~dir (Exec.Spec.to_string_hum spec) : string)]
  | Output { job; step; stream; line } ->
    [%sexp
      "output"
      , (Job.Id.to_string_hum job : string)
      , (step : int)
      , (stream : Exec.Stream.t)
      , (scrub ~dir line.text : string)
      , (if line.transient then "transient" else "line" : string)]
  | Finished report ->
    Sexp.List
      ([ Sexp.Atom "finished"
       ; Atom (Job.Id.to_string_hum report.id)
       ; Atom (if report.cancelled then "cancelled" else "complete")
       ]
       @ List.map report.steps ~f:(fun step -> outcome_sexp ~dir step.outcome))
;;

(* Lines are ordered within a stream, not across stdout and stderr (two pipes): each run
   of consecutive output events is put in stream order, stdout first. *)
let normalize events =
  let is_output = function
    | Event.Output _ -> true
    | Started _ | Finished _ -> false
  in
  let stream = function
    | Event.Output { stream; _ } -> stream
    | Started _ | Finished _ -> Stdout
  in
  List.group events ~break:(fun a b -> Bool.( <> ) (is_output a) (is_output b))
  |> List.concat_map ~f:(fun run ->
    List.stable_sort run ~compare:(fun a b -> Exec.Stream.compare (stream a) (stream b)))
;;

let print_events ?dir events =
  List.iter (normalize events) ~f:(fun event -> print_s (event_sexp ?dir event))
;;

(* The events of one job, in order. *)
let of_job events sequence =
  List.filter events ~f:(fun event -> (Event.job event).sequence = sequence)
;;

(* Position of the first event matching [f]. *)
let index_of events ~f = fst (List.findi_exn events ~f:(fun _ event -> f event))

let finished_at events sequence =
  index_of events ~f:(function
    | Event.Finished report -> report.id.sequence = sequence
    | Started _ | Output _ -> false)
;;

let started_at events sequence =
  index_of events ~f:(function
    | Event.Started { job; _ } -> job.sequence = sequence
    | Output _ | Finished _ -> false)
;;

(* A named pipe: a reader blocks in [open] until a writer arrives, so a script can wait
   for the test without polling. *)
let gate dir name =
  let path = Filename.concat dir name in
  Core_unix.mkfifo path ~perm:0o600;
  path
;;

(* Whether any process is left in group [pgid], allowing [span] for orphans to be reaped
   by init. *)
let group_alive ?(span = Time_ns.Span.of_int_sec 2) pgid =
  let pgid = Pid.of_int pgid in
  let deadline = Time_ns.add (Time_ns.now ()) span in
  let rec loop () =
    match Signal_unix.send Signal.zero (`Group pgid) with
    | `No_such_process -> return false
    | `Ok when Time_ns.( > ) (Time_ns.now ()) deadline -> return true
    | `Ok ->
      let%bind () = Clock_ns.after (ms 20) in
      loop ()
  in
  loop ()
;;
