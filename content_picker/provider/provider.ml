open! Core
open! Async
open Ches_content_picker
module Status = Model.Status

module Limits = struct
  type t =
    { max_hits : int; max_record_bytes : int; max_text_bytes : int
    ; max_payload_bytes : int; max_output_bytes : int; batch_size : int
    ; timeout : Time_ns.Span.t; debounce : Time_ns.Span.t }
  let default =
    { max_hits = 10_000; max_record_bytes = 64 * 1024; max_text_bytes = 4096
    ; max_payload_bytes = 8 * 1024 * 1024; max_output_bytes = 32 * 1024 * 1024
    ; batch_size = 128; timeout = Time_ns.Span.of_sec 10.
    ; debounce = Time_ns.Span.of_int_ms 150 }
end
type run =
  { request : Model.request
  ; reader : Model.hit list Pipe.Reader.t; writer : Model.hit list Pipe.Writer.t
  ; finished : unit Ivar.t; abort : unit Ivar.t
  ; mutable terminal : Status.status option; mutable process : Process.t option
  ; mutable stopped : bool; mutable timed_out : bool }
type t =
  { prog : string; limits : Limits.t; mutable next_id : int
  ; mutable active : run option; mutable reaped : unit Deferred.t
  ; mutable hits_rev : Model.hit list; mutable snapshot : Model.snapshot option }
let create ?(prog = "rg") ?(limits = Limits.default) () =
  if List.exists [ limits.max_hits; limits.max_record_bytes; limits.max_text_bytes
                ; limits.max_payload_bytes; limits.max_output_bytes; limits.batch_size ]
       ~f:(fun n -> n <= 0)
     || Time_ns.Span.(limits.timeout <= zero || limits.debounce < zero)
  then invalid_arg "Content search limits must be positive (debounce may be zero)";
  { prog; limits; next_id = 0; active = None; reaped = return ()
  ; hits_rev = []; snapshot = None }
;;
let request run = run.request
let finished run = Ivar.read run.finished
let snapshot t = t.snapshot
let kill run =
  Option.iter run.process ~f:(fun process ->
    ignore (Process.send_signal_compat process Signal.kill : [ `Ok | `No_such_process ]);
    don't_wait_for (Reader.close (Process.stdout process));
    don't_wait_for (Reader.close (Process.stderr process)))
;;
let cancel t =
  Option.iter t.active ~f:(fun run ->
    run.stopped <- true;
    Ivar.fill_if_empty run.abort ();
    Pipe.close_read run.reader;
    kill run;
    t.snapshot <- Option.map t.snapshot ~f:(fun snapshot -> { snapshot with status = Status.Cancelled }));
  t.active <- None
;;
let stderr_prefix reader =
  let bytes = Bytes.create 4096 in
  let prefix = Buffer.create 8192 in
  let rec loop () =
    match%bind Reader.read reader bytes with
    | `Eof -> return (Buffer.contents prefix)
    | `Ok n ->
      Buffer.add_subbytes prefix bytes ~pos:0 ~len:(Int.min n (8192 - Buffer.length prefix));
      let%bind () = Scheduler.yield () in loop ()
  in loop ()
;;
let collect run (limits : Limits.t) reader =
  let count = ref 0 and payload = ref 0 and output = ref 0 and records = ref 0 in
  let batch = ref [] and batch_count = ref 0 in
  let flush () =
    let hits = List.rev !batch in
    batch := []; batch_count := 0;
    if List.is_empty hits || run.stopped || run.timed_out then return ()
    else Deferred.any_unit [ Pipe.write_if_open run.writer hits; Ivar.read run.abort ]
  in
  let rec add = function
    | [] -> return `Continue
    | (hit : Model.hit) :: rest ->
      let bytes = Model.payload hit in
      if !count >= limits.max_hits || !payload + bytes > limits.max_payload_bytes
         || String.length hit.text > limits.max_text_bytes
         || String.length (Model.Candidate.relative_path hit.candidate) > 4096
      then return `Truncated
      else (
        incr count; payload := !payload + bytes;
        batch := hit :: !batch; incr batch_count;
        let%bind () = if !batch_count >= limits.batch_size then flush () else return () in
        if run.stopped || run.timed_out then return `Truncated else add rest)
  in
  let rec loop () =
    if run.stopped || run.timed_out then return `Truncated
    else match%bind Reader.read_until_bounded reader (`Char '\n') ~keep_delim:false
                      ~max:limits.max_record_bytes with
    | `Eof -> return `Complete
    | `Max_exceeded _ -> return `Truncated
    | `Eof_without_delim _ -> return (`Failed "Unterminated ripgrep JSON record")
    | `Ok raw ->
      output := !output + String.length raw + 1;
      incr records;
      let%bind () = if !records % limits.batch_size = 0 then Scheduler.yield () else return () in
      if !output > limits.max_output_bytes then return `Truncated
      else match Model.parse ~request:run.request raw with
      | Error _ -> return (`Failed "Invalid structured literal-search output from ripgrep")
      | Ok hits ->
        match%bind add hits with `Truncated -> return `Truncated | `Continue -> loop ()
  in
  let%bind result = loop () in
  let%map () = flush () in result
;;
let cleanup run =
  match run.process with
  | None -> return (Ok ())
  | Some process ->
    let%bind exit = Process.wait process in
    let%map () = Deferred.all_unit
      [ Writer.close (Process.stdin process); Reader.close (Process.stdout process)
      ; Reader.close (Process.stderr process) ] in
    run.process <- None;
    exit
;;
let worker t run =
  let%bind created = Process.create ~prog:t.prog ~working_dir:run.request.root ~buf_len:4096
    ~args:(Ches_file_picker.Scope.rg_args
           @ [ "--json"; "--fixed-strings"; "--case-sensitive"; "--line-number"
             ; "--color"; "never"; "--"; run.request.query; "." ]) () in
  match created with
  | Error _ ->
    run.terminal <- Some (Status.Failed
      "Could not start ripgrep. Install ripgrep (rg), check PATH and project access, then retry.");
    return ()
  | Ok process ->
    run.process <- Some process;
    if run.stopped then kill run;
    let timer = Clock_ns.Event.run_after t.limits.timeout (fun () ->
      if not (Ivar.is_full run.finished) && not run.stopped then (
        run.timed_out <- true; Ivar.fill_if_empty run.abort (); kill run)) () in
    upon (finished run) (fun () -> Clock_ns.Event.abort_if_possible timer ());
    let stderr = Monitor.try_with (fun () -> stderr_prefix (Process.stderr process)) in
    let%bind result = Monitor.try_with (fun () -> collect run t.limits (Process.stdout process)) in
    (match result with Ok `Complete -> () | _ -> kill run);
    let%bind exit = cleanup run in
    let%bind stderr = stderr in
    Clock_ns.Event.abort_if_possible timer ();
    let status =
      if run.timed_out then Status.Failed "On-disk search timed out; narrow query or project root."
      else match result with
      | Ok `Truncated -> Status.Complete { truncated = true }
      | Ok (`Failed message) -> Status.Failed message
      | Error _ -> Status.Failed "Could not read ripgrep search output."
      | Ok `Complete ->
        match exit with
        | Ok () | Error (`Exit_non_zero 1) -> Status.Complete { truncated = false }
        | Error _ -> Status.Failed ("ripgrep search failed; check project access. "
            ^ Model.Candidate.display_text (Result.ok stderr |> Option.value ~default:""))
    in
    run.terminal <- Some status;
    return ()
