open! Core
open! Async
open Ches_vcs

module Config = struct
  type t =
    { max_concurrent_reads : int
    ; termination_grace : Time_ns.Span.t
    ; max_batch : int
    }
  [@@deriving sexp_of]

  let default =
    { max_concurrent_reads = 4
    ; termination_grace = Time_ns.Span.of_int_sec 2
    ; max_batch = 64
    }
  ;;
end

(* A pending event. [event] becomes [None] once the event is taken, or dropped (a
   transient line replaced by a later one before anyone took it). *)
module Cell = struct
  type t = { mutable event : Event.t option }
end

(* Child-process slots for reads. A waiter gives up when its job is cancelled. *)
module Slots : sig
  type t

  val create : int -> t
  val acquire : t -> cancel:unit Deferred.t -> [ `Acquired | `Cancelled ] Deferred.t
  val release : t -> unit
end = struct
  type waiter =
    { granted : unit Ivar.t
    ; mutable abandoned : bool
    }

  type t =
    { mutable free : int
    ; waiters : waiter Queue.t
    }

  let create free = { free; waiters = Queue.create () }

  let rec release t =
    match Queue.dequeue t.waiters with
    | None -> t.free <- t.free + 1
    | Some waiter when waiter.abandoned -> release t
    | Some waiter -> Ivar.fill_exn waiter.granted ()
  ;;

  let acquire t ~cancel =
    if Deferred.is_determined cancel
    then return `Cancelled
    else if t.free > 0
    then (
      t.free <- t.free - 1;
      return `Acquired)
    else (
      let waiter = { granted = Ivar.create (); abandoned = false } in
      Queue.enqueue t.waiters waiter;
      match%map
        choose
          [ choice (Ivar.read waiter.granted) (fun () -> `Acquired)
          ; choice cancel (fun () -> `Cancelled)
          ]
      with
      | `Acquired -> `Acquired
      | `Cancelled ->
        waiter.abandoned <- true;
        (* Granted in the same cycle: hand the slot on. *)
        if Ivar.is_full waiter.granted then release t;
        `Cancelled)
  ;;
end

module State = struct
  type t =
    | Queued (** In the mutation queue. *)
    | Running
    | Done (** Reported, or dropped by [stop]. *)
  [@@deriving equal]
end

type job =
  { job : Job.t
  ; kind : Exec.Kind.t
  ; cancel : unit Ivar.t (** Filled by [cancel], a later job of its lane, or [stop]. *)
  ; outcomes : Job.Step.Outcome.t array (** [Skipped] until the step ends. *)
  ; mutable state : State.t
  }

type t =
  { config : Config.t
  ; inherited : (string * string) list
  ; events : Cell.t Queue.t
  ; mutable pending : int (** Cells in [events] that still hold an event. *)
  ; mutable waiter : unit Ivar.t option
  ; mutable jobs : job Job.Id.Map.t (** Queued or running. *)
  ; mutable submitted : Job.Id.Set.t
  ; mutable lanes : job String.Map.t
  ; mutations : job Queue.t
  ; mutable mutation_running : bool
  ; read_slots : Slots.t
  ; mutable live : int (** Child executions not yet reaped (including probes). *)
  ; mutable stopped : bool
  ; reaped : unit Ivar.t
  }

let create ?(config = Config.default) ?inherited () =
  if config.max_concurrent_reads <= 0
     || Time_ns.Span.( < ) config.termination_grace Time_ns.Span.zero
     || config.max_batch <= 0
  then raise_s [%message "Ches_vcs_host.Runner: invalid config" (config : Config.t)];
  let inherited =
    match inherited with
    | Some inherited -> inherited
    | None ->
      Core_unix.environment ()
      |> Array.to_list
      |> List.filter_map ~f:(fun binding -> String.lsplit2 binding ~on:'=')
  in
  { config
  ; inherited
  ; events = Queue.create ()
  ; pending = 0
  ; waiter = None
  ; jobs = Job.Id.Map.empty
  ; submitted = Job.Id.Set.empty
  ; lanes = String.Map.empty
  ; mutations = Queue.create ()
  ; mutation_running = false
  ; read_slots = Slots.create config.max_concurrent_reads
  ; live = 0
  ; stopped = false
  ; reaped = Ivar.create ()
  }
