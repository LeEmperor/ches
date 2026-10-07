open! Core
open Ches_core
open Ches_screen
module Model = Ches_file_picker.Model
module Interaction = Ches_file_picker.Interaction
module Controller = Ches_app.Controller

let width = 120
let height = 40
let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let apply t inputs = Helpers.run ~width ~height t inputs
let request n : Model.Discovery.request = { run_id = Model.Run_id.of_int n; root = "/project" }
let snapshot ?(status = Model.Discovery.Complete { truncated = false }) n paths : Model.Discovery.t =
  { request = request n; status
  ; candidates = List.map paths ~f:(fun relative_path ->
      Model.Candidate.create ~root:"/project" ~relative_path |> Or_error.ok_exn) }
;;
let picker t = Option.value_exn (Ui_state.file_picker t)
let session t = File_picker_tile.session (picker t)
let work t n = apply t [ File_picker_work (request n) ]
let rec finish t n = if Interaction.busy (session t) then finish (work t n) n else t
let open_picker ?(release = fun () -> ()) t discovery =
  Ui_state.open_file_picker t ~width ~height ~discovery ~release
;;
let text t = Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller t)))

let%test_unit "file-only responsive floating geometry and screen resize delivery teardown" =
  let t = open_picker (Helpers.ui "untouched") (snapshot 90 [ "a.ml" ])
    |> fun t -> finish t 90 in
  List.iter [ 14, 14; 80, 78; 100, 80; 104, 102; 120, 118; 180, 175 ] ~f:(fun (width, outer_width) ->
    let placement = Option.value_exn (Ui_state.file_picker_layout t ~width ~height) in
    assert (placement.outer.width = outer_width && placement.outer.height = 38);
    let left, right = File_picker_tile.columns ~width:placement.content.width in
    assert (left > 0);
    assert (Bool.equal (Option.is_some right) (width >= 104));
    let cursor = Option.value_exn (Ui_state.minor_cursor t ~width ~height) in
    let x, _, _ = cursor in
    assert (x >= placement.content.x && x < placement.content.x + left));
  List.iter [ 5, 5; 6, 6; 7, 5; 24, 22; 30, 28; 40, 38; 42, 40; 48, 40 ] ~f:(fun (height, outer_height) ->
    let placement = Option.value_exn (Ui_state.file_picker_layout t ~width:180 ~height) in
    assert (placement.outer.width = 175 && placement.outer.height = outer_height));
  let model = Interaction.model (session t) in
  let request : Ches_file_preview_model.Model.request =
    { session = (Model.discovery model).request; selected = Option.value_exn (Model.selected model)
    ; generation = 1 } in
  let delivery : Ches_file_preview_model.Model.snapshot = { request; state = Missing } in
  File_picker_tile.expect_preview (picker t) (Some request);
  let t = apply t [ File_preview delivery ] in
  assert (Option.is_some (File_picker_tile.preview (picker t)));
  let t = apply t [ Resize; File_preview delivery ] in
  assert (Option.is_none (File_picker_tile.preview (picker t)));
  let previous = picker t in
  let t = open_picker t (snapshot 91 [ "a.ml" ]) |> fun t -> finish t 91 in
  assert (Option.is_none (File_picker_tile.preview previous));
  let t = apply t [ File_preview delivery ] in
  assert (Option.is_none (File_picker_tile.preview (picker t)));
  let t, requests = Ui_state.take_file_requests t in
  assert (List.is_empty requests && String.equal (text t) "untouched");
  let t = fst (Ui_state.apply_all t ~width:13 ~height:5 [ Resize; File_preview delivery ]) in
  assert (Option.is_none (Ui_state.file_picker t))
;;

