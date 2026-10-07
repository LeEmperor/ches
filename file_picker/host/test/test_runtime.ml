open! Core
open! Async
open Ches_file_picker_host
open Ches_screen
module Model = Ches_file_picker.Model
module Interaction = Ches_file_picker.Interaction
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor

let fake_rg = Filename_unix.realpath "fake_rg/fake_rg.exe"
let width = 80
let height = 24
let ui () = Ui_state.create (Controller.create (Editor.create ~cell_width:Cell_map.width
  (Ches_core.Text_buffer.of_string "underlying\ntext"
   |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
   |> Result.ok_or_failwith)))
let apply ui inputs = fst (Ui_state.apply_all ui ~width ~height inputs)
let key ui key = apply ui [ Key key ]
let session ui = File_picker_tile.session (Option.value_exn (Ui_state.file_picker ui))
let discovery ui = Model.discovery (Interaction.model (session ui))
let rendered ui = Frame.to_string (Frame.render ui ~width ~height)
let open_picker runtime ui root = Runtime.open_picker runtime ui ~root ~width ~height |> Or_error.ok_exn
let timeout d =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) d with
  | `Result v -> v
  | `Timeout -> failwith "host integration timed out"
;;
let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR -> Array.iter (Sys_unix.readdir path) ~f:(fun p -> remove (Filename.concat path p)); Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;
let with_root mode f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-host" "") in
  Out_channel.write_all (root ^ "/mode") ~data:mode;
  Monitor.protect (fun () -> f root) ~finally:(fun () -> remove root; return ())
;;
let drain runtime state = timeout (Runtime.pump runtime ~current:(fun () -> !state)
  ~inject:(fun inputs -> state := apply !state inputs; return ()))
;;

let%expect_test "real asynchronous provider -> shared host -> isolated once-only raw consumer" =
  with_root "ordered" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg
      ~limits:{ Ches_file_discovery.Provider.Limits.default with batch_size = 1 } () in
    let initial = ui () in
    let state = ref (open_picker runtime initial root) in
    assert (String.is_substring (rendered !state) ~substring:"Loading files");
    let%bind () = drain runtime state in
    assert (Model.Discovery.equal_status (discovery !state).status (Complete { truncated = false }));
    assert (List.length (Model.results (Interaction.model (session !state))) = 4);
    let old_scroll = Ui_state.scroll !state in
    state := key !state (Ches_input.Key.char 'a');
    let%bind () = drain runtime state in
    assert (Interaction.prepared_count (session !state) = 4);
    state := key !state Enter;
    assert (Option.is_none (Ui_state.file_picker !state));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view !state ~width ~height) Ui_state.document_id);
    assert (Scroll.equal old_scroll (Ui_state.scroll !state));
    let next, requests = Ui_state.take_file_requests !state in
    state := next;
    assert (List.length requests = 1);
    List.iter requests ~f:(fun request ->
      assert (String.is_prefix request.Model.Request.path ~prefix:(root ^ "/a"));
      assert (Option.is_none (Ui_state.file_picker !state)));
    assert (List.is_empty (snd (Ui_state.take_file_requests !state)));
    let%bind () = timeout (Runtime.finished runtime) in
    let%map events = Runtime.next runtime !state in
    assert (List.is_empty events))
;;