;;

(* Events *)

let push t event =
  if t.stopped
  then None
  else (
    let cell = { Cell.event = Some event } in
    Queue.enqueue t.events cell;
    t.pending <- t.pending + 1;
    Option.iter t.waiter ~f:(fun waiter ->
      t.waiter <- None;
      Ivar.fill_if_empty waiter ());
    Some cell)
;;

let drop t (cell : Cell.t) =
  if Option.is_some cell.event
  then (
    cell.event <- None;
    t.pending <- t.pending - 1)
;;

let take t =
  let rec loop taken n =
    if n = 0
    then List.rev taken
    else (
      match Queue.dequeue t.events with
      | None -> List.rev taken
      | Some cell ->
        (match cell.event with
         | None -> loop taken n
         | Some event ->
           drop t cell;
           loop (event :: taken) (n - 1)))
  in
  loop [] t.config.max_batch
;;

let poll t = if t.stopped then [] else take t

let rec next_batch t =
  if t.stopped
  then Deferred.never ()
  else if t.pending > 0
  then return (take t)
  else (
    let waiter = Ivar.create () in
    t.waiter <- Some waiter;
    (* Resumes in a later job, so events pushed in the same cycle share the batch. *)
    let%bind () = Ivar.read waiter in
    next_batch t)
;;

(* Streamed lines of one step and stream: a transient line still pending when the next
   line arrives is dropped. *)
let output_handler t ~job ~step stream =
  let last = ref None in
  fun (line : Event.Line.t) ->
    Option.iter !last ~f:(drop t);
    let cell = push t (Output { job; step; stream; line }) in
    last := if line.transient then cell else None
;;

(* Child processes *)

let check_reaped t = if t.stopped && t.live = 0 then Ivar.fill_if_empty t.reaped ()

let unix_message = function
  | Core_unix.Unix_error (error, _, _) -> Core_unix.Error.message error
  | exn -> Exn.to_string exn
;;

let not_started message : Exec.Result.t =
  { status = Not_started message
  ; stdout = ""
  ; stdout_truncated = false
  ; stderr = ""
  ; stderr_truncated = false
  ; timed_out = false
  ; cancelled = false
  ; elapsed = Time_ns.Span.zero
  }
;;

let check_cwd cwd =
  match%map Monitor.try_with ~extract_exn:true (fun () -> Unix.stat cwd) with
  | Ok { kind = `Directory; _ } -> Ok ()
  | Ok _ -> Error (sprintf "working directory %s: Not a directory" cwd)
  | Error exn -> Error (sprintf "working directory %s: %s" cwd (unix_message exn))
;;

(* [prog] is looked up on the child's [PATH], not this process's. *)
let search_path env =
  match List.Assoc.find env "PATH" ~equal:String.equal with
  | None | Some "" -> None
  | Some path ->
    Some
      (List.map (String.split path ~on:':') ~f:(function
        | "" -> "."
        | dir -> dir))
;;

let spawn_message (spec : Exec.Spec.t) error =
  match Monitor.extract_exn (Error.to_exn error) with
  | Core_unix.Unix_error (error, _, _) ->
    sprintf "%s: %s" spec.prog (Core_unix.Error.message error)
  | _ -> Error.to_string_hum error
;;

(* The child is its group's leader, so its pid is the group id. *)
let signal_group pid signal =
  match Signal_unix.send signal (`Group pid) with
  | `Ok | `No_such_process -> ()
  | exception _ -> ()
;;

(* Read [reader] to end of file, handing each chunk to [add] and, when streaming, to
   [lines]. *)
let drain reader ~add ~lines =
  let buffer = Bytes.create 65536 in
  let splitter = Option.map lines ~f:(fun on_line -> Capture.Lines.create (), on_line) in
  let rec loop () =
    match%bind Reader.read reader buffer with
    | `Eof -> return ()
    | `Ok len ->
      add buffer ~pos:0 ~len;
      Option.iter splitter ~f:(fun (splitter, f) ->
        Capture.Lines.feed splitter buffer ~pos:0 ~len ~f);
      loop ()
  in
  let%bind (_ : (unit, exn) Result.t) = Monitor.try_with ~extract_exn:true loop in
  Option.iter splitter ~f:(fun (splitter, f) -> Capture.Lines.finish splitter ~f);
  Reader.close reader
