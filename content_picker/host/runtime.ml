open! Core
open! Async
module Provider = Ches_content_search.Provider
module Model = Ches_content_picker.Model
module Ui_state = Ches_screen.Ui_state
module Tile = Ches_screen.Content_picker_tile

type t =
  { provider : Provider.t
  ; mutable run : Provider.run option
  ; mutable generation : int
  ; mutable active : bool
  }
let create ?prog ?limits () =
  { provider = Provider.create ?prog ?limits (); run = None; generation = 0; active = false }
;;
let cancel t = t.active <- false; t.generation <- t.generation + 1; Provider.cancel t.provider
let finished t = Option.value_map t.run ~default:(return ()) ~f:Provider.finished
let needs_turn t ui =
  t.active && not (Ui_state.exited ui)
  && Option.exists (Ui_state.content_picker ui) ~f:(fun picker ->
    let session = Tile.session picker in
    not (Model.closed session)
    && Option.exists t.run ~f:(fun run ->
      Model.same_request (Provider.request run) (Model.snapshot session).request)
    && (Model.pending session || match (Model.snapshot session).status with
      | Loading | Partial -> true | Complete _ | Failed _ | Cancelled -> false))
;;
let open_picker t ui ~root ~width ~height =
  if not (Ui_state.can_open_file_picker ui ~width ~height)
  then Or_error.error_string "Content search unavailable: finish paste, leave Insert/Visual, and allow at least 14 columns and 5 rows"
  else Or_error.map (Provider.start t.provider ~root ~query:"") ~f:(fun run ->
    t.generation <- t.generation + 1;
    let generation = t.generation in
    t.run <- Some run;
    t.active <- true;
    Ui_state.open_content_picker ui ~width ~height
      ~snapshot:(Option.value_exn (Provider.snapshot t.provider))
      ~release:(fun () -> if t.generation = generation then cancel t))
;;
let next t ui =
  match Ui_state.content_picker ui with
  | None -> return []
  | Some _ when Ui_state.exited ui -> cancel t; return []
  | Some picker ->
    let session = Tile.session picker in
    let generation = t.generation in
    let current = (Model.snapshot session).request in
    let owns_run = Option.exists t.run ~f:(fun run ->
      Model.same_request (Provider.request run) current) in
    if not t.active || not owns_run || Model.closed session then return []
    else (
      (* Starting replaces/cancels immediately; provider itself debounces spawning.
         Thus stale results are disabled on edit, not only after the timer. *)
      if Model.pending session then (
        let run = Provider.start t.provider ~root:current.root ~query:(Model.query session)
          |> Or_error.ok_exn in
        t.run <- Some run;
        Tile.expect picker (Provider.request run));
      let request = (Model.snapshot session).request in
      let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in
      if generation <> t.generation || Model.closed session
         || not (String.equal request.query (Model.query session))
         || not (Option.exists t.run ~f:(fun run -> Model.same_request request (Provider.request run)))
      then []
      else Provider.poll t.provider ~max_batches:1
        |> Option.to_list |> List.map ~f:(fun snapshot -> Ui_state.Input.Content_picker_snapshot snapshot))
;;
let rec pump t ~current ~inject =
  if not (needs_turn t (current ())) then return ()
  else (
    let%bind events = next t (current ()) in
    let%bind () = inject events in
    pump t ~current ~inject)
;;
