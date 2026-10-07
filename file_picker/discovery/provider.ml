open! Core
open! Async
module Model = Ches_file_picker.Model
module Candidate = Model.Candidate
module Discovery = Model.Discovery

module Limits = struct
  type t =
    { max_candidates : int
    ; max_path_bytes : int
    ; max_total_path_bytes : int
    ; max_output_bytes : int
    ; batch_size : int
    ; timeout : Time_ns.Span.t
    }

  let default =
    { max_candidates = 50_000
    ; max_path_bytes = 4096
    ; max_total_path_bytes = 8 * 1024 * 1024
    ; max_output_bytes = 32 * 1024 * 1024
    ; batch_size = 128
    ; timeout = Time_ns.Span.of_sec 30.
    }
  ;;
end

type delivery =
  { request : Discovery.request
  ; candidates : Candidate.t list
  ; status : Discovery.status
  }

type run =
  { request : Discovery.request
  ; reader : delivery Pipe.Reader.t
  ; writer : delivery Pipe.Writer.t
  ; finished : unit Ivar.t
  ; abort_delivery : unit Ivar.t
  ; mutable terminal : Discovery.status option
  ; mutable process : Process.t option
  ; mutable stopped : bool
  ; mutable timed_out : bool
  }

type t =
  { prog : string
  ; limits : Limits.t
  ; mutable next_id : int
  ; mutable active : run option
  ; mutable candidates : Candidate.t String.Map.t
  ; mutable snapshot : Discovery.t option
  ; mutable reaped : unit Deferred.t
  }

let create ?(prog = "rg") ?(limits = Limits.default) () =
  if List.exists
       [ limits.max_candidates; limits.max_path_bytes; limits.max_total_path_bytes
       ; limits.max_output_bytes; limits.batch_size
       ] ~f:(fun n -> n <= 0)
     || Time_ns.Span.(limits.timeout <= zero)
  then invalid_arg "File discovery limits must be positive";
  { prog; limits; next_id = 0; active = None; candidates = String.Map.empty
  ; snapshot = None; reaped = return () }
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
    Ivar.fill_if_empty run.abort_delivery ();
    Pipe.close_read run.reader;
    kill run;
    t.snapshot <- Option.map t.snapshot ~f:(fun snapshot ->
      { snapshot with status = Discovery.Cancelled }));
  t.active <- None
;;

let deliver run candidates status =
  if run.stopped || run.timed_out then return ()
  else Deferred.any_unit
    [ Pipe.write_if_open run.writer { request = run.request; candidates; status }
    ; Ivar.read run.abort_delivery
    ]
;;

(* Always drain stderr concurrently; retain only a bounded diagnostic prefix.
   Chunk reads, unlike line reads, also bound memory for newline-free errors. *)
let stderr_prefix reader =
  let buffer = Bytes.create 4096 in
  let prefix = Buffer.create 8192 in
  let rec loop () =
    let%bind read = Reader.read reader buffer in
    match read with
    | `Eof -> return (Buffer.contents prefix)
    | `Ok n ->
      let keep = Int.min n (8192 - Buffer.length prefix) in
      Buffer.add_subbytes prefix buffer ~pos:0 ~len:keep;
      let%bind () = Scheduler.yield () in
      loop ()
  in
  loop ()
;;

