open! Core
open Bonsai_term
open Ches_screen
module M = Ches_file_picker.Model
module I = Ches_file_picker.Interaction

let%test_unit "nonpublishing file work retains workspace/Notty base; visual changes and dimensions redraw" =
  let text = Ches_core.Text_buffer.of_string "underlying\ntext" |> Result.ok |> Option.value_exn in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
  let request : M.Discovery.request = { run_id = M.Run_id.of_int 1; root = "/project" } in
  let discovery : M.Discovery.t =
    { request; status = Complete { truncated = false }; candidates = List.init 1024 ~f:(fun i ->
        M.Candidate.create ~root:"/project" ~relative_path:(sprintf "d%04d/model.ml" i) |> Or_error.ok_exn) } in
  let ui = ref (Ui_state.open_file_picker (Ui_state.create controller) ~width:160 ~height:40
    ~discovery ~release:(fun () -> ())) in
  let session = File_picker_tile.session (Option.value_exn (Ui_state.file_picker !ui)) in
  let cache = Frame.Cache.create () in
  let builds = ref 0 in
  let get width height =
    let frame, base = Frame.Cache.get cache !ui ~width ~height ~draw_base:(fun frame ->
      incr builds; Ches_ui.Editor_view.draw_base frame) in
    let actual = Ches_ui.Editor_view.draw_overlay ~base frame in
    let expected = Ches_ui.Editor_view.draw (Frame.render !ui ~width ~height) in
    assert (Notty.I.equal (View.Private.notty_image actual) (View.Private.notty_image expected));
    base in
  let first = get 160 40 in
  let callbacks = ref 0 in
  for _ = 1 to 7 do
    ui := fst (Frame.Cache.apply_inputs cache !ui ~width:160 ~height:40
      ~after_step:(fun ui -> incr callbacks; ui) [ File_picker_work request ]);
    assert (phys_equal first (get 160 40));
    assert (!builds = 1)
  done;
  assert (!callbacks = 7 && I.busy session);
  while I.busy session do
    ui := fst (Frame.Cache.apply_inputs cache !ui ~width:160 ~height:40 [ File_picker_work request ])
  done;
  ignore (get 160 40 : View.t);
  assert (!builds = 2);
  let step inputs = ui := fst (Frame.Cache.apply_inputs cache !ui ~width:160 ~height:40 inputs);
    ignore (get 160 40 : View.t) in
  step [ Key (Ches_input.Key.char 'm') ]; assert (!builds = 3);
  let before = !builds in
  for _ = 1 to 7 do step [ File_picker_work request ]; assert (!builds = before) done;
  while I.busy session do step [ File_picker_work request ] done;
  assert (!builds = before + 1);
  let model = I.model session in
  let expected : Ches_file_preview_model.Model.request =
    { session = request; selected = Option.value_exn (M.selected model); generation = 1 } in
  let tile = Option.value_exn (Ui_state.file_picker !ui) in
  File_picker_tile.expect_preview tile (Some expected);
  let before = !builds in
  step [ File_preview { request = expected; state = Missing } ]; assert (!builds = before + 1);
  step [ File_picker_snapshot { discovery with status = Complete { truncated = true } } ];
  assert (!builds = before + 2);
  ui := fst (Frame.Cache.apply_inputs cache !ui ~width:100 ~height:30 [ Resize ]);
  ignore (get 100 30 : View.t); assert (!builds = before + 3);
  step [ Key (Ches_input.Key.Ctrl 'c') ]; (* capture notice *)
  assert (!builds > before + 3)
;;
