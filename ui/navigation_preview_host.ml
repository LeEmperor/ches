open! Core
open! Async
module Model = Ches_navigation_preview_model.Model
type pending = { request : Model.request; mutable ready : bool }
type active =
  { cancelled : bool Atomic.t; finished : unit Ivar.t
  ; mutable abort_timeout : (unit -> unit) option }
type t =
  { debounce : Time_ns.Span.t; timeout : Time_ns.Span.t
  ; buffer : Model.request -> Model.state option
  ; read : cancelled:bool Atomic.t -> Model.request -> Model.state Deferred.t
  ; mutable pending : pending option; mutable active : active option
  ; mutable snapshot : Model.snapshot option; mutable timer : (unit -> unit) option
  ; mutable wait_timer : (unit -> unit) option
  ; mutable change : unit Ivar.t; mutable stopped : bool }
let equal_request (a : Model.request) (b : Model.request) =
  a.generation = b.generation && Ches_error.Language_query.equal_target a.target b.target
let notify t = let old = t.change in t.change <- Ivar.create (); Ivar.fill_if_empty old ()
let snapshot t = t.snapshot
let changed t = Ivar.read t.change
let finished t = Option.value_map t.active ~default:(return ()) ~f:(fun a -> Ivar.read a.finished)
let clear t =
  Option.iter t.timer ~f:(fun abort -> abort ()); t.timer <- None;
  Option.iter t.wait_timer ~f:(fun abort -> abort ()); t.wait_timer <- None;
  Option.iter t.active ~f:(fun a ->
    Atomic.set a.cancelled true;
    Option.iter a.abort_timeout ~f:(fun abort -> abort ()); a.abort_timeout <- None);
  t.pending <- None; t.snapshot <- None; notify t
let stop t = t.stopped <- true; clear t
let current t request = not t.stopped && Option.exists t.snapshot ~f:(fun s -> equal_request s.request request)
let install t request state = if current t request then (t.snapshot <- Some { request; state }; notify t)
let release_pending t =
  t.pending <- None;
  Option.iter t.wait_timer ~f:(fun abort -> abort ()); t.wait_timer <- None
let rec launch t =
  match t.pending with
  | Some pending when pending.ready && not t.stopped ->
    (* Retained text can bypass an obsolete occupied disk slot. No full text is
       captured in pending work or worker closures. *)
    (match Or_error.try_with (fun () -> t.buffer pending.request) with
     | Error _ -> release_pending t; install t pending.request (Unreadable "Could not snapshot retained buffer")
     | Ok (Some state) -> release_pending t; install t pending.request state
     | Ok None when Option.is_none t.active ->
       release_pending t;
       let active = { cancelled = Atomic.make false; finished = Ivar.create (); abort_timeout = None } in
       t.active <- Some active;
       let timer = Clock_ns.Event.run_after t.timeout (fun () ->
         active.abort_timeout <- None; Atomic.set active.cancelled true;
         install t pending.request (Unreadable "Source preview timed out")) () in
       active.abort_timeout <- Some (fun () -> Clock_ns.Event.abort_if_possible timer ());
       don't_wait_for (
         let%bind result = Monitor.try_with (fun () -> t.read ~cancelled:active.cancelled pending.request) in
         Clock_ns.Event.abort_if_possible timer (); active.abort_timeout <- None;
         if not (Atomic.get active.cancelled) then
           install t pending.request (match result with Ok state -> state | Error _ -> Unreadable "Could not read source preview");
         t.active <- None; Ivar.fill_if_empty active.finished (); launch t; return ())
     | Ok None ->
       (* A timed-out physical read can outlive cancellation. Bound delivery for
          the newest selection even while that obsolete worker holds the slot. *)
       if Option.is_none t.wait_timer then (
         let timer = Clock_ns.Event.run_after t.timeout (fun () ->
           t.wait_timer <- None; t.pending <- None;
           install t pending.request (Unreadable "Source preview timed out waiting for reader")) () in
         t.wait_timer <- Some (fun () -> Clock_ns.Event.abort_if_possible timer ())))
  | _ -> ()
let follow t request =
  match request with
  | None -> if Option.is_some t.snapshot then clear t
  | Some request when not t.stopped && not (current t request) ->
    clear t;
    let pending = { request; ready = false } in
    t.pending <- Some pending; t.snapshot <- Some { request; state = Loading };
    let timer = Clock_ns.Event.run_after t.debounce (fun () ->
      t.timer <- None;
      if current t request then (pending.ready <- true; launch t)) () in
    t.timer <- Some (fun () -> Clock_ns.Event.abort_if_possible timer ()); notify t
  | Some _ -> ()
let stamp (s : Core_unix.stats) = s.st_dev, s.st_ino, s.st_size, s.st_mtime, s.st_ctime
let stamp_string s = Sexp.to_string ([%sexp_of: int * int * int64 * float * float] (stamp s))
let disk_read ~cancelled (request : Model.request) =
  In_thread.run (fun () ->
    let regular (s : Core_unix.stats) = match s.st_kind with S_REG -> true | _ -> false in
    let path = request.target.path in
    if Atomic.get cancelled then Model.Cancelled else
    try
      let before = Core_unix.stat path in
      if not (regular before) then Model.Unsupported "Special file" else
      let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
      Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
        let opened = Core_unix.fstat fd in
        if not (regular opened) then Model.Unsupported "Special file"
        else if not (Poly.equal (stamp before) (stamp opened)) then Model.Unreadable "Source changed before preview"
        else (
          let result = Model.collect ~source:(Disk { stamp = Some (stamp_string opened) })
            ~target:request.target ~cancelled:(fun () -> Atomic.get cancelled)
            ~read:(fun buf ~pos ~len -> Core_unix.read ~restart:true fd ~buf ~pos ~len) in
          if Atomic.get cancelled then Model.Cancelled
          else if not (Poly.equal (stamp opened) (stamp (Core_unix.fstat fd)))
               || not (Poly.equal (stamp opened) (stamp (Core_unix.stat path)))
          then Model.Unreadable "Source changed during preview"
          else result))
    with
    | Core_unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Model.Missing
    | _ -> Model.Unreadable "Source preview unavailable; check access")
let make ?(debounce = Time_ns.Span.of_int_ms 40) ?(timeout = Time_ns.Span.of_sec 2.) ~buffer ~read () =
  if Time_ns.Span.(debounce < zero || timeout <= zero) then invalid_arg "Invalid preview timing";
  { debounce; timeout; buffer; read; pending = None; active = None; snapshot = None
  ; timer = None; wait_timer = None; change = Ivar.create (); stopped = false }
let create ?debounce ?timeout ~buffer () = make ?debounce ?timeout ~buffer ~read:disk_read ()
module For_testing = struct let create = make let disk_read = disk_read end
