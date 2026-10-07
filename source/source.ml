open! Core
open! Async

module Driver = struct
  type t =
    { handle : Ches_error.Source_request.t -> unit
    ; stop : unit -> unit
    }
end

type t =
  { mutable queue : Event_queue.t
  ; mutable waiter : unit Ivar.t option
  ; mutable stopped : bool
  ; mutable driver : Driver.t
  }

let max_batch = 64

let emit t event =
  if not t.stopped
  then (
    t.queue <- Event_queue.push t.queue event;
    Option.iter t.waiter ~f:(fun waiter -> Ivar.fill_if_empty waiter ());
    t.waiter <- None)
;;

let create f =
  let t =
    { queue = Event_queue.empty
    ; waiter = None
    ; stopped = false
    ; driver = { handle = ignore; stop = ignore }
    }
  in
  t.driver <- f ~emit:(emit t);
  t
;;

let send t request = if not t.stopped then t.driver.handle request

let stop t =
  if not t.stopped
  then (
    t.stopped <- true;
    t.queue <- Event_queue.empty;
    t.waiter <- None;
    t.driver.stop ())
;;

let rec next_batch t =
  if t.stopped
  then Deferred.never ()
  else (
    match Event_queue.take t.queue ~max:max_batch with
    | _, [] ->
      let waiter = Ivar.create () in
      t.waiter <- Some waiter;
      let%bind () = Ivar.read waiter in
      next_batch t
    | queue, events ->
      t.queue <- queue;
      return events)
;;

let poll t =
  let queue, events = Event_queue.take t.queue ~max:max_batch in
  t.queue <- queue;
  events
;;

let dropped t = Event_queue.dropped t.queue
