open! Core
open Ches_vcs

module Kind = struct
  type t =
    | Rebase
    | Merge
  [@@deriving sexp, equal]
end

module Choice = struct
  type t =
    | Continue of Kind.t
    | Skip
    | Abort of Kind.t
  [@@deriving sexp, equal]
end

let action key description run = { Popup.Action.key; description; run }

let popup (kind : Kind.t) : Choice.t Popup.t =
  let title, actions =
    match kind with
    | Rebase ->
      ( "Rebasing"
      , [ action 'r' "Continue" (fun ~enabled:_ -> Choice.Continue Rebase)
        ; action 's' "Skip this commit" (fun ~enabled:_ -> Choice.Skip)
        ; action 'a' "Abort" (fun ~enabled:_ -> Choice.Abort Rebase)
        ] )
    | Merge ->
      ( "Merging"
      , [ action 'm' "Commit the merge" (fun ~enabled:_ -> Choice.Continue Merge)
        ; action 'a' "Abort" (fun ~enabled:_ -> Choice.Abort Merge)
        ] )
  in
  Popup.create ~title ~switches:[] ~actions |> Or_error.ok_exn
;;

let in_progress (operations : In_progress.t list) (kind : Kind.t) =
  List.exists operations ~f:(fun (op : In_progress.t) ->
    match kind, op with
    | Rebase, Rebase _ | Merge, Merge _ -> true
    | Rebase, (Apply_mailbox | Merge _ | Cherry_pick _ | Revert _ | Bisect)
    | Merge, (Rebase _ | Apply_mailbox | Cherry_pick _ | Revert _ | Bisect) -> false)
;;

module Merge_choice = struct
  type t =
    { branch : string option
    ; flags : string list
    }
  [@@deriving sexp, equal]
end

let no_ff = "--no-ff"
let ff_only = "--ff-only"

let merge_popup ~branch : Merge_choice.t Popup.t =
  let switch key flag description =
    { Popup.Switch.key; flag; description; group = Some "fast-forward" }
  in
  let description =
    match branch with
    | Some branch -> "Merge " ^ branch
    | None -> "Merge (select a branch in Branches first)"
  in
  Popup.create
    ~title:"Merge"
    ~switches:
      [ switch 'n' no_ff "Always create a merge commit"
      ; switch 'f' ff_only "Fast-forward only"
      ]
    ~actions:
      [ action 'm' description (fun ~enabled -> { Merge_choice.branch; flags = enabled })
      ]
  |> Or_error.ok_exn
;;

let merge_flags = [ no_ff; ff_only ]

(* git prints the CONFLICT lines on stdout (merge, rebase --continue, pull --rebase:
   verified with 2.43); stderr is searched as well. *)
let stopped_hint (report : Job.Step_report.t) =
  match report.outcome with
  | Ran result when not (Job.Step_report.succeeded report) ->
    Option.some_if
      (List.exists [ result.stdout; result.stderr ] ~f:(fun text ->
         String.is_substring text ~substring:"CONFLICT ("))
      "Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it \
       resolved with s, then continue"
  | Ran _ | Read _ | Skipped -> None
;;