;;

let supervise t (spec : Exec.Spec.t) process ~cancel ~lines =
  let start = Time_ns.now () in
  let pid = Process.pid process in
  let exited = Process.wait process in
  let ended = ref start in
  upon exited (fun _ -> ended := Time_ns.now ());
  (* Full once the child is reaped and both pipes are at end of file: after that the group
     is never signaled (its id may be reused). *)
  let complete = Ivar.create () in
  let reason = ref None in
  let terminate why =
    if Option.is_none !reason && not (Ivar.is_full complete)
    then (
      reason := Some why;
      signal_group pid Signal.term;
      let kill =
        Clock_ns.Event.run_after
          t.config.termination_grace
          (fun () -> if not (Ivar.is_full complete) then signal_group pid Signal.kill)
          ()
      in
      upon (Ivar.read complete) (fun () -> Clock_ns.Event.abort_if_possible kill ()))
  in
  Option.iter spec.timeout ~f:(fun timeout ->
    let timer = Clock_ns.Event.run_after timeout (fun () -> terminate `Timed_out) () in
    upon (Ivar.read complete) (fun () -> Clock_ns.Event.abort_if_possible timer ()));
  upon cancel (fun () -> terminate `Cancelled);
  (* [Null]: nothing was written, so this closes the pipe at once. [Data]: closes it once
     written; forced if the child exits without reading it all. *)
  let stdin_closed =
    Writer.close (Process.stdin process) ~force_close:(Deferred.ignore_m exited)
  in
  let head = Capture.Head.create ~limit:spec.stdout_limit in
  let tail = Capture.Tail.create ~limit:spec.stderr_limit in
  let stdout_done =
    drain
      (Process.stdout process)
      ~lines:(Option.map lines ~f:(fun lines -> lines Exec.Stream.Stdout))
      ~add:(fun bytes ~pos ~len ->
        match Capture.Head.add head bytes ~pos ~len, spec.kind with
        | `Passed_limit, Read -> terminate `Cut
        | (`Within | `Beyond), _ | `Passed_limit, (Mutate | Network) -> ())
  in
  let stderr_done =
    drain
      (Process.stderr process)
      ~lines:(Option.map lines ~f:(fun lines -> lines Exec.Stream.Stderr))
      ~add:(Capture.Tail.add tail)
  in
  let%bind exit = exited
  and () = stdout_done
  and () = stderr_done in
  Ivar.fill_if_empty complete ();
  let%map () = stdin_closed in
  let status : Exec.Status.t =
    match exit with
    | Ok () -> Exited 0
    | Error (`Exit_non_zero code) -> Exited code
    | Error (`Signal signal) -> Signaled (Signal.to_string signal)
  in
  { Exec.Result.status
  ; stdout = Capture.Head.contents head
  ; stdout_truncated = Capture.Head.truncated head
  ; stderr = Capture.Tail.contents tail
  ; stderr_truncated = Capture.Tail.truncated tail
  ; timed_out =
      (match !reason with
       | Some `Timed_out -> true
       | Some (`Cancelled | `Cut) | None -> false)
  ; cancelled =
      (match !reason with
       | Some `Cancelled -> true
       | Some (`Timed_out | `Cut) | None -> false)
  ; elapsed = Time_ns.diff !ended start
  }
;;

let spawn_and_supervise t (spec : Exec.Spec.t) ~env ~cancel ~lines =
  match%bind check_cwd spec.cwd with
  | Error message -> return (not_started message)
  | Ok () when Deferred.is_determined cancel ->
    return { (not_started "cancelled before it started") with cancelled = true }
  | Ok () ->
    let stdin =
      match spec.stdin with
      | Null -> None
      | Data data -> Some data
    in
    (match%bind
       Process.create
         ~prog:spec.prog
         ~args:spec.args
         ~env:(`Replace env)
         ?prog_search_path:(search_path env)
         ~working_dir:spec.cwd
         ~setpgid:Core_unix.Pgid.new_process_group
         ?stdin
         ()
     with
     | Error error -> return (not_started (spawn_message spec error))
     | Ok process -> supervise t spec process ~cancel ~lines)
