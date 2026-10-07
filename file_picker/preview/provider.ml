open! Core
open! Async
module Candidate = Ches_file_picker.Model.Candidate
type pending = { request : Model.request; path : string; mutable ready : bool }
type active =
  { cancelled : bool Atomic.t; finished : unit Ivar.t
  ; mutable abort_timeout : (unit -> unit) option }
type t =
  { debounce : Time_ns.Span.t; timeout : Time_ns.Span.t
  ; buffer : path:string -> Model.state option
  ; read : cancelled:bool Atomic.t -> path:string -> Model.state option Deferred.t
  ; mutable generation : int; mutable pending : pending option
  ; mutable active : active option; mutable snapshot : Model.snapshot option
  ; mutable timer : (unit -> unit) option; mutable change : unit Ivar.t }
let notify t = let old = t.change in t.change <- Ivar.create (); Ivar.fill_if_empty old ()
let snapshot t = t.snapshot
let changed t = Ivar.read t.change
let finished t = Option.value_map t.active ~default:(return ()) ~f:(fun a -> Ivar.read a.finished)
let abort_timer t = Option.iter t.timer ~f:(fun abort -> abort ()); t.timer <- None
let clear t =
  abort_timer t;
  Option.iter t.active ~f:(fun a ->
    Atomic.set a.cancelled true;
    Option.iter a.abort_timeout ~f:(fun abort -> abort ());
    a.abort_timeout <- None);
  t.pending <- None; t.snapshot <- None;
  notify t
;;
let current t request = Option.exists t.snapshot ~f:(fun s -> Model.equal_request s.request request)
let install t request state = if current t request then (t.snapshot <- Some { request; state }; notify t)
let rec launch t =
  match t.active, t.pending with
  | None, Some pending when pending.ready ->
    t.pending <- None;
    (* Lookup is late and synchronous but bounded; no immutable full buffer is
       captured by disk workers or pending/debounce closures. *)
    (match Or_error.try_with (fun () -> t.buffer ~path:pending.path) with
     | Error _ -> install t pending.request (Unreadable "Could not snapshot open buffer")
     | Ok (Some state) -> install t pending.request state
     | Ok None ->
       let active = { cancelled = Atomic.make false; finished = Ivar.create (); abort_timeout = None } in
       t.active <- Some active;
       let timer = Clock_ns.Event.run_after t.timeout (fun () ->
         active.abort_timeout <- None;
         Atomic.set active.cancelled true;
         install t pending.request (Unreadable "File preview timed out")) () in
       active.abort_timeout <- Some (fun () -> Clock_ns.Event.abort_if_possible timer ());
       don't_wait_for (
         let%bind result = Monitor.try_with (fun () -> t.read ~cancelled:active.cancelled ~path:pending.path) in
         Clock_ns.Event.abort_if_possible timer ();
         active.abort_timeout <- None;
         if not (Atomic.get active.cancelled) then (
           let state = match result with Ok (Some state) -> state
             | Ok None | Error _ -> Model.Unreadable "Could not read file preview" in
           install t pending.request state);
         t.active <- None;
         Ivar.fill_if_empty active.finished ();
         launch t;
         return ()))
  | _ -> ()
;;
let select ?(refresh = false) t ~session candidate =
  let selected = Candidate.id candidate in
  match t.snapshot with
  | Some s when not refresh && Ches_file_picker.Model.Discovery.equal_request s.request.session session
                && Candidate.Id.equal s.request.selected selected -> s.request
  | _ ->
    clear t;
    t.generation <- t.generation + 1;
    let request : Model.request = { session; selected; generation = t.generation } in
    let pending = { request; path = Candidate.path candidate; ready = false } in
    t.pending <- Some pending; t.snapshot <- Some { request; state = Loading };
    let timer = Clock_ns.Event.run_after t.debounce (fun () ->
      t.timer <- None;
      if current t request then (pending.ready <- true; launch t)) () in
    t.timer <- Some (fun () -> Clock_ns.Event.abort_if_possible timer ());
    notify t; request
;;
let follow ?refresh t model =
  match Option.bind model ~f:(fun model ->
    Option.bind (Ches_file_picker.Model.selected model) ~f:(fun selected ->
      Option.map (List.find (Ches_file_picker.Model.results model) ~f:(fun result ->
        Candidate.Id.equal (Candidate.id result.candidate) selected)) ~f:(fun result ->
        (Ches_file_picker.Model.discovery model).request, result.candidate))) with
  | None -> if Option.is_some t.snapshot then clear t; None
  | Some (session, candidate) -> Some (select ?refresh t ~session candidate)
;;
let disk_read ~cancelled ~path =
  In_thread.run (fun () ->
    let regular (stats : Core_unix.stats) = match stats.st_kind with S_REG -> true | _ -> false in
    if Atomic.get cancelled then None else
    try
      (* Precheck avoids opening known devices/FIFOs. O_NONBLOCK + descriptor
         fstat also defend replacement with a FIFO between stat and open. Symlinks
         are followed only to regular files; descriptor owns the checked identity. *)
      if not (regular (Core_unix.stat path))
      then Some (Model.Unsupported Special_file)
      else
        let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
        Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
          if not (regular (Core_unix.fstat fd))
          then Some (Model.Unsupported Special_file)
          else Model.collect ~source:Disk ~cancelled:(fun () -> Atomic.get cancelled)
            ~read:(fun buf ~len -> Core_unix.read ~restart:true fd ~buf ~len))
    with
    | Core_unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Some Model.Missing
    | _ -> Some (Model.Unreadable "File preview unavailable; check access"))
;;
let make ?(debounce = Time_ns.Span.of_int_ms 60) ?(timeout = Time_ns.Span.of_sec 2.) ~buffer ~read () =
  if Time_ns.Span.(debounce < zero || timeout <= zero) then invalid_arg "Invalid preview timing";
  { debounce; timeout; buffer; read; generation = 0; pending = None; active = None
  ; snapshot = None; timer = None; change = Ivar.create () }
;;
let create ?debounce ?timeout ~buffer () = make ?debounce ?timeout ~buffer ~read:disk_read ()
module For_testing = struct let create = make end
