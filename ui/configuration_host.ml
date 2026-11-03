open! Core
open! Async

type configuration = (Ches_config_runtime.Settings.t, string) Result.t

type t =
  { load : unit -> configuration Deferred.t
  ; mutable latest : int
  ; mutable pending : int option
  ; mutable active : bool
  ; mutable finished : unit Ivar.t option
  ; mutable stopped : bool
  ; mutable reply : (int * configuration) option
  ; mutable changed : unit Ivar.t
  }

let notify t =
  let changed = t.changed in
  t.changed <- Ivar.create ();
  Ivar.fill_if_empty changed ()
;;

let load t =
  match%map Monitor.try_with t.load with
  | Ok result -> result
  | Error exn -> Error (Exn.to_string exn)
;;

let rec launch t =
  match t.pending with
  | Some generation when not t.active && not t.stopped ->
    t.pending <- None;
    t.active <- true;
    let finished = Ivar.create () in
    t.finished <- Some finished;
    don't_wait_for (
      let%bind result = load t in
      t.active <- false;
      t.finished <- None;
      Ivar.fill_if_empty finished ();
      if not t.stopped && generation = t.latest then (
        t.reply <- Some (generation, result);
        notify t);
      launch t;
      return ())
  | _ -> ()
;;

let create ?(load = fun () -> Ches_config_runtime.Loader.load ()) () =
  { load; latest = 0; pending = None; active = false; finished = None; stopped = false
  ; reply = None; changed = Ivar.create () }
;;

let startup t =
  if t.active || t.stopped then return (Error "Configuration host is busy or stopped") else (
    t.active <- true;
    let finished = Ivar.create () in
    t.finished <- Some finished;
    let%map result = load t in
    t.active <- false;
    t.finished <- None;
    Ivar.fill_if_empty finished ();
    launch t;
    result)
;;

let submit t generations =
  if not t.stopped then (
    List.iter generations ~f:(fun generation ->
      if generation > t.latest then (
        t.latest <- generation;
        t.pending <- Some generation;
        t.reply <- None));
    launch t)
;;

let rec next t =
  if t.stopped then return None else
  match t.reply with
  | Some reply -> t.reply <- None; return (Some reply)
  | None -> let%bind () = Ivar.read t.changed in next t
;;

let stop t =
  t.stopped <- true;
  t.pending <- None;
  t.reply <- None;
  notify t
;;

let shutdown t =
  stop t;
  Option.value_map t.finished ~default:(return ()) ~f:Ivar.read
;;