let collect run (limits : Limits.t) reader =
  let seen = ref String.Set.empty in
  let retained_bytes = ref 0 in
  let output_bytes = ref 0 in
  let batch = ref [] in
  let batch_count = ref 0 in
  let records = ref 0 in
  let flush () =
    let candidates = List.rev !batch in
    batch := [];
    batch_count := 0;
    if List.is_empty candidates then return () else deliver run candidates Discovery.Partial
  in
  let rec loop () =
    if run.stopped || run.timed_out then return (`Failed "File discovery stopped")
    else (
      let%bind record =
        Reader.read_until_bounded reader (`Char '\000') ~keep_delim:false
          ~max:limits.max_path_bytes
      in
      match record with
      | `Eof -> return `Complete
      | `Max_exceeded _ -> return `Truncated
      | `Eof_without_delim _ -> return (`Failed "ripgrep returned an unterminated path")
      | `Ok raw ->
        incr records;
        (* Even duplicate/hidden records must yield, not only emitted batches. *)
        let%bind () =
          if !records % limits.batch_size = 0 then Scheduler.yield () else return ()
        in
        output_bytes := !output_bytes + String.length raw + 1;
        let path = Option.value (String.chop_prefix raw ~prefix:"./") ~default:raw in
        if !output_bytes > limits.max_output_bytes then return `Truncated
        else if Set.mem !seen path then loop ()
        else (
          match Candidate.create ~root:run.request.root ~relative_path:path with
          | Error _ -> return (`Failed "ripgrep returned an invalid relative path")
          | Ok candidate ->
            let candidate_bytes =
              String.length (Candidate.root candidate)
              + String.length (Candidate.path candidate)
              + String.length (Candidate.relative_path candidate)
              + String.length (Candidate.display_path candidate)
            in
            (* Enforce policy even if the executable's defaults/config change. *)
             if not (Ches_file_picker.Scope.visible_path path)
            then loop ()
            else if Set.length !seen >= limits.max_candidates
                    || !retained_bytes + candidate_bytes > limits.max_total_path_bytes
            then return `Truncated
            else (
              seen := Set.add !seen path;
              retained_bytes := !retained_bytes + candidate_bytes;
              batch := candidate :: !batch;
              incr batch_count;
              let%bind () = if !batch_count >= limits.batch_size then flush () else return () in
              loop ())))
  in
  let%bind result = loop () in
  let%map () = flush () in
  result
;;