let%test_unit "Tab/Shift-Tab route, clamp, reveal, preserve query and accept selected file" =
  let paths = List.init 40 ~f:(sprintf "sub/file%02d.ml") in
  let t = open_picker (Helpers.ui "unchanged") (snapshot 70 paths) |> fun t -> finish t 70 in
  let t = run t "sub" |> fun t -> finish t 70 in
  let selected t = Model.selected (Interaction.model (session t)) in
  let first = selected t in
  let t = run t "<S-Tab><S-Tab>" in
  assert ([%equal: Model.Candidate.Id.t option] first (selected t));
  let t = run t (String.concat (List.init 45 ~f:(fun _ -> "<Tab>"))) in
  let view = File_picker_tile.view (picker t) in
  assert (view.index = 39 && view.top > 0);
  let layout = Option.value_exn (Ui_state.file_picker_layout t ~width ~height) in
  assert (view.index >= view.top && view.index < view.top + layout.content.height - 2);
  assert (String.equal (Interaction.query (session t)) "sub");
  let t = run t "<S-Tab><C-p><C-n>" in
  assert ((File_picker_tile.view (picker t)).index = 38);
  let keep = selected t in
  let t = run t "/" |> fun t -> finish t 70 in
  assert ([%equal: Model.Candidate.Id.t option] keep (selected t));
  assert (String.equal (Interaction.query (session t)) "sub/");
  let expected = Option.value_exn (Model.accept (Interaction.model (session t))) in
  let t = run t "<CR>" in
  assert (Option.is_none (Ui_state.file_picker t));
  let _, intents = Ui_state.take_file_requests t in
  assert (String.equal (List.hd_exn intents).path expected.path && List.length intents = 1);
  assert (String.equal (text t) "unchanged");
  let t = open_picker t (snapshot 71 []) |> fun t -> finish t 71 |> fun t -> run t "<Tab><S-Tab><CR>" in
  assert (Option.is_some (Ui_state.file_picker t) && Option.is_none (selected t));
  assert (Option.is_none (Ui_state.file_picker (run t "<Esc>")))
;;

let%test_unit "shared floating host: zen/workspace, query, scroll, cursor and exact restoration" =
  List.iter [ false; true ] ~f:(fun zen ->
    let initial = Helpers.ui (String.concat ~sep:"\n" (List.init 100 ~f:(sprintf "line %d"))) in
    let initial = run initial (if zen then " vzG" else "G") in
    let workspace = Ui_state.workspace initial ~width ~height in
    let scroll = Ui_state.scroll initial in
    let baseline = Frame.to_string (Frame.render initial ~width ~height) in
    let paths = List.init 300 ~f:(fun n -> sprintf "sub/file%03d.ml" n) in
    let releases = ref 0 in
    let opened = open_picker initial (snapshot 1 paths) ~release:(fun () -> incr releases) in
    assert (Option.is_none (Ui_state.palette opened));
    assert (Interaction.prepared_count (session opened) = 0);
    let opened = work opened 1 in
    assert (Interaction.prepared_count (session opened) = 128);
    let opened = finish opened 1 |> fun t -> run t "file<C-n><C-n>" |> fun t -> finish t 1 in
    let opened = run opened "<C-n><C-n>" in
    assert ([%equal: Workspace.t] workspace (Ui_state.workspace opened ~width ~height));
    assert (Scroll.equal scroll (Ui_state.scroll opened));
    assert (String.equal (text initial) (text opened));
    let layout = Option.value_exn (Ui_state.file_picker_layout opened ~width ~height) in
    assert (layout.content.height >= 3);
    let frame = Frame.render opened ~width ~height in
    let cursor = Option.value_exn frame.cursor in
    let x, y, shape = Option.value_exn (Ui_state.minor_cursor opened ~width ~height) in
    assert (cursor.x = x && cursor.y = y && Ches_tile.Cursor.Shape.equal shape Bar);
    assert (List.is_empty frame.smear);
    let allocation : Geometry.Rect.t = { x = 5; y = 2; width = 60; height = 10 } in
    assert (String.equal
      (Frame.to_string (Frame.render ~allocation initial ~width ~height))
      (Frame.to_string (Frame.render ~allocation opened ~width ~height)));
    let closed = run opened "<Esc>" in
    assert (!releases = 1 && Option.is_none (Ui_state.file_picker closed));
    assert (String.equal baseline (Frame.to_string (Frame.render closed ~width ~height)));
    assert (List.is_empty (snd (Ui_state.take_file_requests closed))))