;;

(* Run one child to completion. Never raises; [live] counts it until it is reaped. *)
let execute t spec ~env ~cancel ~lines =
  t.live <- t.live + 1;
  let%map result =
    Monitor.try_with
      ~extract_exn:true
      ~rest:(`Call (fun (_ : exn) -> ()))
      (fun () -> spawn_and_supervise t spec ~env ~cancel ~lines)
  in
  t.live <- t.live - 1;
  check_reaped t;
  match result with
  | Ok result -> result
  | Error exn -> not_started (Exn.to_string exn)
;;

let read_file ({ path; limit } : Job.File_read.t) : Job.File_read.Result.t Deferred.t =
  let read () : Job.File_read.Result.t =
    match Core_unix.openfile path ~mode:[ O_RDONLY ] with
    | exception Core_unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Missing
    | exception exn -> Failed (unix_message exn)
    | fd ->
      Exn.protect
        ~f:(fun () ->
          let buffer = Bytes.create (limit + 1) in
          let rec fill pos =
            if pos > limit
            then pos
            else (
              match Core_unix.read fd ~buf:buffer ~pos ~len:(limit + 1 - pos) with
              | 0 -> pos
              | n -> fill (pos + n))
          in
          match fill 0 with
          | exception exn -> Job.File_read.Result.Failed (unix_message exn)
          | length ->
            Contents
              { text = Bytes.To_string.sub buffer ~pos:0 ~len:(Int.min length limit)
              ; truncated = length > limit
              })
        ~finally:(fun () ->
          try Core_unix.close fd with
          | _ -> ())
  in
  match%map Monitor.try_with ~extract_exn:true (fun () -> In_thread.run read) with
  | Ok result -> result
  | Error exn -> Failed (unix_message exn)
;;

(* Jobs *)

let cancelled job = Ivar.is_full job.cancel

let report job : Job.Report.t =
  { id = job.job.id
  ; lane = job.job.lane
  ; kind = job.kind
  ; steps =
      List.mapi job.job.steps ~f:(fun index step ->
        { Job.Step_report.step; outcome = job.outcomes.(index) })
  ; cancelled = cancelled job
  }
;;

let forget t job =
  t.jobs <- Map.remove t.jobs job.job.id;
  Option.iter job.job.lane ~f:(fun lane ->
    match Map.find t.lanes lane with
    | Some current when phys_equal current job -> t.lanes <- Map.remove t.lanes lane
    | Some _ | None -> ())
;;

let finish t job =
  match job.state with
  | Done -> ()
  | Queued | Running ->
    job.state <- Done;
    forget t job;
    ignore (push t (Finished (report job)) : Cell.t option)
;;

(* One command step: for a network step the [core.sshCommand] probe first, then [Started]
   and the child. A step whose job is cancelled before [Started] is [Skipped]. *)
let run_command t job ~index (spec : Exec.Spec.t) : Job.Step.Outcome.t Deferred.t =
  let cancel = Ivar.read job.cancel in
  let base = t.inherited @ spec.env in
  let%bind ssh_command_configured =
    match spec.kind with
    | Read | Mutate -> return false
    | Network when Deferred.is_determined cancel -> return false
    | Network ->
      let probe = Auth.ssh_command_probe ~cwd:spec.cwd in
      let env =
        Auth.environment ~kind:Read ~base:(base @ probe.env) ~ssh_command_configured:false
      in
      let%map result = execute t probe ~env ~cancel ~lines:None in
      Auth.ssh_command_configured result
  in
  if Deferred.is_determined cancel
  then return Job.Step.Outcome.Skipped
  else (
    ignore (push t (Started { job = job.job.id; step = index; spec }) : Cell.t option);
    let env = Auth.environment ~kind:spec.kind ~base ~ssh_command_configured in
    let lines =
      Option.some_if spec.stream (output_handler t ~job:job.job.id ~step:index)
    in
    let%map result = execute t spec ~env ~cancel ~lines in
    Job.Step.Outcome.Ran result)
;;

let run_step t job ~index (step : Job.Step.t) =
  match step with
  | Read_file read ->
    let%map result = read_file read in
    Job.Step.Outcome.Read result
  | Run spec -> run_command t job ~index spec
;;

(* Steps are independent: all start at once, commands as read slots allow. *)
let run_read_job t job =
  Deferred.List.iteri ~how:`Parallel job.job.steps ~f:(fun index step ->
    let%map outcome =
      match step with
      | Read_file _ when cancelled job -> return Job.Step.Outcome.Skipped
      | Read_file _ -> run_step t job ~index step
      | Run _ ->
        (match%bind Slots.acquire t.read_slots ~cancel:(Ivar.read job.cancel) with
         | `Cancelled -> return Job.Step.Outcome.Skipped
         | `Acquired ->
           let%map outcome = run_step t job ~index step in
           Slots.release t.read_slots;
           outcome)
    in
    job.outcomes.(index) <- outcome)
;;

(* Steps in order, stopping at the first that does not succeed. *)
let run_mutation_job t job =
  let rec loop index steps =
    match steps with
    | [] -> return ()
    | _ :: _ when cancelled job -> return ()
    | step :: rest ->
      let%bind outcome = run_step t job ~index step in
      job.outcomes.(index) <- outcome;
      if Job.Step_report.succeeded { step; outcome }
      then loop (index + 1) rest
      else return ()
  in
  loop 0 job.job.steps
;;

let run_job t job run =
  let%map (_ : (unit, exn) Result.t) =
    Monitor.try_with ~rest:(`Call (fun (_ : exn) -> ())) (fun () -> run t job)
  in
  finish t job
;;

let rec pump t =
  if (not t.stopped) && not t.mutation_running
  then (
    match Queue.dequeue t.mutations with
    | None -> ()
    | Some job ->
      (match job.state with
       | Running | Done -> pump t
       | Queued ->
         job.state <- Running;
         t.mutation_running <- true;
         don't_wait_for
           (let%map () = run_job t job run_mutation_job in
            t.mutation_running <- false;
            pump t)))
;;

let cancel t id =
  match Map.find t.jobs id with
  | None -> ()
  | Some job ->
    Ivar.fill_if_empty job.cancel ();
    (match job.state with
     | Running | Done -> ()
     | Queued ->
       job.state <- Done;
       forget t job;
       ignore (push t (Finished (Job.never_started job.job)) : Cell.t option))
;;

let submit t (submitted : Job.t) =
  if not t.stopped
  then
    if Set.mem t.submitted submitted.id
    then ignore (push t (Finished (Job.never_started submitted)) : Cell.t option)
    else (
      t.submitted <- Set.add t.submitted submitted.id;
      let job =
        { job = submitted
        ; kind = Job.kind submitted
        ; cancel = Ivar.create ()
        ; outcomes =
            Array.create ~len:(List.length submitted.steps) Job.Step.Outcome.Skipped
        ; state = Queued
        }
      in
      Option.iter submitted.lane ~f:(fun lane ->
        Option.iter (Map.find t.lanes lane) ~f:(fun earlier -> cancel t earlier.job.id);
        t.lanes <- Map.set t.lanes ~key:lane ~data:job);
      t.jobs <- Map.set t.jobs ~key:submitted.id ~data:job;
      match job.kind with
      | Read ->
        job.state <- Running;
        don't_wait_for (run_job t job run_read_job)
      | Mutate | Network ->
        Queue.enqueue t.mutations job;
        pump t)
;;

let busy t = not (Map.is_empty t.jobs)

let stop t =
  if not t.stopped
  then (
    t.stopped <- true;
    Queue.iter t.events ~f:(drop t);
    Queue.clear t.events;
    t.waiter <- None;
    Map.iter t.jobs ~f:(fun job ->
      job.state <- Done;
      Ivar.fill_if_empty job.cancel ());
    t.jobs <- Job.Id.Map.empty;
    t.lanes <- String.Map.empty;
    Queue.clear t.mutations;
    check_reaped t)
;;

let finished t = Ivar.read t.reaped
