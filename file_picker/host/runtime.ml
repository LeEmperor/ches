open! Core
open! Async
module Provider = Ches_file_discovery.Provider
module Model = Ches_file_picker.Model
module Ui_state = Ches_screen.Ui_state
module Tile = Ches_screen.File_picker_tile
module Interaction = Ches_file_picker.Interaction

module Cache_limits = struct
  type t = { max_roots : int; max_bytes : int; ttl : Time_ns.Span.t }
  let default = { max_roots = 2; max_bytes = 128 * 1024 * 1024; ttl = Time_ns.Span.of_int_sec 30 }
end
type entry = { root : string; policy : string; data : Interaction.Snapshot.t; validated : Time_ns.t }
type t =
  { provider : Provider.t; mutable run : Provider.run option; cache_limits : Cache_limits.t
  ; now : unit -> Time_ns.t; mutable entries : entry list; mutable hits : int; mutable evictions : int
  ; mutable validation : (Model.Discovery.request * Time_ns.t option ref) option }
let monotonic () = Time_ns.of_int63_ns_since_epoch (Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic)
let create ?prog ?limits ?(cache_limits = Cache_limits.default) ?(now = monotonic) () =
  if cache_limits.max_roots < 0 || cache_limits.max_roots > 4 || cache_limits.max_bytes < 0
     || Time_ns.Span.(cache_limits.ttl < zero) then invalid_arg "Reopen cache limits";
  { provider = Provider.create ?prog ?limits (); run = None; cache_limits; now
  ; entries = []; hits = 0; evictions = 0; validation = None }
let prune t =
  let now = t.now () in
  t.entries <- List.filter t.entries ~f:(fun entry ->
    let age = Time_ns.diff now entry.validated in
    Time_ns.Span.(age >= zero && age <= t.cache_limits.ttl))
let cache_bytes t = prune t; List.sum (module Int) t.entries ~f:(fun e -> Interaction.Snapshot.bytes e.data)
let cache_entries t = prune t; List.length t.entries
let cache_hits t = t.hits
let cache_evictions t = t.evictions
let invalidate_cache t = t.entries <- []
let remember t ~root ~policy ~validated data =
  prune t;
  t.entries <- List.filter t.entries ~f:(fun e -> not (String.equal e.root root));
  if t.cache_limits.max_roots > 0 && Interaction.Snapshot.bytes data <= t.cache_limits.max_bytes then (
    t.entries <- { root; policy; data; validated } :: t.entries;
    while List.length t.entries > t.cache_limits.max_roots || cache_bytes t > t.cache_limits.max_bytes do
      t.entries <- List.drop_last_exn t.entries; t.evictions <- t.evictions + 1
    done)
let find t root policy =
  prune t;
  t.entries <- List.filter t.entries ~f:(fun e -> not (String.equal e.root root) || String.equal e.policy policy);
  let found = List.find t.entries ~f:(fun e -> String.equal e.root root && String.equal e.policy policy) in
  Option.iter found ~f:(fun entry ->
    t.entries <- entry :: List.filter t.entries ~f:(fun other -> not (phys_equal entry other)));
  found

let same_run t request =
  Option.exists (Provider.current t.provider) ~f:(fun snapshot ->
    Model.Discovery.equal_request snapshot.request request)
;;

let open_picker_with_policy t ui ~root ~policy ~width ~height =
  if not (Ui_state.can_open_file_picker ui ~width ~height)
  then Or_error.error_string
    "Files unavailable: finish paste, leave Insert/Visual, and allow at least 14 columns and 5 rows"
  else (
    (* Replacement closes/captures the previous picker before the lookup. *)
    Option.iter (Ui_state.file_picker ui) ~f:(fun picker -> Interaction.cancel (Tile.session picker) ~release:(fun () -> ()));
    let root_key = Model.Candidate.create ~root ~relative_path:"cache-root" |> Or_error.map ~f:Model.Candidate.root in
    Or_error.bind root_key ~f:(fun root ->
    let cached = find t root policy in
    Or_error.map (Provider.start ?reuse:(Option.map cached ~f:(fun e -> Interaction.Snapshot.candidates e.data)) t.provider ~root) ~f:(fun run ->
    t.run <- Some run;
     let request = Provider.request run in
     let validated = ref None in
     t.validation <- Some (request, validated);
    let release () = if same_run t request then Provider.cancel t.provider in
    let ui = Ui_state.open_file_picker ui ~width ~height
      ~discovery:(Option.value_exn (Provider.snapshot t.provider)) ~release in
    Option.iter (Ui_state.file_picker ui) ~f:(fun picker ->
      let session = Tile.session picker in
      let initial = Option.value_exn (Provider.current t.provider) in
      ignore (Interaction.install_update session initial : bool);
      Option.iter cached ~f:(fun entry ->
        if Interaction.restore_snapshot session entry.data initial then t.hits <- t.hits + 1);
      Interaction.set_snapshot_sink session (fun data ->
        remember t ~root ~policy ~validated:(Option.value !validated ~default:(t.now ())) data));
    ui)))
let open_picker t ui ~root ~width ~height = open_picker_with_policy t ui ~root ~policy:"native-v1" ~width ~height
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
    let request = Model.discovery_request (Ches_file_picker.Interaction.model session) in
    if not (same_run t request) then return []
    else (
      if Interaction.acceptance_blocked session && not (Interaction.refreshing session) then (
        match Model.discovery_status (Interaction.model session) with
        | Failed _ | Cancelled | Complete { truncated = true } ->
          t.entries <- List.filter t.entries ~f:(fun e -> not (String.equal e.root request.root))
        | _ -> ());
      if Model.Discovery.equal_status (Model.discovery_status (Interaction.model session)) (Complete { truncated = false })
         && not (Interaction.busy session) && not (Interaction.acceptance_blocked session) then
        Option.iter t.validation ~f:(fun (owner, time) ->
          if Model.Discovery.equal_request owner request && Option.is_none !time then time := Some (t.now ()));
      let ready = Provider.poll_update t.provider ~max_batches:1 in
      let%map () =
        if Interaction.has_work session || Option.is_some ready
        then Scheduler.yield ()
        else Clock_ns.after (Time_ns.Span.of_int_ms 2)
      in
      if not (same_run t request) || Ches_file_picker.Interaction.closed session
      then []
      else
       let snapshot = match ready with Some _ -> ready | None -> Provider.poll_update t.provider ~max_batches:1 in
       let events = Option.to_list (Option.map snapshot ~f:(fun s -> Ui_state.Input.File_picker_update s)) in
       let status = (Option.value_exn (Provider.current t.provider)).status in
      let working = Ches_file_picker.Interaction.busy session || Option.is_some snapshot in
      match status, working with
      | (Loading | Partial), _ | _, true -> events @ [ Ui_state.Input.File_picker_work request ]
      | (Complete _ | Failed _ | Cancelled), false -> [])
;;

let cancel t = Provider.cancel t.provider; invalidate_cache t
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
       let model = Ches_file_picker.Interaction.model session in
       same_run t (Model.discovery_request model) && not (Ui_state.exited ui)
      && (Ches_file_picker.Interaction.busy session
           || match Model.discovery_status model with Loading | Partial -> true | _ -> false)) in
    if continue then pump t ~current ~inject else return ()
  | _ ->
    let%bind () = inject events in
    pump t ~current ~inject
;;
