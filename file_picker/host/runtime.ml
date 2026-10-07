open! Core
open! Async
module Provider = Ches_file_discovery.Provider
module Model = Ches_file_picker.Model
module Ui_state = Ches_screen.Ui_state
module Tile = Ches_screen.File_picker_tile

type t = { provider : Provider.t; mutable run : Provider.run option }
let create ?prog ?limits () = { provider = Provider.create ?prog ?limits (); run = None }

let same_run t request =
  Option.exists (Provider.snapshot t.provider) ~f:(fun snapshot ->
    Model.Discovery.equal_request snapshot.request request)
;;

let open_picker t ui ~root ~width ~height =
  if not (Ui_state.can_open_file_picker ui ~width ~height)
  then Or_error.error_string
    "Files unavailable: finish paste, leave Insert/Visual, and allow at least 14 columns and 5 rows"
  else Or_error.map (Provider.start t.provider ~root) ~f:(fun run ->
    t.run <- Some run;
    let request = Provider.request run in
    let release () = if same_run t request then Provider.cancel t.provider in
    Ui_state.open_file_picker ui ~width ~height
      ~discovery:(Option.value_exn (Provider.snapshot t.provider)) ~release)
;;

(* The frontend chains these deferred turns, not one turn per rendered frame.
   Waiting while discovery is idle avoids spinning; busy ranking yields to Async
   between every bounded work action. Neither callback runs traversal/ranking. *)
let next t ui =
  match Ui_state.file_picker ui with
  | None -> return []
  | Some _ when Ui_state.exited ui -> Provider.cancel t.provider; return []
  | Some picker ->
    let session = Tile.session picker in
    let request = (Model.discovery (Ches_file_picker.Interaction.model session)).request in
    if not (same_run t request) then return []
    else (
      let%map () =
        if Ches_file_picker.Interaction.busy session
        then Scheduler.yield ()
        else Clock_ns.after (Time_ns.Span.of_int_ms 2)
      in
      if not (same_run t request) || Ches_file_picker.Interaction.closed session
      then []
      else
      let snapshot = Provider.poll t.provider ~max_batches:1 in
      let events = Option.to_list (Option.map snapshot ~f:(fun s -> Ui_state.Input.File_picker_snapshot s)) in
      let status = (Option.value_exn (Provider.snapshot t.provider)).status in
      let working = Ches_file_picker.Interaction.busy session || Option.is_some snapshot in
      match status, working with
      | (Loading | Partial), _ | _, true -> events @ [ Ui_state.Input.File_picker_work request ]
      | (Complete _ | Failed _ | Cancelled), false -> [])
;;

let cancel t = Provider.cancel t.provider
let finished t = Option.value_map t.run ~default:(return ()) ~f:Provider.finished

let rec pump t ~current ~inject =
  let%bind events = next t (current ()) in
  match events with
  | [] ->
    (* Reopening can invalidate a deferred turn while it is yielding. Continue
       with the new run rather than leaving its discovery without a poller. *)
    let ui = current () in
    let continue = Option.exists (Ui_state.file_picker ui) ~f:(fun picker ->
      let session = Tile.session picker in
      let discovery = Model.discovery (Ches_file_picker.Interaction.model session) in
      same_run t discovery.request && not (Ui_state.exited ui)
      && (Ches_file_picker.Interaction.busy session
          || match discovery.status with Loading | Partial -> true | _ -> false)) in
    if continue then pump t ~current ~inject else return ()
  | _ ->
    let%bind () = inject events in
    pump t ~current ~inject
;;
