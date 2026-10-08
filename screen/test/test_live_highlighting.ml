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

let%test_unit "SystemVerilog syntax renders, edits incrementally, and restores on undo" =
  List.iter [ "f.sv"; "f.svh"; "f.v"; "f.vh" ] ~f:(fun path ->
    let ui = ui ~path "module top; logic q; endmodule\n" in
    let original = Snapshot.ranges (snapshot ui) in
    assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) ->
      Category.equal d.syntax Keyword));
    assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) ->
      Category.equal d.syntax Type));
    let before = count ui in
    let ui = run ui (keys "i/*<Esc>A*/<Esc>") in
    assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) ->
      Category.equal d.syntax Comment));
    let ui = run ui (keys "uu") in
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges (snapshot ui)) ~expect:original;
    assert (count ui > before);
    assert (Controller.For_testing.highlight_incremental_count (Ui_state.controller ui) > 0);
    Controller.close (Ui_state.controller ui))
;;

let%test_unit "GAS syntax renders for .s/.S, edits incrementally and restores on undo" =
  List.iter [ "f.s"; "f.S" ] ~f:(fun path ->
    let ui = ui ~path ".text\nmain:\nmovq $foo+8, %rax\n1: jmp 1b\n" in
    let original = Snapshot.ranges (snapshot ui) in
    List.iter [ Category.Keyword; Function; Number; Constant ] ~f:(fun category ->
      assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) ->
        Category.equal d.syntax category)));
    let before = count ui in
    let ui = run ui (keys "i#<Esc>") in
    assert (List.exists (syntax_spans (render ui)) ~f:(fun (_, d) ->
      Category.equal d.syntax Comment));
    let ui = run ui (keys "u") in
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges (snapshot ui)) ~expect:original;
    assert (count ui > before);
    assert (Controller.For_testing.highlight_incremental_count (Ui_state.controller ui) > 0);
    let invalid_key = Snapshot.Key.create ~document:(Snapshot.Document_id.create ())
        ~revision:(-1) ~language:Plain ~configuration:"gas-plain" in
    let colored = render ui in
    let plain = Frame.render ~highlights:(invalid_key, snapshot ui) ui ~width:40 ~height:8 in
    [%test_result: string] (Frame.to_string colored) ~expect:(Frame.to_string plain);
    Controller.close (Ui_state.controller ui))
;;

let%test_unit "frames, movement, scrolling, resizing, animation, search and selections reuse highlights" =
  let source = String.concat (List.init 100 ~f:(fun i -> sprintf "let item%d = \"é\"\n" i)) in
  let controller = Controller.create (Editor.create ~path:"f.ml" ~cell_width:Cell_map.width
      (Text_buffer.of_string source
       |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
       |> Result.ok_or_failwith)) in
  let base = Ui_state.create ~tiles_visible:false ~smear_enabled:true controller in
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
  List.iter [ "f.txt"; "f.ML"; "f.asm"; "extensionless" ] ~f:(fun path ->
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

let%test_unit "acceptance matrix: live mixed-width text, overlays, clipping and tiny dimensions" =
  List.iter [ "f.ml", "let f x = x\n", "let"
            ; "f.mli", "val f : int -> int\n", "val"
            ; "f.txt", "let f x = x\n", "let" ]
    ~f:(fun (path, declaration, keyword) ->
      let source = "(*\té á 界 \001\194\133\226\128\174\n (* nested *)\n*)\n"
                   ^ declaration ^ "(* unfinished" in
      let base = Helpers.ui ~path source in
      let controller = Ui_state.controller base in
      let cached = snapshot base in
      let before = count base in
      let supported = not (String.is_suffix path ~suffix:".txt") in
      assert (before = if supported then 1 else 0);
      let full = render ~width:80 ~height:12 base in
      let display = Frame.to_string full in
      List.iter [ "^A"; "<85>"; "<202e>"; "界"; "á" ] ~f:(fun text ->
        assert (String.is_substring display ~substring:text));
      List.iter [ "\001"; "\194\133"; "\226\128\174" ] ~f:(fun raw ->
        assert (not (String.is_substring display ~substring:raw)));
      if supported then (
        assert (List.exists (syntax_spans full) ~f:(fun (_, d) ->
          d.special && Category.equal d.syntax Comment));
        assert (List.exists (syntax_spans full) ~f:(fun (_, d) -> Category.equal d.syntax Keyword)))
      else List.iter (syntax_spans full) ~f:(fun (_, d) -> assert (Category.equal d.syntax Plain));
      let invalid_key = Snapshot.Key.create ~document:(Snapshot.Document_id.create ())
          ~revision:(-1) ~language:Plain ~configuration:"acceptance-plain" in
      List.iter [ ""; "/" ^ keyword ^ "<CR>"; "/" ^ keyword ^ "<CR>vll"
                ; "/" ^ keyword ^ "<CR>V"; "gg0<C-v>jll"
                ; "gg0<C-v>jI"; "gg0<C-v>jA"; "gg0llllllllll"; "G$" ]
        ~f:(fun sequence ->
          let ui = run base (keys sequence) in
          List.iter [ 0, 0; 1, 1; 2, 2; 3, 2; 8, 4; 40, 8; 80, 24; 160, 48 ]
            ~f:(fun (width, height) ->
              let colored = Frame.render ui ~width ~height in
              let plain = Frame.render ~highlights:(invalid_key, cached) ui ~width ~height in
              [%test_result: string] (Frame.to_string colored) ~expect:(Frame.to_string plain);
              assert (Option.equal Frame.Cursor.equal colored.cursor plain.cursor);
              [%test_result: (int * int) list] colored.smear ~expect:plain.smear;
              assert (List.length colored.rows = height);
              List.iter colored.rows ~f:(fun row -> assert (Span.total_width row = width)));
          assert (count ui = before && phys_equal cached (snapshot ui));
          let editor = Controller.editor (Ui_state.controller ui) in
          [%test_result: string] (Text_buffer.to_string (Editor.text editor)) ~expect:source;
          assert (not (Editor.is_dirty editor)));
      Controller.close controller)
;;
