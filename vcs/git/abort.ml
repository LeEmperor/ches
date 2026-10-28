open! Core
open Ches_vcs

module Operation = struct
  type t =
    | Rebase
    | Merge
  [@@deriving sexp, equal]
end

let popup (operation : Operation.t) : Operation.t Popup.t =
  let title =
    match operation with
    | Rebase -> "Rebasing"
    | Merge -> "Merging"
  in
  let abort =
    { Popup.Action.key = 'a'; description = "Abort"; run = (fun ~enabled:_ -> operation) }
  in
  Popup.create ~title ~switches:[] ~actions:[ abort ] |> Or_error.ok_exn
;;

let in_progress (operations : In_progress.t list) (operation : Operation.t) =
  List.exists operations ~f:(fun (op : In_progress.t) ->
    match operation, op with
    | Rebase, Rebase _ | Merge, Merge _ -> true
    | Rebase, (Apply_mailbox | Merge _ | Cherry_pick _ | Revert _ | Bisect)
    | Merge, (Rebase _ | Apply_mailbox | Cherry_pick _ | Revert _ | Bisect) -> false)
;;