let%expect_test "provider failures, truncation and empty roots appear through the host frame" =
  Deferred.List.iter ~how:`Sequential [ "partial-failure"; "ordered"; "empty" ] ~f:(fun mode ->
    with_root mode (fun root ->
      let runtime = Runtime.create ~prog:fake_rg
        ~limits:{ Ches_file_discovery.Provider.Limits.default with max_candidates = 2 } () in
      let state = ref (open_picker runtime (ui ()) root) in
      let%bind () = drain runtime state in
      let frame = rendered !state in
      assert (String.is_substring frame ~substring:(match mode with
        | "partial-failure" -> "Discovery failed"
        | "ordered" -> "TRUNCATED"
        | _ -> "No project files"));
      let%map () = timeout (Runtime.finished runtime) in
      Runtime.cancel runtime))
;;

let%expect_test "released acceptance uses session ownership and synchronizes source lifetimes" =
  with_root "empty" (fun root ->
    let path = root ^ "/accepted.ml" in
    Out_channel.write_all path ~data:"let accepted = 1\n";
    let runtime = Runtime.create () in
    let initial = Ui_state.create ~source_attached:true
      (Controller.create (Editor.create ~cell_width:Cell_map.width Ches_core.Text_buffer.empty)) in
    let state = ref (open_picker runtime initial root) in
    let%bind () = drain runtime state in
    String.iter "accepted" ~f:(fun c -> state := key !state (Ches_input.Key.char c));
    let%bind () = drain runtime state in
    let picker_session = session !state in
    state := key !state Enter;
    assert (Interaction.closed picker_session);
    let ui, requests = Ui_state.take_file_requests !state in
    state := ui;
    assert (List.length requests = 1);
    assert (List.is_empty (snd (Ui_state.take_file_requests !state)));
    state := apply !state (List.map requests ~f:(fun r -> Ui_state.Input.File_picker_accept r));
    assert (List.length (Ches_app.Session.buffers (Ui_state.session !state)) = 2);
    assert (Option.equal String.equal (Editor.path (Controller.editor (Ui_state.controller !state))) (Some path));
    assert (Controller.highlight_parse_count (Ui_state.controller !state) > 0);
    let ui, source_requests = Ui_state.take_source_requests !state in state := ui;
    assert (List.exists source_requests ~f:(function
      | Ches_error.Source_request.Document_opened { resource; _ } -> String.equal resource path
      | _ -> false));
    assert (List.exists source_requests ~f:(function
      | Ches_error.Source_request.Document_changed { resource; text; _ } ->
        String.equal resource path && String.equal text "let accepted = 1\n"
      | _ -> false));
    assert (List.is_empty (snd (Ui_state.take_source_requests !state)));
    let old_generation = Ches_app.Session.source_generation (Ui_state.session !state)
      (Option.value_exn (Ches_app.Session.active_id (Ui_state.session !state))) |> Option.value_exn in
    state := fst (Ui_state.close_current !state ~width ~height ~force:false);
    state := fst (Ui_state.open_file !state ~width ~height path |> Or_error.ok_exn);
    let stale = Ches_error.Source_event.Owned { resource = path; generation = old_generation;
      event = Unavailable { source = "stale-picker-test"; root; reason = "STALE" } } in
    state := apply !state [ Source stale ];
    assert (not (String.is_substring (rendered !state) ~substring:"STALE"));
    (* New missing/unsupported files fail without installing any buffer. *)
    let before = Ui_state.session !state in
    assert (Result.is_error (Ches_app.Session.open_or_activate ~must_exist:true before (root ^ "/missing.ml")));
    Out_channel.write_all (root ^ "/invalid.ml") ~data:(String.of_char (Char.of_int_exn 255));
    assert (Result.is_error (Ches_app.Session.open_or_activate ~must_exist:true before (root ^ "/invalid.ml")));
    Core_unix.mkfifo (root ^ "/fifo") ~perm:0o600;
    assert (Result.is_error (Ches_app.Session.open_or_activate ~must_exist:true before (root ^ "/fifo")));
    assert (List.length (Ches_app.Session.buffers before) = 2);
    (* Ordinary startup/new-path semantics remain intentionally permissive. *)
    let new_controller = Controller.open_file ~cell_width:Cell_map.width (root ^ "/new.ml") |> Or_error.ok_exn in
    assert (String.is_empty (Ches_core.Text_buffer.to_string (Editor.text (Controller.editor new_controller))));
    Controller.close new_controller;
    Ches_app.Session.dispose (Ui_state.session !state);
    timeout (Runtime.finished runtime))
;;

let%expect_test "bounded Async turns allow input; cancellation and queued stale turns isolate reopening" =
  with_root "pushback" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg () in
    let initial = ui () in
    let state = ref (open_picker runtime initial root) in
    let old_request = (discovery !state).request in
    let rec spawned () =
      if Sys_unix.file_exists_exn (root ^ "/pid") then return ()
      else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in spawned () in
    let%bind () = timeout (spawned ()) in
    let turns = ref 0 in
    let%bind () = timeout (Runtime.pump runtime ~current:(fun () -> !state)
      ~inject:(fun events ->
        incr turns;
        state := apply !state events;
        if !turns = 5 then state := key !state Escape;
        return ())) in
    assert (!turns = 5 && Option.is_none (Ui_state.file_picker !state));
    let%bind () = timeout (Runtime.finished runtime) in
    let pid = Pid.of_string (In_channel.read_all (root ^ "/pid")) in
    (match Core_unix.wait_nohang (`Pid pid) with
     | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
     | _ -> failwith "child not reaped");
    Out_channel.write_all (root ^ "/mode") ~data:"ordered";
    state := open_picker runtime !state root;
    let replacement = session !state in
    let queued = Runtime.next runtime !state in
    state := key !state Escape;
    state := open_picker runtime !state root;
    let%bind events = queued in
    assert (List.is_empty events && Interaction.closed replacement);
    state := apply !state [ File_picker_work old_request
      ; File_picker_snapshot { request = old_request; candidates = []; status = Failed "OLD ERROR" } ];
    assert (Interaction.prepared_count (session !state) = 0);
    let%bind () = drain runtime state in
    assert (not (String.is_substring (rendered !state) ~substring:"OLD ERROR"));
    assert (String.equal
      (Ches_core.Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller !state))))
      (Ches_core.Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller initial)))));
    state := key !state Escape;
    timeout (Runtime.finished runtime))
;;
