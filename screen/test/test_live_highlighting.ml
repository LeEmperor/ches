open! Core
open Ches_core
open Ches_app
open Ches_highlight
open Ches_screen
open Helpers

let count ui = Controller.highlight_parse_count (Ui_state.controller ui)
let snapshot ui = snd (Controller.highlights (Ui_state.controller ui))
let render ?(width = 40) ?(height = 8) ui = Frame.render ui ~width ~height
let syntax_spans frame =
  List.concat frame.Frame.rows |> List.filter_map ~f:(fun span ->
    match span.Span.style with Document d -> Some (span, d) | _ -> None)
;;

let%test_unit "frames, movement, scrolling, resizing, animation, search and selections reuse highlights" =
  let source = String.concat (List.init 100 ~f:(fun i -> sprintf "let item%d = \"é\"\n" i)) in
  let controller = Controller.create (Editor.create ~path:"f.ml" ~cell_width:Cell_map.width
      (Text_buffer.of_string source
       |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
       |> Result.ok_or_failwith)) in
  let base = Ui_state.create ~smear_enabled:true controller in
  let cached = snapshot base in
  let before = count base in
  let ui = run base (keys "jjll<C-e><C-y><C-d><C-u>50Gzzztzb/let<CR>nN<Esc>vll<Esc>Vj<Esc><C-v>j<Esc> v+ vs") in
  assert (count ui = before && phys_equal cached (snapshot ui));
  List.iter [ 40, 8; 80, 24; 3, 2; 0, 0 ] ~f:(fun (width, height) ->
    let frame = render ~width ~height ui in
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
  let ui = List.fold (List.init 20 ~f:(fun i ->
    Ui_state.Input.Animation_tick (Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms (Float.of_int (i * 17))))))
      ~init:ui ~f:(fun ui event -> run ui [ event ]) in
  ignore (render ui : Frame.t);
  assert (count ui = before && phys_equal cached (snapshot ui));
  Controller.close controller
;;

let%test_unit "editing a comment above the viewport changes all visible syntax and undo restores it" =
  let source = "let top = 1\n" ^ String.concat (List.init 80 ~f:(fun _ -> "let item = 42\n")) ^ "*)\n" in
  let ui = ui ~path:"f.ml" source |> fun ui -> run ui (keys "50Gzt") in
  let initial = render ui in
  assert (List.exists (syntax_spans initial) ~f:(fun (_, d) -> Category.equal d.syntax Keyword));
  let ui = run ui (keys "ggi") in
  let before = count ui in
  let ui = run ui (paste "(*<CR>") in
  assert (count ui = before + 1);
  let ui = run ui (keys "<Esc>50Gzt") in
  let frame = render ui in
  assert ((Ui_state.fitted_scroll ui ~width:40 ~height:8).top > 0);
  assert (List.exists (syntax_spans frame) ~f:(fun (_, d) -> Category.equal d.syntax Comment));
  assert (not (List.exists (syntax_spans frame) ~f:(fun (_, d) -> Category.equal d.syntax Keyword)));
  let before = count ui in
  let ui = run ui (keys "u") in
  assert (count ui = before + 1);
  assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) -> Category.equal d.syntax Keyword));
  let ui = run ui (keys "<C-r>") in
  assert (count ui = before + 2);
  Controller.close (Ui_state.controller ui)
;;

let%test_unit "cached provider failure renders plain text, and unsupported paths never parse" =
  let ui = ui ~path:"f.ml" "let x = 1" in
  Controller.For_testing.fail_next_highlight (Ui_state.controller ui);
  let ui = run ui (keys "i <Esc>") in
  let cached = snapshot ui in
  let before = count ui in
  for _ = 1 to 5 do
    List.iter (syntax_spans (render ui)) ~f:(fun (_, d) -> assert (Category.equal d.syntax Plain))
  done;
  assert (count ui = before && phys_equal cached (snapshot ui));
  Controller.close (Ui_state.controller ui);
  List.iter [ "f.txt"; "f.ML"; "extensionless" ] ~f:(fun path ->
    let ui = Helpers.ui ~path "let x = 1" in
    let ui = run ui (keys "i <Esc>u<C-r>") in
    assert (count ui = 0);
    List.iter (syntax_spans (render ui)) ~f:(fun (_, d) -> assert (Category.equal d.syntax Plain));
    Controller.close (Ui_state.controller ui))
;;

let%test_unit "live syntax remains beneath overlays and leaves text geometry unchanged" =
  let ui = ui ~path:"f.mli" "val f : int -> string\n" in
  let before = count ui in
  let ui = run ui (keys "/val<CR>vll") in
  let frame = render ui in
  assert (count ui = before);
  assert (List.exists (syntax_spans frame) ~f:(fun (_, d) ->
    Category.equal d.syntax Keyword && Option.equal Style.Overlay.equal d.overlay (Some Selection)));
  let bad_key = Snapshot.Key.create ~document:(Snapshot.Document_id.create ()) ~revision:(-1)
      ~language:Plain ~configuration:"no-highlights" in
  let plain = Frame.render ~highlights:(bad_key, snapshot ui) ui ~width:40 ~height:8 in
  [%test_result: string] (Frame.to_string frame) ~expect:(Frame.to_string plain);
  List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = 40));
  Controller.close (Ui_state.controller ui)
;;