let worker t run =
  let%bind created =
    Process.create ~prog:t.prog
      ~args:(Ches_file_picker.Scope.rg_args @ [ "--files"; "--null"; "--"; "." ])
      ~working_dir:run.request.root ~buf_len:4096 ()
  in
  match created with
  | Error _ ->
    run.terminal <- Some (Discovery.Failed
      "Could not start ripgrep file discovery. Install ripgrep (rg), check PATH and the project directory, then retry.");
    Pipe.close run.writer;
    Ivar.fill_if_empty run.finished ();
    return ()
  | Ok process ->
    run.process <- Some process;
    if run.stopped then kill run;
    let timer =
      Clock_ns.Event.run_after t.limits.timeout (fun () ->
      if not (Ivar.is_full run.finished) && not run.stopped then (
        run.timed_out <- true;
        Ivar.fill_if_empty run.abort_delivery ();
        kill run)) ()
    in
    upon (finished run) (fun () -> Clock_ns.Event.abort_if_possible timer ());
    let stderr = Monitor.try_with (fun () -> stderr_prefix (Process.stderr process)) in
    let%bind result = Monitor.try_with (fun () -> collect run t.limits (Process.stdout process)) in
    (match result with
     | Ok `Complete -> ()
     | Ok (`Truncated | `Failed _) | Error _ -> kill run);
    let%bind exit = Process.wait process in
    let%bind () = Deferred.all_unit
      [ Writer.close (Process.stdin process)
      ; Reader.close (Process.stdout process)
      ; Reader.close (Process.stderr process)
      ]
    in
    let%bind stderr = stderr in
    Clock_ns.Event.abort_if_possible timer ();
    run.process <- None;
    Ivar.fill_if_empty run.finished ();
    let status =
      if run.timed_out then Discovery.Failed "File discovery timed out; retry or narrow the project root."
      else (
        match result with
        | Ok `Truncated -> Discovery.Complete { truncated = true }
        | Ok (`Failed message) -> Discovery.Failed message
        | Error _ -> Discovery.Failed "Could not read ripgrep file discovery output."
        | Ok `Complete ->
          (match exit with
           | Ok () | Error (`Exit_non_zero 1) -> Discovery.Complete { truncated = false }
           | Error _ ->
             let detail = Result.ok stderr |> Option.value ~default:"" in
             let detail =
               String.concat_map detail ~f:(fun c ->
                 let code = Char.to_int c in
                 if code < 32 || code > 126 then sprintf "\\x%02X" code
                 else if Char.equal c '\\' then "\\\\" else String.of_char c)
             in
             Discovery.Failed ("ripgrep failed; check project access and ignore rules. " ^ detail)))
    in
    run.terminal <- Some status;
    Pipe.close run.writer;
    return ()
;;

let safe_worker t run =
  let%bind result = Monitor.try_with (fun () -> worker t run) in
  match result with
  | Ok () -> return ()
  | Error _ ->
    kill run;
    let%bind () =
      match run.process with
      | None -> return ()
      | Some process ->
        let%bind _ = Process.wait process in
        Deferred.all_unit
          [ Writer.close (Process.stdin process)
          ; Reader.close (Process.stdout process)
          ; Reader.close (Process.stderr process)
          ]
    in
    run.process <- None;
    run.terminal <- Some (Discovery.Failed "Unexpected file discovery failure; retry.");
    Pipe.close run.writer;
    Ivar.fill_if_empty run.finished ();
    return ()
;;

let start t ~root =
  let validation =
    if String.length root > 4096 then Or_error.error_string "File picker root exceeds 4 KiB"
    else Candidate.create ~root ~relative_path:"root-validation"
  in
  match validation with
  | Error error -> Error error
  | Ok candidate ->
    let previous = t.reaped in
    cancel t;
    t.next_id <- t.next_id + 1;
    let reader, writer = Pipe.create () in
    Pipe.set_size_budget reader 0;
    let request : Discovery.request =
      { run_id = Model.Run_id.of_int t.next_id; root = Candidate.root candidate }
    in
    let run =
      { request; reader; writer; finished = Ivar.create (); abort_delivery = Ivar.create ()
      ; terminal = None; process = None
      ; stopped = false; timed_out = false }
    in
    t.active <- Some run;
    t.reaped <- finished run;
    t.candidates <- String.Map.empty;
    t.snapshot <- Some { request; candidates = []; status = Discovery.Loading };
    don't_wait_for (
      let%bind () = previous in
      if run.stopped then (
        Ivar.fill_if_empty run.finished ();
        return ())
      else safe_worker t run);
    Ok run
;;

let poll t ~max_batches =
  if max_batches <= 0 then invalid_arg "max_batches must be positive";
  match t.active with
  | None -> None
  | Some run ->
    let changed = ref false in
    let candidates_changed = ref false in
    let status = ref (Option.value_exn t.snapshot).status in
    let rec take remaining =
      if remaining > 0 then (
        match Pipe.read_now run.reader with
        | `Nothing_available -> ()
        | `Eof ->
          Option.iter run.terminal ~f:(fun terminal ->
            run.terminal <- None;
            status := terminal;
            changed := true)
        | `Ok delivery ->
          if not run.stopped
             && Model.Run_id.equal delivery.request.run_id run.request.run_id
             && String.equal delivery.request.root run.request.root
          then (
            List.iter delivery.candidates ~f:(fun candidate ->
              if String.equal (Candidate.root candidate) run.request.root then (
                t.candidates <- Map.set t.candidates
                  ~key:(Candidate.relative_path candidate) ~data:candidate;
                candidates_changed := true));
            status := delivery.status;
            changed := true);
          take (remaining - 1))
    in
    take max_batches;
    if !changed then (
      (* Interaction uses list identity to distinguish metadata-only updates.
         Completion/failure must not restart a fully published ranking. *)
      let candidates =
        if !candidates_changed then Map.data t.candidates
        else (Option.value_exn t.snapshot).candidates
      in
      t.snapshot <- Some
        { request = run.request; candidates; status = !status };
      t.snapshot)
    else None
;;