;;
let safe_worker t run =
  let%bind result = Monitor.try_with (fun () -> worker t run) in
  let%bind () = match result with
    | Ok () -> return ()
    | Error _ ->
      kill run;
      let%map _ = cleanup run in
      run.terminal <- Some (Status.Failed "Unexpected on-disk search failure; retry.")
  in
  Pipe.close run.writer;
  Ivar.fill_if_empty run.finished ();
  return ()
;;
let start t ~root ~query =
  let validation =
    if String.length root > 4096 || String.length query > 4096
       || String.exists query ~f:(fun c -> Char.equal c '\000' || Char.equal c '\n' || Char.equal c '\r')
    then Or_error.error_string "Search requires root/query <= 4 KiB and a single-line NUL-free literal"
    else Model.Candidate.create ~root ~relative_path:"root-validation"
  in
  match validation with
  | Error error -> Error error
  | Ok candidate ->
    let previous = t.reaped in
    cancel t;
    t.next_id <- t.next_id + 1;
    let reader, writer = Pipe.create () in
    Pipe.set_size_budget reader 0;
    let request : Model.request =
      { run_id = Model.Run_id.of_int t.next_id; root = Model.Candidate.root candidate; query } in
    let run =
      { request; reader; writer; finished = Ivar.create (); abort = Ivar.create ()
      ; terminal = None; process = None; stopped = false; timed_out = false } in
    t.active <- Some run; t.reaped <- finished run; t.hits_rev <- [];
    t.snapshot <- Some { request; hits = []; status = Status.Loading };
    don't_wait_for (
      let%bind () = previous in
      let%bind () = Deferred.any_unit
        [ Clock_ns.after t.limits.debounce; Ivar.read run.abort ] in
      if run.stopped || String.is_empty query then (
        run.terminal <- Some (Status.Complete { truncated = false });
        Pipe.close writer; Ivar.fill_if_empty run.finished (); return ())
      else safe_worker t run);
    Ok run
;;
let poll t ~max_batches =
  if max_batches <= 0 then invalid_arg "max_batches must be positive";
  match t.active with
  | None -> None
  | Some run ->
    (* The private reader belongs to this active request only. Replacement closes
       the old reader; workers never mutate snapshots. No obsolete query/root can
       cross this installation boundary, even if its process finishes late. *)
    let changed = ref false in
    let status = ref (Option.value_exn t.snapshot).status in
    let rec take n =
      if n > 0 && not run.stopped then
        match Pipe.read_now run.reader with
        | `Nothing_available -> ()
        | `Eof -> Option.iter run.terminal ~f:(fun terminal ->
            run.terminal <- None; status := terminal; changed := true)
        | `Ok hits ->
          t.hits_rev <- List.rev_append hits t.hits_rev;
          status := Status.Partial; changed := true; take (n - 1)
    in
    take max_batches;
    if not !changed then None
    else (
      t.snapshot <- Some { request = run.request; hits = List.rev t.hits_rev; status = !status };
      t.snapshot)
;;
