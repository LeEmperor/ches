open! Core
open! Async
open Ches_source

let%expect_test "many resource lifetimes release drivers exactly once" =
  let active = ref 0 and created = ref 0 and stopped = ref 0 in
  let manager = Workspace.start ~create:(fun _ ->
    incr active; incr created;
    Some (Source.create (fun ~emit:_ ->
      { handle = ignore; stop = (fun () -> decr active; incr stopped) }))) () in
  List.iter (List.init 64 ~f:Fn.id) ~f:(fun n ->
    Source.send manager (Document_opened { resource = sprintf "/file-%d.ml" n; generation = n }));
  assert (!active = 64);
  List.iter (List.init 64 ~f:Fn.id) ~f:(fun n ->
    let resource = sprintf "/file-%d.ml" n in
    Source.send manager (Document_closed { resource });
    Source.send manager (Document_closed { resource }));
  assert (!active = 0 && !stopped = 64);
  List.iter (List.init 32 ~f:Fn.id) ~f:(fun n ->
    Source.send manager (Document_opened { resource = sprintf "/file-%d.ml" n; generation = 100 + n }));
  Source.stop manager; Source.stop manager;
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (!active = 0 && !created = 96 && !stopped = 96);
  printf "96 runtimes released; close and shutdown idempotent\n";
  [%expect {| 96 runtimes released; close and shutdown idempotent |}];
  return ()
;;

let%expect_test "per-resource runtimes route writes, stop only on close, and tag late batches" =
  let requests = String.Table.create () in
  let stops = String.Table.create () in
  let emitters = String.Table.create () in
  let created = ref 0 in
  let manager = Workspace.start ~create:(fun resource ->
    incr created;
    Some (Source.create (fun ~emit ->
      Hashtbl.set emitters ~key:resource ~data:emit;
      { handle = (fun request -> Hashtbl.add_multi requests ~key:resource ~data:request)
      ; stop = (fun () -> Hashtbl.update stops resource ~f:(fun n -> Option.value n ~default:0 + 1)) }))) () in
  let send = Source.send manager in
  send (Document_opened { resource = "/a.ml"; generation = 1 });
  send (Document_changed { resource = "/a.ml"; text = "A"; revision = 7 });
  send (Document_opened { resource = "/b.ml"; generation = 2 });
  send (Document_changed { resource = "/b.ml"; text = "B"; revision = 3 });
  send (Document_saved { resource = "/a.ml"; revision = 7 });
  assert (!created = 2 && Hashtbl.is_empty stops);
  assert (List.exists (Hashtbl.find_multi requests "/a.ml") ~f:(function Document_saved { resource; revision = 7 } -> String.equal resource "/a.ml" | _ -> false));
  assert (not (List.exists (Hashtbl.find_multi requests "/b.ml") ~f:(function Document_saved _ -> true | _ -> false)));
  let emit_a = Hashtbl.find_exn emitters "/a.ml" in
  emit_a (Started { source = "lsp"; root = "/" });
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  let events = Source.poll manager in
  assert (List.exists events ~f:(function Owned { resource = "/a.ml"; generation = 1; event = Started { source = "lsp#1"; _ } } -> true | _ -> false));
  send (Document_closed { resource = "/a.ml" });
  assert (Hashtbl.find_exn stops "/a.ml" = 1 && not (Hashtbl.mem stops "/b.ml"));
  emit_a (Started { source = "late"; root = "/" });
  send (Document_opened { resource = "/a.ml"; generation = 3 });
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (List.is_empty (Source.poll manager));
  send (Document_changed { resource = "/a.ml"; text = "new"; revision = 0 });
  assert (!created = 3);
  Source.stop manager;
  assert (Hashtbl.find_exn stops "/a.ml" = 2 && Hashtbl.find_exn stops "/b.ml" = 1);
  print_endline "addressed saves; persistent sibling; lifetime tags; close/shutdown cleanup";
  [%expect {| addressed saves; persistent sibling; lifetime tags; close/shutdown cleanup |}];
  return ()
;;