;;

let%test_unit "accept releases discovery and capture before once-only raw-path consumer" =
  let released = ref false in
  let initial = Helpers.ui "dirty-independent document" in
  let t = open_picker initial (snapshot 2 [ "a\nb.ml" ]) ~release:(fun () -> released := true) in
  let t = run t "<CR>" in
  assert (Option.is_some (Ui_state.file_picker t)); (* pending Enter is not queued *)
  let t = finish t 2 in
  let t = run t "zzzz" |> fun t -> finish t 2 in
  let t = run t "<CR>" in
  assert (Option.is_some (Ui_state.file_picker t) && not !released);
  let t = run t "<C-w>" |> fun t -> finish t 2 in
  let t = run t "<CR>" in
  assert (!released && Option.is_none (Ui_state.file_picker t));
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Ui_state.document_id);
  let t, intents = Ui_state.take_file_requests t in
  assert (List.length intents = 1);
  List.iter intents ~f:(fun intent ->
    assert (!released && String.equal intent.Model.Request.path "/project/a\nb.ml");
    assert (String.equal (text initial) (text t)));
  assert (List.is_empty (snd (Ui_state.take_file_requests t)))
;;

let%test_unit "host paste sanitization and identity selection survive incremental discovery" =
  let initial = Helpers.ui "untouched" in
  let t = open_picker initial (snapshot ~status:Partial 30 [ "sub/a.ml"; "sub/b.ml" ])
    |> fun t -> finish t 30 in
  let t = run t "<C-n>" in
  let selected = Model.selected (Interaction.model (session t)) in
  let t = apply t [ File_picker_snapshot
      (snapshot ~status:Partial 30 [ "first.ml"; "sub/a.ml"; "sub/b.ml" ]) ]
    |> fun t -> finish t 30 in
  assert ([%equal: Model.Candidate.Id.t option] selected (Model.selected (Interaction.model (session t))));
  let t = apply t ([ Ui_state.Input.Paste_start ] @ Helpers.keys "sub" @ [ Ui_state.Input.Key Enter ]
      @ Helpers.keys "b.ml" @ [ Ui_state.Input.Paste_end ]) |> fun t -> finish t 30 in
  assert (String.equal (Interaction.query (session t)) "sub b.ml");
  assert (String.equal (Model.Candidate.relative_path
    (List.hd_exn (Model.results (Interaction.model (session t)))).candidate) "sub/b.ml");
  assert (String.equal (text initial) (text t));
  let t = run t "<C-w>" |> fun t -> finish t 30 in
  assert (String.equal (Interaction.query (session t)) "sub ");
  let t = run t "<Esc>" in
  assert (List.is_empty (snd (Ui_state.take_file_requests t)))
;;

