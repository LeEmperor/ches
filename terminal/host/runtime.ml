open! Core
open! Async
open Ches_terminal
module Emulator = Ches_terminal_emulator.Emulator

type session =
  { pty : Pty.t
  ; emulator : Emulator.t
  ; writes : string Queue.t
  ; mutable write_pos : int
  ; mutable queued_bytes : int
  ; mutable eof : bool
  ; mutable stopping_at : Time_ns.t option
  ; mutable dirty : bool
  }

type t =
  { mutable session : session option
  ; mutable generation : int
  ; mutable announce_generation : bool
  ; mutable snapshot : (int * Model.snapshot) option
  ; mutable failure : (int * string) option
  ; mutable waiter : unit Ivar.t
  ; mutable closed : bool
  ; mutable loop_running : bool
  ; mutable done_ : unit Ivar.t
  }

let max_input : int = 1024 * 1024
let tick : Time_ns.Span.t = Time_ns.Span.of_ms 10.

let wake (t : t) : unit = Ivar.fill_if_empty t.waiter ()
let failed (t : t) (message : string) : unit =
  t.failure <- Some (t.generation, message);
  wake t
;;

let publish (t : t) (session : session) ~(exited : string option) : unit =
  t.snapshot <- Some (t.generation, Emulator.snapshot session.emulator ~exited);
  session.dirty <- false;
  wake t
;;

let enqueue (session : session) (bytes : string) : unit =
  let length : int = String.length bytes in
  if length > max_input - session.queued_bytes
  then failwith "terminal input queue exceeds 1 MiB";
  if length > 0
  then (
    Queue.enqueue session.writes bytes;
    session.queued_bytes <- session.queued_bytes + length)
;;

let read_output (session : session) : unit =
  (* Bound per-turn work even if the child continuously floods output. *)
  let rec loop (remaining : int) : unit =
    if remaining > 0 && not session.eof
    then (
      match Pty.read session.pty with
      | None -> ()
      | Some "" -> session.eof <- true
      | Some bytes ->
        enqueue session (Emulator.feed session.emulator bytes);
        session.dirty <- true;
        loop (remaining - String.length bytes))
  in
  loop 65536
;;

let write_input (session : session) : unit =
  let rec loop (remaining : int) : unit =
    if remaining > 0 && not session.eof
    then (
      match Queue.peek session.writes with
      | None -> ()
      | Some bytes ->
        let written : int = Pty.write session.pty bytes ~pos:session.write_pos in
        session.write_pos <- session.write_pos + written;
        session.queued_bytes <- session.queued_bytes - written;
        if session.write_pos = String.length bytes
        then (
          ignore (Queue.dequeue_exn session.writes : string);
          session.write_pos <- 0);
        if written > 0 then loop (remaining - written))
  in
  loop 65536
;;

let begin_stop (session : session) : unit =
  if Option.is_none session.stopping_at
  then (
    session.stopping_at <- Some (Time_ns.now ());
    Queue.clear session.writes;
    session.queued_bytes <- 0;
    session.write_pos <- 0;
    Pty.signal session.pty ~force:false)
;;

let finish (t : t) (session : session) (status : string) : unit =
  publish t session ~exited:(Some status);
  Pty.close session.pty;
  Emulator.close session.emulator;
  t.session <- None
;;

let pump (t : t) (session : session) : unit =
  (try
     read_output session;
     if Option.is_none session.stopping_at then write_input session
   with
   | exn ->
     failed t (Exn.to_string exn);
     begin_stop session);
  (match session.stopping_at with
   | Some since when Time_ns.Span.( >= ) (Time_ns.diff (Time_ns.now ()) since) (Time_ns.Span.of_ms 250.) ->
     Pty.signal session.pty ~force:true
   | _ -> ());
  match Pty.poll_exit session.pty with
  | Some status ->
    (* Drain a final bounded chunk before retaining the exit screen. *)
    (try read_output session with | _ -> ());
    finish t session status
  | None ->
    if session.eof then begin_stop session;
    if session.dirty then publish t session ~exited:None
;;

let rec run (t : t) : unit Deferred.t =
  match t.session with
  | None ->
    t.loop_running <- false;
    Ivar.fill_if_empty t.done_ ();
    return ()
  | Some session ->
    pump t session;
    let%bind () = Clock_ns.after tick in
    run t
;;

