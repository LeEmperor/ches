open! Core
open! Async
module Model = Ches_terminal.Model

module Host = Ches_ui.Terminal_host

let within deferred =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) deferred with
  | `Result value -> value
  | `Timeout -> failwith "terminal frontend shutdown/event deadline exceeded"
;;

let text (snapshot : Model.snapshot) =
  Array.to_list snapshot.rows
  |> List.map ~f:(fun row ->
    Array.to_list row |> List.map ~f:(fun (cell : Model.cell) -> cell.text)
    |> String.concat)
  |> String.concat ~sep:"\n"
;;

let command host terminal command =
  Host.submit_sessions host
    [ terminal, Paste command
    ; terminal, Key { code = Enter; modifiers = Model.no_modifiers }
    ]
;;

let rec wait_sessions host snapshots predicate =
  if predicate snapshots then return ()
  else
    let%bind update = within (Host.next_session_update host) in
    match update with
    | Some (terminal, generation, Snapshot snapshot) ->
      Hashtbl.set snapshots ~key:terminal ~data:(generation, snapshot);
      wait_sessions host snapshots predicate
    | Some (_, _, Failed message) -> failwith message
    | None -> failwith "pool closed before expected output"
;;

let contains snapshots terminal needle =
  Option.exists (Hashtbl.find snapshots terminal) ~f:(fun (_, snapshot) ->
    String.is_substring (text snapshot) ~substring:needle)
;;

let pid snapshots terminal marker =
  let output = text (snd (Hashtbl.find_exn snapshots terminal)) in
  let start = List.last_exn (String.substr_index_all output ~pattern:marker ~may_overlap:false)
    + String.length marker in
  Int.of_string (String.take_while (String.drop_prefix output start) ~f:Char.is_digit)
;;

let process_running pid =
  try
    let stat = In_channel.read_all (sprintf "/proc/%d/stat" pid) in
    not (Char.equal stat.[String.rindex_exn stat ')' + 2] 'Z')
  with _ -> false
;;