let%test_unit "focus return, one transient, fitting and undersized resize, interrupted paste" =
  let initial = run (Helpers.ui "untouched") " vo" in
  let t = open_picker initial (snapshot 3 [ "a"; "b" ]) |> fun t -> finish t 3 in
  let t = run t "<Esc>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Problems_tile.id);
  let t = open_picker t (snapshot 4 [ "a"; "b" ]) |> fun t -> finish t 4 in
  let t = run t "a" |> fun t -> finish t 4 in
  let selected = Model.selected (Interaction.model (session t)) in
  let t = Helpers.run ~width:14 ~height:5 t [ Resize ] in
  assert (String.equal (Interaction.query (session t)) "a");
  assert ([%equal: Model.Candidate.Id.t option] selected (Model.selected (Interaction.model (session t))));
  let t = apply t (Paste_start :: Helpers.keys "OLD") in
  let releases = ref 0 in
  (* Opening during paste refuses, preserving the existing owner/session. *)
  let refused = open_picker t (snapshot 5 [ "new" ]) ~release:(fun () -> incr releases) in
  assert (!releases = 1 && phys_equal (picker refused) (picker t));
  let t = Helpers.run ~width:13 ~height:5 refused [ Resize ] in
  assert (Option.is_none (Ui_state.file_picker t) && Ui_state.pasting t);
  let t = apply t (Helpers.keys "remaining" @ [ Paste_end ]) in
  assert (String.equal (text initial) (text t));
  assert (String.equal (Option.value_exn (Ui_state.message t)).text "Files closed; paste dropped");
  let t = open_picker t (snapshot 6 [ "new" ]) in
  let t = Ui_state.apply_all t ~width ~height (Helpers.keys " cc") |> fst in
  (* Text input treats workspace prefixes as query, never opens a second float. *)
  assert (Option.is_some (Ui_state.file_picker t) && Option.is_none (Ui_state.palette t));
  let t = run t "<Esc> cc" in
  assert (Option.is_some (Ui_state.palette t) && Option.is_none (Ui_state.file_picker t));
  let t = open_picker t (snapshot 7 [ "a" ]) in
  assert (Option.is_none (Ui_state.palette t) && Option.is_some (Ui_state.file_picker t));
  List.iter [ 0, 0; 14, 4; 13, 100 ] ~f:(fun (width, height) ->
    let t = Helpers.run ~width ~height t [ Resize ] in
    assert (Option.is_none (Ui_state.file_picker t)))
;;

let%test_unit "loading/error/truncation through frame; stale snapshots/work cannot enter replacement" =
  let initial = Helpers.ui "unchanged" in
  let t = open_picker initial (snapshot ~status:Loading 10 []) in
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"Loading files");
  let t = apply t [ File_picker_snapshot (snapshot ~status:Partial 10 [ "a" ]) ] |> fun t -> finish t 10 in
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"partial");
  let t = apply t [ File_picker_snapshot (snapshot ~status:(Failed "install rg") 10 [ "a" ]) ] in
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"install rg");
  let t = apply t [ File_picker_snapshot (snapshot ~status:(Complete { truncated = true }) 10 [ "a" ]) ] in
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"TRUNCATED");
  let old = session t in
  let t = open_picker t (snapshot 11 [ "b" ]) in
  assert (Interaction.closed old);
  let t = apply t [ File_picker_snapshot (snapshot 10 [ "late" ]); File_picker_work (request 10) ] in
  assert (Interaction.prepared_count (session t) = 0);
  let bad_root = { (snapshot 11 [ "late" ]) with request = { (request 11) with root = "/other" } } in
  let t = apply t [ File_picker_snapshot bad_root; File_picker_work bad_root.request ] in
  assert (Interaction.prepared_count (session t) = 0);
  let t = finish t 11 in
  assert ([%equal: string list]
    (List.map (Model.results (Interaction.model (session t))) ~f:(fun r -> Model.Candidate.relative_path r.candidate)) [ "b" ]);
  let t = run t "<Esc>" in
  let t = apply t [ File_picker_snapshot (snapshot 11 [ "late" ]); File_picker_work (request 11) ] in
  assert (String.equal (text initial) (text t) && Option.is_none (Ui_state.file_picker t))
;;

let%test_unit "closed shared palette instance cannot donate a paste to its reopened instance" =
  let module Host = Ches_tile.Host in
  let host = Host.create ~leader:(Ches_input.Key.char ' ') ~primary:Ui_state.document_id
    [ Ches_tile.Spec.primary Ui_state.document_id ~title:"Document"; Palette_tile.spec ] in
  let host = Host.focus host Palette_tile.id |> fun h -> Host.paste_start h ~available:(fun _ -> true) in
  let host = Host.paste_key host (Ches_input.Key.char 'x') in
  let host = Host.invalidate_paste host Palette_tile.id |> Host.return in
  let host = Host.focus host Palette_tile.id in
  match Host.paste_end host with
  | _, `Reject (owner, text) ->
    assert (Ches_tile.View_id.equal owner Palette_tile.id);
    assert (String.equal text "Commands closed; paste dropped")
  | _ -> failwith "old paste was delivered to a reopened view"
;;
