open! Core
open Bonsai_term
open Ches_screen
open Ches_ui

let%expect_test "production app animation ticks retain base image work" =
  let text = Ches_core.Text_buffer.of_string "abcdef\nsecond"
    |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
  let work = ref 0 and smear = ref 0 in
  let font style =
    (match style with Style.Smear -> incr smear | _ -> incr work);
    Theme.Font.default style in
  let handle = Bonsai_term_test.create_handle
      (Editor_view.app ~smear_enabled:true ~font controller ~exit:(fun () -> Effect.Ignore)) in
  Bonsai_term_test.set_dimensions handle { width = 80; height = 24 };
  let recompute () =
    for _ = 1 to 3 do Bonsai_test.Handle.recompute_view handle done in
  recompute ();
  Bonsai_term_test.send_event handle (Key_press { key = ASCII 'l'; mods = [] });
  recompute ();
  let baseline = !work in
  assert (baseline > 0);
  for _ = 1 to 100 do
    Bonsai_test.Handle.advance_clock_by handle (Time_ns.Span.of_ms 17.);
    recompute ();
    assert (!work = baseline)
  done;
  assert (!smear > 0);
  Bonsai_term_test.send_event handle (Key_press { key = ASCII 'j'; mods = [] });
  recompute ();
  assert (!work > baseline);
  (* Cursor effects are printed by the test terminal on every display. *)
  ignore ([%expect.output] : string);
  printf "100 clock turns: no base span work; next key rebuilds\n";
  [%expect {| 100 clock turns: no base span work; next key rebuilds |}]
;;

let%test_unit "cached animation draws identical Notty images without rebuilding base attributes" =
  let text = Ches_core.Text_buffer.of_string "abc界́def\nsecond\nthird"
    |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
  let ui = ref (Ui_state.create ~smear_enabled:true controller) in
  let keys = List.map (String.to_list "llj") ~f:(fun c ->
    Ui_state.Input.Key (Ches_input.Key.char c)) in
  ui := fst (Ui_state.apply_all !ui ~width:80 ~height:24 keys);
  let static_attrs = ref 0 and overlay_attrs = ref 0 in
  let font style =
    (match style with Style.Smear -> incr overlay_attrs | _ -> incr static_attrs);
    Theme.Font.default style in
  let cache = Frame.Cache.create () in
  let get () = Frame.Cache.get cache !ui ~width:80 ~height:24
      ~draw_base:(Editor_view.draw_base ~font) in
  let _, first_base = get () in
  let initial_work = !static_attrs in
  assert (initial_work > 0);
  for i = 1 to 100 do
    let now = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms (Float.of_int (i * 17))) in
    ui := fst (Ui_state.apply_all !ui ~width:80 ~height:24 [ Animation_tick now ]);
    let frame, base = get () in
    assert (phys_equal first_base base);
    let actual = Editor_view.draw_overlay ~font ~base frame in
    let expected = Editor_view.draw (Frame.render !ui ~width:80 ~height:24) in
    assert (Notty.I.equal (View.Private.notty_image actual) (View.Private.notty_image expected));
    assert (!static_attrs = initial_work)
  done;
  assert (!overlay_attrs > 0);
  assert (Option.is_some (Frame.render !ui ~width:80 ~height:24).cursor)
;;
