open! Core
open! Async
module Protocol = Ches_harness.Protocol
module Vcd = Ches_harness.Vcd

type t = { mutable process : Process.t option; mutable stopped : bool }
let create () = { process = None; stopped = false }
let stop t =
  t.stopped <- true;
  (* qh handles SIGINT by killing its active tool group and saving the run. *)
  Option.iter t.process ~f:(fun process -> Process.send_signal process Signal.int)
;;

let env name = Sys.getenv name |> Option.filter ~f:(Fn.non String.is_empty)
let home () = Option.value_exn (env "HOME") ~message:"Set HOME or QH_SCRATCH_ROOT"
let absolute path = if Filename.is_relative path then Filename.concat (Core_unix.getcwd ()) path else path

let executable () =
  match env "QH_BIN" with
  | Some path -> path
  | None ->
    (match env "HOME" with
     | None -> "qh"
     | Some home ->
       let local = Filename.concat home "devel/Quick-Harness/bin/qh" in
       if Stdlib.Sys.file_exists local then local else "qh")
;;

let scratch language =
  let root = absolute (Option.value_or_thunk (env "QH_SCRATCH_ROOT")
    ~default:(fun () -> Filename.concat (home ()) "scratch/ches")) in
  Core_unix.mkdir_p root;
  (* Reserve a unique container atomically. qh itself refuses an existing target. *)
  let container = Filename_unix.temp_dir ~in_dir:root ("qh-" ^ language ^ "-") "" in
  Filename.concat container "project"
;;

let project location =
  let location = absolute location in
  let start = if Stdlib.Sys.is_directory location then location else Filename.dirname location in
  let rec find directory =
    if Stdlib.Sys.file_exists (Filename.concat directory "quick-harness.json") then directory
    else let parent = Filename.dirname directory in
      if String.equal parent directory then failwith ("No quick-harness.json above " ^ location)
      else find parent in
  find start
;;

let read_wave path =
  Or_error.try_with (fun () ->
    let fd = Core_unix.openfile path ~mode:[O_RDONLY; O_NONBLOCK; O_CLOEXEC] in
    Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
      let stat = Core_unix.fstat fd in
      (match stat.st_kind with S_REG -> () | _ -> failwith "VCD must be a regular file");
      let bytes = Bytes.create (Vcd.max_bytes + 1) in
      let rec read pos =
        if pos > Vcd.max_bytes then failwith "VCD exceeds 16 MiB demo limit";
        match Core_unix.read fd ~buf:bytes ~pos ~len:(Vcd.max_bytes + 1 - pos) with
        | 0 -> Bytes.to_string (Bytes.sub bytes ~pos:0 ~len:pos)
        | n -> read (pos + n) in
      read 0))
  |> Or_error.bind ~f:Vcd.parse
  |> Result.map_error ~f:Error.to_string_hum
;;

let execute t ({ Protocol.action = request; location; dirty } : Protocol.work) =
  let%bind result = Monitor.try_with ~extract_exn:true (fun () ->
    if t.stopped then failwith "Quick-Harness host stopped";
    let%bind args = In_thread.run (fun () ->
      let args = match request with
        | "new-sv" | "new-hardcaml" | "new-ocaml" ->
          let language = String.drop_prefix request 4 in
          ["new"; language; scratch language]
        | "run" ->
          let root = project location |> Filename_unix.realpath in
          List.iter dirty ~f:(fun path ->
            let path = try Filename_unix.realpath path with _ -> absolute path in
            if String.is_prefix path ~prefix:(root ^ "/") then
              failwith ("Save modified project buffer before running Quick-Harness: " ^ path));
          ["run"; "--project"; root; "--jobs"; "6"]
        | "latest" | "log" -> ["latest"; "--project"; project location]
        | _ -> failwith ("Unknown Quick-Harness request: " ^ request) in
      executable (), args @ ["--format"; "json"]) in
    if t.stopped then failwith "Quick-Harness host stopped";
    let prog, args = args in
    let%bind process = Process.create_exn ~prog ~args () in
    t.process <- Some process;
    if t.stopped then Process.send_signal process Signal.int;
    let%bind output = Process.collect_output_and_wait process in
    t.process <- None;
    let reply = match Protocol.parse output.stdout with
      | Ok reply -> reply
      | Error error -> failwith (Error.to_string_hum error ^ " " ^ String.prefix output.stderr 2048) in
    let%map wave = match reply with
      | Protocol.Finished run when not (String.equal request "log") ->
        (match run.waveform with
         | None -> return None
         | Some path -> In_thread.run (fun () -> Some (read_wave path)))
      | Created _ | Finished _ -> return None in
    reply, wave) in
  return (Result.map_error result ~f:(function Failure message -> message | exn -> Exn.to_string exn))
;;
