open! Core
open Ches_screen
open Helpers

let%test_unit "practice scrambles have valid moves without redundant axis runs" =
  let random = Random.State.make [| 42 |] in
  let axis = function 'U' | 'D' -> 0 | 'R' | 'L' -> 1 | _ -> 2 in
  for _ = 1 to 1000 do
    let moves = String.split (Rubiks_tile.generate random) ~on:' ' in
    assert (List.length moves = 20);
    List.iter moves ~f:(fun move ->
      assert (String.contains "UDRLFB" move.[0]);
      assert (List.mem [ ""; "'"; "2" ] (String.drop_prefix move 1) ~equal:String.equal));
    let rec check = function
      | a :: (b :: rest as tail) ->
        assert (Char.(a.[0] <> b.[0]));
        (match rest with
         | c :: _ -> assert (axis a.[0] <> axis b.[0] || axis b.[0] <> axis c.[0])
         | [] -> ());
        check tail
      | _ -> ()
    in
    check moves
  done
;;

let%test_unit "timer records the scramble being solved and cancels without a result" =
  let tile = Rubiks_tile.create () in
  let scramble = tile.scramble in
  let tile = Rubiks_tile.space tile ~now:Time_ns.epoch in
  let finish = Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 12.34) in
  assert (Float.(abs (Rubiks_tile.elapsed (Rubiks_tile.tick tile finish) -. 12.34) < 0.001));
  assert (List.is_empty (Rubiks_tile.cancel tile).solves);
  let tile = Rubiks_tile.space tile ~now:finish in
  assert (not (Rubiks_tile.running tile));
  let solve = List.hd_exn tile.solves in
  assert (String.equal solve.scramble scramble);
  assert (Float.(abs (solve.seconds -. 12.34) < 0.001))
;;

let%test_unit "focused Space belongs to timer; paste and resize cannot edit or record" =
  let run = run ~width:120 ~height:30 in
  let t = run (ui "unchanged") (keys "<Space>vU") in
  assert (Ches_tile.View_id.equal
    (Ui_state.focused_view t ~width:120 ~height:30) Rubiks_tile.id);
  let t = run t (paste " n ") in
  assert (not (Ui_state.timer_running t));
  let t = run t (keys "<Space>") in
  assert (Ui_state.timer_running t);
  let scramble = (Ui_state.rubiks_tile t).scramble in
  let t = run t (keys "n") in
  assert (String.equal scramble (Ui_state.rubiks_tile t).scramble);
  let t = run t (keys "<Space>") in
  assert (List.length (Ui_state.rubiks_tile t).solves = 1);
  let t = run t (keys "<Space><Esc>") in
  assert (not (Ui_state.timer_running t));
  assert (List.length (Ui_state.rubiks_tile t).solves = 1);
  let t = run t (keys "<Space>vU<Space>") in
  assert (Ui_state.timer_running t);
  let t = Helpers.run ~width:10 ~height:2 t [ Resize ] in
  assert (not (Ui_state.timer_running t));
  assert (List.length (Ui_state.rubiks_tile t).solves = 1);
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  assert (String.equal (Ches_core.Text_buffer.to_string (Ches_core.Editor.text editor)) "unchanged")
;;