let ensure_running (t : t) : unit =
  if not t.loop_running
  then (
    t.loop_running <- true;
    t.done_ <- Ivar.create ();
    don't_wait_for (run t))
;;

let create () : t =
  { session = None
  ; generation = 0
  ; announce_generation = false
  ; snapshot = None
  ; failure = None
  ; waiter = Ivar.create ()
  ; closed = false
  ; loop_running = false
  ; done_ = Ivar.create ()
  }
;;

let stop (t : t) : unit = Option.iter t.session ~f:begin_stop

let handle (t : t) ~(input : session -> string -> unit) (request : Model.request) : unit =
  match request, t.session with
  | Start { cwd; rows; cols }, None ->
    t.generation <- t.generation + 1;
    t.announce_generation <- true;
    t.snapshot <- None;
    t.failure <- None;
    let emulator : Emulator.t = Emulator.create ~rows ~cols in
    let pty : Pty.t =
      try Pty.spawn ~cwd ~rows ~cols with
      | exn -> Emulator.close emulator; raise exn
    in
    let session : session =
      { pty; emulator; writes = Queue.create (); write_pos = 0
      ; queued_bytes = 0; eof = false; stopping_at = None; dirty = true }
    in
    t.snapshot <- None;
    t.failure <- None;
    t.session <- Some session;
    publish t session ~exited:None;
    ensure_running t
  | Start _, Some _ -> ()
  | Stop, _ -> stop t
  | Key key, Some session when Option.is_none session.stopping_at ->
    input session (Emulator.key session.emulator key)
  | Paste bytes, Some session when Option.is_none session.stopping_at ->
    if String.length bytes > max_input then failwith "terminal paste exceeds 1 MiB";
    input session (Emulator.paste session.emulator bytes)
  | Resize { rows; cols }, Some session when Option.is_none session.stopping_at ->
    Emulator.resize session.emulator ~rows ~cols;
    Pty.resize session.pty ~rows ~cols;
    session.dirty <- true;
    publish t session ~exited:None
  | (Key _ | Paste _ | Resize _), _ -> ()
;;

let submit (t : t) (requests : Model.request list) : unit =
  if not t.closed
  then (
    (* A rejected paste must not leave an accepted prefix or a trailing Enter
       from the same frontend batch in the PTY queue. Stage input atomically;
       previously accepted input remains intact. No Async yield occurs here. *)
    let staged : (session * string) list ref = ref [] in
    let staged_bytes : int ref = ref 0 in
    let input_failed : bool ref = ref false in
    let input (session : session) (bytes : string) : unit =
      let length : int = String.length bytes in
      if length > max_input - session.queued_bytes - !staged_bytes
      then failwith "terminal input queue exceeds 1 MiB";
      if length > 0 then (
        staged := (session, bytes) :: !staged;
        staged_bytes := !staged_bytes + length)
    in
    List.iter requests ~f:(fun request ->
      let is_input : bool = match request with Key _ | Paste _ -> true | _ -> false in
      if not (is_input && !input_failed) then
        try handle t ~input request with
        | exn ->
          if is_input then (input_failed := true; staged := []);
          failed t (Exn.to_string exn));
    List.iter (List.rev !staged) ~f:(fun (session, bytes) ->
      if Option.is_none session.stopping_at
         && Option.exists t.session ~f:(phys_equal session)
      then enqueue session bytes))
;;

let rec next_event_with_generation (t : t) : (int * Model.event) Deferred.t =
  match t.failure, t.snapshot with
  | _, Some (generation, snapshot) when t.announce_generation ->
    (* Establish whether the new shell is live before reporting a nonfatal input
       rejection. Otherwise a UI with no snapshot yet mistakes it for a failed
       Start and can attempt a restart while the original shell is still live. *)
    t.announce_generation <- false;
    t.snapshot <- None;
    return (generation, Model.Snapshot snapshot)
  | Some (generation, message), _ ->
    t.announce_generation <- false;
    t.failure <- None;
    return (generation, Model.Failed message)
  | None, Some (generation, snapshot) ->
    t.snapshot <- None;
    return (generation, Model.Snapshot snapshot)
  | None, None ->
    if Ivar.is_full t.waiter then t.waiter <- Ivar.create ();
    let%bind () = Ivar.read t.waiter in
    next_event_with_generation t
;;

let next_event (t : t) : Model.event Deferred.t =
  let%map _, event = next_event_with_generation t in
  event
;;

let shutdown (t : t) : unit Deferred.t =
  t.closed <- true;
  stop t;
  if t.loop_running then Ivar.read t.done_ else return ()
;;
