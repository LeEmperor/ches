open! Core
open! Async

module Runtime = Ches_terminal_host.Runtime
module Model = Ches_terminal.Model

type host =
  { runtime : Runtime.t
  ; mutable generation : int
  ; mutable snapshot : Model.snapshot option
  ; mutable failure : string option
  ; mutable snapshot_first : bool
  ; mutable queued : bool
  }

type t =
  { hosts : host Int.Table.t
  ; ready : int Queue.t
  ; mutable changed : unit Ivar.t
  ; closed : unit Ivar.t
  ; mutable finished : unit Deferred.t option
  }

let create () =
  { hosts = Int.Table.create ()
  ; ready = Queue.create ()
  ; changed = Ivar.create ()
  ; closed = Ivar.create ()
  ; finished = None
  }
;;

let enqueue t terminal host =
  if not host.queued then (
    host.queued <- true;
    Queue.enqueue t.ready terminal);
  Ivar.fill_if_empty t.changed ()
;;

let publish t terminal host (generation, event) =
  if generation >= host.generation then (
    if generation > host.generation then (
      host.generation <- generation;
      host.snapshot <- None;
      host.failure <- None;
      (* The runtime's first event establishes whether Start succeeded. Keep
         that ordering even when a failure and newer snapshots are coalesced. *)
      host.snapshot_first <- (match event with Model.Snapshot _ -> true | Failed _ -> false));
    (match event with
     | Model.Snapshot snapshot -> host.snapshot <- Some snapshot
     | Failed message -> host.failure <- Some message);
    enqueue t terminal host)
;;

let add_host t terminal =
  let host =
    { runtime = Runtime.create (); generation = 0; snapshot = None
    ; failure = None; snapshot_first = false; queued = false }
  in
  Hashtbl.add_exn t.hosts ~key:terminal ~data:host;
  (* Exactly one destructive backend read is outstanding per runtime. The only
     losing read is at permanent pool shutdown, never at a UI polling boundary. *)
  let rec drain () =
    let%bind update = Deferred.choose
      [ Deferred.choice (Ivar.read t.closed) (fun () -> None)
      ; Deferred.choice (Runtime.next_event_with_generation host.runtime) Option.some
      ] in
    match update with
    | None -> return ()
    | Some update when not (Ivar.is_full t.closed) ->
      publish t terminal host update;
      let%bind () = Scheduler.yield () in
      drain ()
    | Some _ -> return ()
  in
  don't_wait_for (drain ());
  host
;;

let submit_sessions t requests =
  if not (Ivar.is_full t.closed) then (
    (* Keep each backend batch atomic, including paste rejection semantics. IDs
       are keys, never a range to allocate or launch. *)
    let batches = Int.Table.create () in
    let order = Queue.create () in
    List.iter requests ~f:(fun (terminal, request) ->
      if terminal <= 0 then invalid_arg "terminal number must be positive";
      if not (Hashtbl.mem batches terminal) then Queue.enqueue order terminal;
      Hashtbl.add_multi batches ~key:terminal ~data:request);
    Queue.iter order ~f:(fun terminal ->
      let host = match Hashtbl.find t.hosts terminal with
        | Some host -> host
        | None -> add_host t terminal in
      Runtime.submit host.runtime (List.rev (Hashtbl.find_exn batches terminal))))
;;

let submit t requests = submit_sessions t (List.map requests ~f:(fun request -> 1, request))

let stop t = Hashtbl.iter t.hosts ~f:(fun host -> Runtime.stop host.runtime)

let shutdown t =
  match t.finished with
  | Some finished -> finished
  | None ->
    Ivar.fill_if_empty t.closed ();
    Ivar.fill_if_empty t.changed ();
    Queue.clear t.ready;
    Hashtbl.iter t.hosts ~f:(fun host ->
      host.snapshot <- None;
      host.failure <- None);
    let finished = Deferred.all_unit
      (List.map (Hashtbl.data t.hosts) ~f:(fun host -> Runtime.shutdown host.runtime)) in
    t.finished <- Some finished;
    finished
;;

let rec next_session_update t =
  if Ivar.is_full t.closed then return None
  else match Queue.dequeue t.ready with
  | Some terminal ->
    let host = Hashtbl.find_exn t.hosts terminal in
    host.queued <- false;
    let event = match host.snapshot, host.failure with
      | Some snapshot, _ when host.snapshot_first ->
        host.snapshot_first <- false;
        host.snapshot <- None;
        Model.Snapshot snapshot
      | _, Some message -> host.failure <- None; Model.Failed message
      | Some snapshot, None -> host.snapshot <- None; Model.Snapshot snapshot
      | None, None -> assert false in
    (* Requeue at the tail: a noisy shell gets at most one turn before every
       other ready shell, independent of its output rate. *)
    if Option.is_some host.snapshot || Option.is_some host.failure
    then enqueue t terminal host;
    return (Some (terminal, host.generation, event))
  | None ->
    if Ivar.is_full t.changed then t.changed <- Ivar.create ();
    let%bind () = Ivar.read t.changed in
    next_session_update t
;;

let next_update t =
  let%map update = next_session_update t in
  Option.map update ~f:(fun (_, generation, event) -> generation, event)
;;

let next_event t =
  let%map update = next_update t in
  Option.map update ~f:snd
;;
