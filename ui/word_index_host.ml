open! Core
open! Async
module State = Ches_screen.Ui_state
module Words = Ches_completion.Model.Buffer_words
type request = State.word_index_request
type t =
  { mutable desired : request option
  ; mutable active : bool
  ; mutable stopped : bool
  ; mutable reply : (request * Words.t) option
  ; mutable changed : unit Ivar.t
  }
let create () =
  { desired = None; active = false; stopped = false; reply = None; changed = Ivar.create () }
let notify t =
  let changed = t.changed in t.changed <- Ivar.create (); Ivar.fill_if_empty changed ()
let same_document (a : request) (b : request) =
  Option.equal Ches_app.Buffer_id.equal a.owner b.owner
  && Ches_app.Controller.Document_id.equal a.document b.document
let same_request (a : request) (b : request) =
  same_document a b && Ches_completion.Model.Token.equal a.request.token b.request.token
let rec launch t =
  match t.desired with
  | Some request when not t.active && not t.stopped ->
    t.active <- true;
    let builder = Words.Builder.create ?before:request.before request.text in
    let rec run () =
      let%bind () = Scheduler.yield () in
      if t.stopped || not (Option.exists t.desired ~f:(same_document request)) then return None
      else match Words.Builder.step builder ~budget:16384 with
        | Some words -> return (Some words)
        | None -> run () in
    don't_wait_for (
      let%bind result = run () in
      t.active <- false;
      Option.iter result ~f:(fun words ->
        if not t.stopped then (
          t.reply <- Some (request, words); notify t;
          t.desired <- Option.map t.desired ~f:(fun latest ->
            if same_document request latest then { latest with before = Some words } else latest)));
      (match t.desired with
       | Some latest when same_request request latest && Option.is_some result -> ()
       | _ -> launch t);
      return ())
  | _ -> ()
let follow t request =
  if not t.stopped then (
    let unchanged = Option.equal same_request t.desired request in
    t.desired <- request;
    if not unchanged then (t.reply <- None; launch t))
let rec next t =
  if t.stopped then return None else
  match t.reply with
  | Some reply -> t.reply <- None; return (Some reply)
  | None -> let%bind () = Ivar.read t.changed in next t
let stop t =
  t.stopped <- true; t.desired <- None; t.reply <- None; notify t
