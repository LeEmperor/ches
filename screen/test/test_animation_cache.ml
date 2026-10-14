open! Core
open Ches_screen

let equal_frame actual expected =
  assert (Sexp.equal (Frame.sexp_of_t actual) (Frame.sexp_of_t expected))
;;

let tick i = Ui_state.Input.Animation_tick
    (Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms (Float.of_int (i * 17))))
;;

let exercise ~width ~height ui =
  let cache = Frame.Cache.create () in
  let builds = ref 0 in
  let get ui = Frame.Cache.get cache ui ~width ~height ~draw_base:(fun frame ->
    incr builds; frame.rows) in
  let first, rows = get ui in
  let ui = ref ui in
  let saw_smear = ref (not (List.is_empty first.smear)) in
  for i = 1 to 100 do
    let scroll = Ui_state.scroll !ui in
    let problems = Ui_state.problems_tile !ui in
    let history = Ui_state.history_tile !ui in
    ui := Helpers.run ~width ~height !ui [ tick i ];
    (* These adapters allocate on fitting: identity here is a work invariant,
       never a cache key or a claim about arbitrary model equality. *)
    assert (phys_equal scroll (Ui_state.scroll !ui));
    assert (phys_equal problems (Ui_state.problems_tile !ui));
    assert (phys_equal history (Ui_state.history_tile !ui));
    let frame, base = get !ui in
    equal_frame frame (Frame.render !ui ~width ~height);
    assert (phys_equal base rows && phys_equal frame.rows first.rows);
    saw_smear := !saw_smear || not (List.is_empty frame.smear)
  done;
  assert (!builds = 1);
  assert (not (Animation.active (Ui_state.animation !ui)));
  !ui, !saw_smear
;;

let%test_unit "animation reuses rows, skips pane fits, clips smear and restores settled cursor" =
  List.iter [ false; true ] ~f:(fun tiles_visible ->
    List.iter [ 80, 24; 40, 8; 12, 3 ] ~f:(fun (width, height) ->
      let ui = Ui_state.create ~tiles_visible ~smear_enabled:true
          (Ui_state.controller (Helpers.ui "abcdef\nsecond\nthird")) in
      let ui = Helpers.run ~width ~height ui (Helpers.keys "llj") in
      assert (Animation.active (Ui_state.animation ui));
      assert (Option.is_none (Frame.render ui ~width ~height).cursor);
      let ui, saw_smear = exercise ~width ~height ui in
      assert saw_smear;
      assert (Option.is_some (Frame.render ui ~width ~height).cursor)))
;;

let%test_unit "every workspace action invalidates; dimensions independently miss" =
  let cache = Frame.Cache.create () in
  let builds = ref 0 in
  let get ui ~width ~height =
    let frame, _ = Frame.Cache.get cache ui ~width ~height
        ~draw_base:(fun _ -> incr builds) in
    equal_frame frame (Frame.render ui ~width ~height) in
  let ui = ref (Helpers.ui "abcdef\nsecond") in
  get !ui ~width:80 ~height:24;
  List.iter [ "ll"; " vt"; " vb"; " vm"; " vz"; " cc"; "abc"; "<Esc>"; "iZ<Esc>" ]
    ~f:(fun keys ->
      Frame.Cache.invalidate cache;
      ui := Helpers.run ~width:80 ~height:24 !ui (Helpers.keys keys);
      get !ui ~width:80 ~height:24);
  assert (!builds = 10);
  ui := Helpers.run ~width:12 ~height:3 !ui [ tick 1 ];
  get !ui ~width:12 ~height:3;
  assert (!builds = 11)
;;

let%test_unit "floating capture cache retains bar cursor and suppresses animation" =
  let ui = Ui_state.create ~smear_enabled:true
      (Ui_state.controller (Helpers.ui "abcdef\nsecond")) in
  let ui = Helpers.run ~width:80 ~height:24 ui (Helpers.keys "ll cc") in
  let ui, saw_smear = exercise ~width:80 ~height:24 ui in
  assert (not saw_smear);
  assert (Frame.Cursor.equal_shape
    (Option.value_exn (Frame.render ui ~width:80 ~height:24).cursor).shape Bar)
;;

let%test_unit "default off and runtime toggle preserve animation opt-in" =
  let ui = Helpers.ui "abcdef" in
  assert (not (Animation.enabled (Ui_state.animation ui)));
  let ui = Helpers.run ui (Helpers.keys " vsll") in
  assert (Animation.enabled (Ui_state.animation ui));
  assert (Animation.active (Ui_state.animation ui));
  let ui = Helpers.run ui (Helpers.keys " vs") in
  assert (not (Animation.enabled (Ui_state.animation ui)));
  assert (not (Animation.active (Ui_state.animation ui)))
;;
