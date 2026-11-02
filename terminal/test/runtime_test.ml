open! Core
open! Async
open Ches_terminal
module R = Ches_terminal_host.Runtime

let hosts : R.t list ref = ref []
let create () : R.t =
  let t : R.t = R.create () in
  hosts := t :: !hosts;
  t
;;

let check (condition : bool) (message : string) : unit =
  if not condition then failwith message
;;

let screen (snapshot : Model.snapshot) : string =
  Array.to_list snapshot.rows
  |> List.map ~f:(fun row ->
    Array.to_list row
    |> List.map ~f:(fun (cell : Model.cell) -> cell.text)
    |> String.concat)
  |> String.concat ~sep:"\n"
;;

let rec wait (t : R.t) ~(label : string) ~(f : Model.snapshot -> bool) : Model.snapshot Deferred.t =
  let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 8) (R.next_event t) in
  match result with
  | `Timeout -> failwith ("terminal timed out: " ^ label)
  | `Result (Failed message) -> failwith ("terminal failure: " ^ message)
  | `Result (Snapshot snapshot) ->
    if f snapshot then return snapshot else wait t ~label ~f
;;

let contains (needle : string) (snapshot : Model.snapshot) : bool =
  String.is_substring (screen snapshot) ~substring:needle
;;

let command (t : R.t) (text : string) : unit =
  R.submit t [ Paste text; Key { code = Enter; modifiers = Model.no_modifiers } ]
;;

let process_running (pid : int) : bool =
  try
    let stat : string = In_channel.read_all (sprintf "/proc/%d/stat" pid) in
    let end_name : int = String.rindex_exn stat ')' in
    not (Char.equal stat.[end_name + 2] 'Z')
  with
  | _ -> false
;;

let rec await_process_gone (pid : int) (remaining : int) : unit Deferred.t =
  if not (process_running pid) then return ()
  else if remaining = 0 then failwith "PTY-owned background job survived shutdown"
  else (
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 20.) in
    await_process_gone pid (remaining - 1))
;;

let main () : unit Deferred.t =
  Core_unix.putenv ~key:"SHELL" ~data:"/bin/sh";
  Core_unix.putenv ~key:"PS1" ~data:"";
  let t : R.t = create () in
  R.submit t [ Start { cwd = "/tmp"; rows = 16; cols = 100 } ];
  command t "stty -echo; test -t 0 && test -t 1 && test -r /dev/tty && printf 'TTY_%s\\n' OK; printf 'TERM_%s\\n' \"$TERM\"; pwd";
  let%bind initial = wait t ~label:"controlling PTY, environment and cwd" ~f:(fun s -> contains "TTY_OK" s && contains "TERM_xterm-256color" s && contains "/tmp" s) in
  check (Option.is_none initial.exited) "shell should be live";
  command t "CHES_STATE=persistent; printf 'STATE_%s\\n' \"$CHES_STATE\"";
  let%bind _ = wait t ~label:"set shell state" ~f:(contains "STATE_persistent") in
  command t "printf 'AGAIN_%s\\n' \"$CHES_STATE\"";
  let%bind _ = wait t ~label:"persistent shell" ~f:(contains "AGAIN_persistent") in
  R.submit t [ Resize { rows = 20; cols = 90 } ];
  command t "printf 'SIZE_'; stty size";
  let%bind resized = wait t ~label:"PTY resize" ~f:(contains "SIZE_20 90") in
  check (Array.length resized.rows = 20 && Array.length resized.rows.(0) = 90) "emulator resize";
  (* No event consumer during this interval. Output must still be drained. *)
  command t "i=0; while [ \"$i\" -lt 6000 ]; do printf 'flood_%s\\n' \"$i\"; i=$((i+1)); done; printf 'HIDDEN_%s\\n' DONE";
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 600.) in
  let%bind _ = wait t ~label:"hidden output drain and coalescing" ~f:(contains "HIDDEN_DONE") in
  command t "sleep 30";
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 150.) in
  R.submit t [ Key { code = Char (Uchar.of_char 'C'); modifiers = { Model.no_modifiers with ctrl = true } } ];
  command t "printf 'INTERRUPT_%s\\n' OK";
  let%bind _ = wait t ~label:"Ctrl-C interrupts foreground job" ~f:(contains "INTERRUPT_OK") in
  command t "stty -echo -icanon min 1 time 0; printf 'BULK_%s\\n' READY; dd bs=1024 count=128 iflag=fullblock of=/dev/null 2>/dev/null; stty icanon; printf 'BULK_%s\\n' DONE";
  let%bind _ = wait t ~label:"bulk input reader ready" ~f:(contains "BULK_READY") in
  R.submit t [ Paste (String.make 131072 'x') ];
  let%bind _ = wait t ~label:"partial nonblocking input writes" ~f:(contains "BULK_DONE") in
  (* Rejected batches must drop both earlier staged input and trailing Enter.
     The old implementation accepted this assignment and executed it anyway. *)
  R.submit t [ Paste "CHES_REJECTED=bad"; Paste (String.make (1024 * 1024 + 1) 'x')
             ; Key { code = Enter; modifiers = Model.no_modifiers } ];
  let%bind overflow = R.next_event t in
  check (match overflow with Failed _ -> true | Snapshot _ -> false) "oversized input is bounded";
  command t "printf 'ATOMIC_%s\\n' \"${CHES_REJECTED:-ok}\"";
  let%bind _ = wait t ~label:"failed input batch leaves no prefix or suffix" ~f:(contains "ATOMIC_ok") in
  command t "printf 'LINE_%s\\n' A\r\nprintf 'LINE_%s\\n' B";
  let%bind _ = wait t ~label:"multiline CRLF paste" ~f:(fun s -> contains "LINE_A" s && contains "LINE_B" s) in
  command t "printf 'FINAL_%s\\n' SCREEN; exit 7";
  let%bind exited = wait t ~label:"child exit" ~f:(fun s -> Option.is_some s.exited) in
  check (contains "FINAL_SCREEN" exited) "retained exit screen";
  check (Option.equal String.equal exited.exited (Some "exited 7")) "exit code";
  R.submit t [ Start { cwd = "/tmp"; rows = 8; cols = 80 } ];
  command t "stty -echo; printf 'RESTART_%s\\n' OK";
  let%bind restarted = wait t ~label:"restart exited shell" ~f:(contains "RESTART_OK") in
  check (Option.is_none restarted.exited && Array.length restarted.rows = 8) "restart generation";
  command t "trap '' HUP; printf 'IGNORE_%s\\n' HUP; while :; do :; done";
  let%bind _ = wait t ~label:"termination resistant child ready" ~f:(contains "IGNORE_HUP") in
  let%bind shutdown = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 3) (R.shutdown t) in
  check (match shutdown with `Result () -> true | `Timeout -> false) "bounded shutdown escalates SIGKILL";
  let%bind _ = wait t ~label:"shutdown exit snapshot" ~f:(fun s -> Option.is_some s.exited) in
  let%bind () = R.shutdown t in
  let idle : R.t = create () in
  R.submit idle [ Start { cwd = "/"; rows = 0; cols = 80 } ];
  let%bind invalid = R.next_event idle in
  check (match invalid with Failed _ -> true | Snapshot _ -> false) "invalid dimensions report failure";
  R.submit idle [ Start { cwd = "/ches-terminal-nonexistent-directory"; rows = 8; cols = 80 } ];
  let%bind bad_cwd = wait idle ~label:"failed child setup" ~f:(fun s -> Option.is_some s.exited) in
  check (Option.equal String.equal bad_cwd.exited (Some "exited 126")) "child setup exit status";
  Core_unix.putenv ~key:"SHELL" ~data:"/ches-terminal-nonexistent-shell";
  R.submit idle [ Start { cwd = "/tmp"; rows = 8; cols = 80 } ];
  command idle "printf 'FALLBACK_%s\\n' OK; exit";
  let%bind fallback = wait idle ~label:"fallback shell and PTY EOF" ~f:(fun s -> Option.is_some s.exited) in
  check (contains "FALLBACK_OK" fallback) "fallback /bin/sh";
  let%bind () = R.shutdown idle in
  (* A failed restart also advances generation and discards the old retained
     snapshot, so an exited frame cannot arrive after its startup failure. *)
  let generations : R.t = create () in
  R.submit generations [ Start { cwd = "/tmp"; rows = 3; cols = 30 } ];
  R.submit generations [ Paste (String.make (1024 * 1024 + 1) 'x') ];
  let%bind generation, event = R.next_event_with_generation generations in
  check (generation = 1 && match event with Snapshot s -> Option.is_none s.exited | _ -> false) "initial live state precedes rejected input";
  let%bind generation, event = R.next_event_with_generation generations in
  check (generation = 1 && match event with Failed _ -> true | _ -> false) "first generation input failure";
  command generations "exit 0";
  let%bind _ = wait generations ~label:"generation fixture exit" ~f:(fun s -> Option.is_some s.exited) in
  R.submit generations [ Start { cwd = "/"; rows = 0; cols = 30 } ];
  let%bind generation, event = R.next_event_with_generation generations in
  check (generation = 2 && match event with Failed _ -> true | _ -> false) "failed restart generation";
  R.submit generations [ Start { cwd = "/tmp"; rows = 4; cols = 40 } ];
  let%bind generation, event = R.next_event_with_generation generations in
  check (generation = 3 && match event with Snapshot s -> Option.is_none s.exited && Array.length s.rows = 4 | _ -> false) "restart snapshot generation";
  let%bind () = R.shutdown generations in
  let survivor : R.t = create () in
  let victim : R.t = create () in
  R.submit survivor [ Start { cwd = "/tmp"; rows = 8; cols = 100 } ];
  command survivor "stty -echo; CHES_OWNER=survivor; printf 'OWNER_%s\\n' READY";
  let%bind _ = wait survivor ~label:"independent session ready" ~f:(contains "OWNER_READY") in
  R.submit victim [ Start { cwd = "/tmp"; rows = 8; cols = 100 } ];
  command victim "stty -echo; printf 'VICTIM_%s\\n' READY";
  let%bind _ = wait victim ~label:"victim echo disabled" ~f:(contains "VICTIM_READY") in
  command victim "(trap '' HUP; while :; do sleep 1; done) & CHES_BG=$!; printf 'BG_PID_%s\\n' \"$CHES_BG\"";
  let%bind background = wait victim ~label:"background job ready" ~f:(contains "BG_PID_") in
  let output : string = screen background in
  let start : int = String.substr_index_exn output ~pattern:"BG_PID_" + 7 in
  let digits : string = String.drop_prefix output start |> String.take_while ~f:Char.is_digit in
  let pid : int = Int.of_string digits in
  check (process_running pid) "background fixture is live";
  let%bind () = R.shutdown victim in
  let%bind () = await_process_gone pid 50 in
  command survivor "printf 'STILL_%s\\n' \"$CHES_OWNER\"";
  let%bind _ = wait survivor ~label:"shutdown leaves unrelated PTY session alive" ~f:(contains "STILL_survivor") in
  let%bind () = R.shutdown survivor in
  print_endline "terminal PTY runtime tests passed";
  return ()
;;

let () =
  don't_wait_for
    (let%bind result = Monitor.try_with (fun () ->
       Monitor.protect main ~finally:(fun () -> Deferred.List.iter !hosts ~how:`Sequential ~f:R.shutdown)) in
     match result with
     | Ok () -> Shutdown.exit 0
     | Error exn ->
       eprintf "%s\n%!" (Exn.to_string exn);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
