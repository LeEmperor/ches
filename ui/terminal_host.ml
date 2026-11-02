open! Core
open! Async

type t =
  { runtime : Ches_terminal_host.Runtime.t
  ; closed : unit Ivar.t
  ; mutable finished : unit Deferred.t option
  }

let create () =
  { runtime = Ches_terminal_host.Runtime.create ()
  ; closed = Ivar.create ()
  ; finished = None
  }
;;

let submit t requests =
  if not (Ivar.is_full t.closed) then Ches_terminal_host.Runtime.submit t.runtime requests
;;

let stop t = Ches_terminal_host.Runtime.stop t.runtime

let shutdown t =
  match t.finished with
  | Some finished -> finished
  | None ->
    Ivar.fill_if_empty t.closed ();
    let finished = Ches_terminal_host.Runtime.shutdown t.runtime in
    t.finished <- Some finished;
    finished
;;

let next_update t =
  if Ivar.is_full t.closed then return None
  else Deferred.choose
    [ Deferred.choice (Ivar.read t.closed) (fun () -> None)
    ; Deferred.choice (Ches_terminal_host.Runtime.next_event_with_generation t.runtime)
        (fun event -> if Ivar.is_full t.closed then None else Some event)
    ]
;;

let next_event t =
  let%map update = next_update t in
  Option.map update ~f:snd
;;
