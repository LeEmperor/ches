open! Core
open Ches_core
open Ches_screen
open Ches_highlight
open Helpers

let editor ui = Ches_app.Controller.editor (Ui_state.controller ui)
let key ?(document = Snapshot.Document_id.create ()) ?(language = Language.Ocaml)
    ?(configuration = "synthetic-v1") ui =
  Snapshot.Key.create ~document ~revision:(Editor.revision (editor ui)) ~language ~configuration
;;
let range start stop category = { Snapshot.Range.start; stop; category }
let highlights ui ranges =
  let key = key ui in
  key, Snapshot.create ~key ~source:(Text_buffer.to_string (Editor.text (editor ui))) ranges
;;
let render ?highlights ui = Frame.render ?highlights ui ~width:30 ~height:7
let document_spans frame =
  List.concat frame.Frame.rows |> List.filter_map ~f:(fun s ->
    match s.Span.style with Document d -> Some (s, d) | _ -> None)
;;
let has_syntax frame =
  List.exists (document_spans frame) ~f:(fun (_, d) -> not (Category.equal d.syntax Plain))
;;
let same_geometry plain colored =
  [%test_result: string] (Frame.to_string colored) ~expect:(Frame.to_string plain);
  assert (Option.equal Frame.Cursor.equal colored.cursor plain.cursor);
  [%test_result: (int * int) list] colored.smear ~expect:plain.smear;
  List.iter colored.rows ~f:(fun row -> assert (Span.total_width row = colored.width))
;;

let%test_unit "synthetic multiline Unicode highlights leave geometry and blank padding unchanged" =
  let ui = ui "é\n界x\n" in
  let highlights = highlights ui [ range 0 6 Comment; range 3 6 Type; range 6 7 Number ] in
  let frame = render ~highlights ui in
  same_geometry (render ui) frame;
  List.iter (document_spans frame) ~f:(fun (s, d) ->
    let expected = match s.text with "é" -> Category.Comment | "界" -> Type | "x" -> Number | _ -> Plain in
    [%test_result: Category.t] d.syntax ~expect:expected);
  assert (has_syntax frame)
;;

let%test_unit "frame independently rejects stale revisions and mismatched expected keys" =
  let ui = ui "abc" in
  let document = Snapshot.Document_id.create () in
  let expected = key ~document ui in
  let snapshot = Snapshot.create ~key:expected ~source:"abc" [ range 0 3 Keyword ] in
  assert (has_syntax (render ~highlights:(expected, snapshot) ui));
  List.iter [ key ui; key ~document ~language:Plain ui; key ~document ~configuration:"v2" ui ] ~f:(fun wrong ->
    assert (not (has_syntax (render ~highlights:(wrong, snapshot) ui))));
  let changed = run ui (keys "iX<Esc>") in
  assert (Editor.revision (editor changed) <> Snapshot.Key.revision expected);
  assert (not (has_syntax (render ~highlights:(expected, snapshot) changed)));
  let undo = run changed (keys "u") in
  assert (not (has_syntax (render ~highlights:(expected, snapshot) undo)))
;;

let%test_unit "syntax survives every overlay and returns after selection removal" =
  let base = ui "abc abc\nabc abc" in
  let highlights = highlights base [ range 0 15 Keyword ] in
  List.iter
    [ "/abc<CR>", [ Style.Overlay.Search_match; Search_current ]
    ; "/abc<CR>vll", [ Selection ]
    ; "/abc<CR>V", [ Selection ]
    ; "/abc<CR><C-v>j", [ Selection ]
    ; "<C-v>jI", [ Insert_cursor; Insert_point ]
    ] ~f:(fun (keys_text, overlays) ->
      let ui = run base (keys keys_text) in
      let frame = render ~highlights ui in
      same_geometry (render ui) frame;
      List.iter overlays ~f:(fun overlay ->
        assert (List.exists (document_spans frame) ~f:(fun (_, d) ->
          Option.equal Style.Overlay.equal d.overlay (Some overlay)
          && Category.equal d.syntax Keyword))));
  let selected = run base (keys "vll") in
  let restored = render ~highlights (run selected (keys "<Esc>")) in
  assert (has_syntax restored);
  List.iter (document_spans restored) ~f:(fun (_, d) -> assert (Option.is_none d.overlay))