let%expect_test "numbered pool drains hidden shells fairly, keeps independent state and reaps all hosts" =
  let host = Host.create () in
  let snapshots = Int.Table.create () in
  let large = 1_000_000_007 in
  Monitor.protect
    (fun () ->
      Host.submit_sessions host
        [ 1, Start { cwd = "/"; rows = 12; cols = 100 }
        ; large, Start { cwd = "/tmp"; rows = 14; cols = 110 }
        ];
      command host 1 {|stty -echo; CHES_POOL=one; printf 'ONE_%s PID_%s\n' "$CHES_POOL" $$|};
      command host large {|stty -echo; CHES_POOL=two; printf 'TWO_%s PID_%s\n' "$CHES_POOL" $$|};
      let%bind () = wait_sessions host snapshots (fun s ->
        contains s 1 "ONE_one PID_" && contains s large "TWO_two PID_") in
      let first_pid = pid snapshots 1 "PID_" in
      let second_pid = pid snapshots large "PID_" in
      assert (first_pid <> second_pid);
      assert (process_running first_pid && process_running second_pid);
      (* No frontend reader while both shells exceed a PTY's output capacity. *)
      List.iter [ 1; large ] ~f:(fun terminal ->
        command host terminal
          "i=0; while [ $i -lt 6000 ]; do printf 'flood_%s\\n' $i; i=$((i+1)); done; printf 'HIDDEN_%s\\n' DONE");
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 800.) in
      let%bind () = wait_sessions host snapshots (fun s ->
        contains s 1 "HIDDEN_DONE" && contains s large "HIDDEN_DONE") in
      (* A continuously ready ID cannot monopolize the pool. *)
      command host 1 "while :; do printf 'NOISY\\n'; done";
      command host large {|printf 'FAIR_%s\n' "$CHES_POOL"|};
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 100.) in
      let rec fair turns =
        assert (turns < 8);
        let%bind update = within (Host.next_session_update host) in
        match update with
        | Some (terminal, 1, Snapshot snapshot)
          when terminal = large && String.is_substring (text snapshot) ~substring:"FAIR_two" ->
          return ()
        | Some (_, _, Failed message) -> failwith message
        | _ -> fair (turns + 1)
      in
      let%bind () = fair 0 in
      (* Stop one ID without affecting the persistent state of the other. *)
      Host.submit_sessions host [ 1, Stop ];
      let%bind () = wait_sessions host snapshots (fun s ->
        Option.exists (Hashtbl.find s 1) ~f:(fun (_, s) -> Option.is_some s.exited)) in
      assert (not (process_running first_pid));
      command host large {|printf 'STILL_%s PID_%s\n' "$CHES_POOL" $$|};
      let%bind () = wait_sessions host snapshots (fun s -> contains s large "STILL_two") in
      assert (pid snapshots large "PID_" = second_pid);
      Host.submit_sessions host [ 1, Start { cwd = "/"; rows = 8; cols = 90 } ];
      command host 1 {|stty -echo; printf 'NEW_%s PID_%s\n' "${CHES_POOL:-empty}" $$|};
      let%bind () = wait_sessions host snapshots (fun s -> contains s 1 "NEW_empty") in
      let generation, snapshot = Hashtbl.find_exn snapshots 1 in
      assert (generation = 2 && Array.length snapshot.rows = 8);
      let restarted_pid = pid snapshots 1 "PID_" in
      assert (restarted_pid <> first_pid);
      assert (fst (Hashtbl.find_exn snapshots large) = 1);
      (* Background children in both PTYs must die too, even when ignoring HUP. *)
      List.iter [ 1; large ] ~f:(fun terminal ->
        command host terminal
          "(trap '' HUP; while :; do sleep 1; done) & printf 'BG_%s\\n' $!");
      let%bind () = wait_sessions host snapshots (fun s ->
        contains s 1 "BG_" && contains s large "BG_") in
      let background = List.map [ 1; large ] ~f:(fun terminal -> pid snapshots terminal "BG_") in
      assert (List.for_all background ~f:process_running);
      Host.stop host;
      let%bind () = within (Host.shutdown host) in
      let rec reaped remaining =
        if List.exists (restarted_pid :: second_pid :: background) ~f:process_running then (
          assert (remaining > 0);
          let%bind () = Clock_ns.after (Time_ns.Span.of_ms 20.) in
          reaped (remaining - 1))
        else return () in
      let%bind () = reaped 50 in
      print_endline "independent numbered shells; hidden drain; fair delivery; restart isolation; all children reaped";
      [%expect {| independent numbered shells; hidden drain; fair delivery; restart isolation; all children reaped |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;

let%expect_test "mailboxes coalesce snapshots, preserve initial failure ordering and have no orphan readers" =
  let host = Host.create () in
  Monitor.protect
    (fun () ->
      Host.submit_sessions host
        [ 7, Start { cwd = "/"; rows = 3; cols = 30 }
        ; 7, Paste (String.make (1024 * 1024 + 1) 'x')
        ; 99, Start { cwd = "/"; rows = 0; cols = 30 }
        ];
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 80.) in
      let%bind first = within (Host.next_session_update host) in
      let%bind second = within (Host.next_session_update host) in
      let%bind third = within (Host.next_session_update host) in
      let updates = List.filter_map [ first; second; third ] ~f:Fn.id in
      assert (List.count updates ~f:(fun (id, _, _) -> id = 99) = 1);
      (match List.filter updates ~f:(fun (id, _, _) -> id = 7) with
       | [ (_, 1, Snapshot s); (_, 1, Failed _) ] -> assert (Option.is_none s.exited)
       | _ -> failwith "initial snapshot must precede rejected input");
      (* Hundreds of synchronous publications retain just the latest dimensions. *)
      for cols = 31 to 230 do
        Host.submit_sessions host [ 7, Resize { rows = 4; cols } ]
      done;
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 80.) in
      let%bind latest = within (Host.next_session_update host) in
      (match latest with
       | Some (7, 1, Snapshot s) -> assert (Array.length s.rows.(0) = 230)
       | _ -> failwith "missing coalesced snapshot");
      let pending = Host.next_session_update host in
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 30.) in
      assert (not (Deferred.is_determined pending));
      Host.submit_sessions host [ 99, Start { cwd = "/"; rows = 5; cols = 40 } ];
      let%bind update = within pending in
      (match update with
       | Some (99, 2, Snapshot s) -> assert (Array.length s.rows = 5)
       | _ -> failwith "pending consumer lost restart update");
      (* The same single consumer receives a later failure, not an abandoned read. *)
      let pending = Host.next_session_update host in
      Host.submit_sessions host [ 99, Paste (String.make (1024 * 1024 + 1) 'x') ];
      let rec failure pending =
        let%bind update = within pending in
        match update with
        | Some (99, 2, Model.Failed _) -> return ()
        | Some (_, _, Snapshot _) -> failure (Host.next_session_update host)
        | _ -> failwith "lost failure" in
      let%bind () = failure pending in
      print_endline "bounded latest snapshot; initial snapshot before failure; generation-safe pending delivery";
      [%expect {| bounded latest snapshot; initial snapshot before failure; generation-safe pending delivery |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;

let%expect_test "shutdown releases the idle event pump and rejects subsequent starts" =
  let host = Host.create () in
  let pending = Host.next_event host in
  assert (not (Deferred.is_determined pending));
  let%bind () = within (Host.shutdown host) in
  let%bind event = within pending in
  assert (Option.is_none event);
  Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
  let%bind event = within (Host.next_event host) in
  assert (Option.is_none event);
  let%bind () = within (Host.shutdown host) in
  print_endline "idle pump cancelled; closed host stays closed";
  [%expect {| idle pump cancelled; closed host stays closed |}];
  return ()
;;

let%expect_test "one runtime publishes a shell snapshot and shuts down with a waiter" =
  let host = Host.create () in
  Monitor.protect
    (fun () ->
      Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
      let%bind event = within (Host.next_event host) in
      (match event with
       | Some (Snapshot snapshot) ->
         assert (Array.length snapshot.rows = 3);
         assert (Array.for_all snapshot.rows ~f:(fun row -> Array.length row = 20))
       | Some (Failed error) -> failwith error
       | None -> failwith "terminal closed before its initial snapshot");
      let pending = Host.next_event host in
      Host.stop host;
      let%bind () = within (Host.shutdown host) in
      let%bind event = within pending in
      assert (Option.is_none event);
      print_endline "snapshot delivered; child shutdown awaited; pump cancelled";
      [%expect {| snapshot delivered; child shutdown awaited; pump cancelled |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;

let%expect_test "updates retain the generation of publication, not when the consumer began waiting" =
  let host = Host.create () in
  Monitor.protect
    (fun () ->
      let pending = Host.next_update host in
      Host.submit host [ Start { cwd = "/"; rows = 0; cols = 20 } ];
      let%bind event = within pending in
      (match event with
       | Some (1, Failed _) -> ()
       | _ -> failwith "failed Start lost its generation");
      let pending = Host.next_update host in
      Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
      let%bind event = within pending in
      (match event with
       | Some (2, Snapshot snapshot) -> assert (Option.is_none snapshot.exited)
       | _ -> failwith "restarted shell lost its generation");
      print_endline "failed and successful starts retain distinct generations";
      [%expect {| failed and successful starts retain distinct generations |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;
