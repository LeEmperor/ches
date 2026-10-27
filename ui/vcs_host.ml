(* A thin owner of one runner: the contract is vcs_host.mli. Everything here is the
   runner's behavior, adapted to [Ui_state] inputs and given a bounded shutdown. *)

open! Core
open! Async
module Runner = Ches_vcs_host.Runner

type t = Runner.t

let create ?config ?inherited () = Runner.create ?config ?inherited ()
let submit t jobs = List.iter jobs ~f:(Runner.submit t)

let next_inputs t =
  let%map events = Runner.next_batch t in
  List.map events ~f:(fun event -> Ches_screen.Ui_state.Input.Vcs event)
;;

let busy = Runner.busy
let stop = Runner.stop

let shutdown ?(cap = Time_ns.Span.of_int_sec 3) t =
  stop t;
  match%map Clock_ns.with_timeout cap (Runner.finished t) with
  | `Result () -> `Finished
  | `Timeout -> `Timed_out
;;