;;

let%test_unit "offscreen multiline captures and dense spans use current viewport offsets" =
  let source = String.concat (List.init 20_000 ~f:(fun _ -> "abc\n")) in
  let base = ui source in
  let ui = run ~width:30 ~height:7 base (keys "10000Gzt") in
  let first = Text_buffer.line_start (Editor.text (editor ui)) 9999 in
  let highlights = highlights ui
      (range 0 (String.length source) Comment
       :: List.init 20_000 ~f:(fun i -> range (i * 4) (i * 4 + 1) Keyword))
  in
  let frame = render ~highlights ui in
  same_geometry (render ui) frame;
  assert (first > 0);
  assert (has_syntax frame);
  assert (List.exists (document_spans frame) ~f:(fun (s, d) ->
    String.equal s.text "bc" && Category.equal d.syntax Comment))
;;

let%test_unit "syntax on TABs, controls, combining marks and clipped glyphs" =
  let text = Style.document ~current_line:true () in
  let special = Style.document ~current_line:true ~special:true () in
  let spans source ~left ~cols =
    Span.of_glyphs (Cell_map.glyphs source) ~left ~cols ~text ~special
      ~syntax:(fun _ -> Category.String) ~highlight:(fun _ -> Some `Selection)
  in
  let full = spans "á\t\001界" ~left:0 ~cols:12 in
  List.iter full ~f:(fun s ->
    match s.style with
    | Document d when String.for_all s.text ~f:(Char.equal ' ') && Option.is_none d.overlay ->
      assert (Category.equal d.syntax Plain)
    | Document d -> assert (Category.equal d.syntax String)
    | _ -> assert false);
  let combining = List.find_exn full ~f:(fun s -> String.equal s.text "́") in
  (match combining.style with
   | Document d -> assert (Option.is_none d.overlay && Category.equal d.syntax String)
   | _ -> assert false);
  let clipped_wide = spans "界" ~left:1 ~cols:1 in
  assert (Style.equal (List.hd_exn clipped_wide).style special);
  let clipped_escape = spans "\001" ~left:1 ~cols:1 in
  assert (Style.equal (List.hd_exn clipped_escape).style special);
  let clipped_tab = spans "\t" ~left:1 ~cols:2 in
  assert (Style.equal (List.hd_exn clipped_tab).style
    (Style.document ~syntax:String ~current_line:true ~overlay:Selection ()))
;;

let%test_unit "block insertion padding past a short line has no syntax" =
  let ui = ui "abcdef\nx" |> fun ui -> run ui (keys "3l<C-v>jA") in
  let highlights = highlights ui [ range 0 8 Keyword ] in
  let frame = render ~highlights ui in
  same_geometry (render ui) frame;
  assert (List.exists (document_spans frame) ~f:(fun (s, d) ->
    String.for_all s.text ~f:(Char.equal ' ')
    && Option.is_some d.overlay && Category.equal d.syntax Plain));
  List.iter (document_spans frame) ~f:(fun (s, d) ->
    if String.for_all s.text ~f:(Char.equal ' ') then assert (Category.equal d.syntax Plain))
;;

let%test_unit "syntax dump labels hide syntax beneath overlays and special treatment" =
  [%test_result: string]
    (Style.to_string_hum (Style.document ~syntax:Keyword ~current_line:true ()))
    ~expect:"Keyword_cursor_line";
  [%test_result: string]
    (Style.to_string_hum (Style.document ~syntax:Keyword ~overlay:Selection ()))
    ~expect:"Selection";
  [%test_result: string]
    (Style.to_string_hum (Style.document ~syntax:Keyword ~special:true ()))
    ~expect:"Special"
;;
