open! Core
open Ches_screen

let render ?highlight ?(current_line = false) source ~left ~cols =
  Span.of_glyphs
    ?highlight
    (Cell_map.glyphs source)
    ~left
    ~cols
    ~text:(Style.document ~current_line ())
    ~special:(Style.document ~current_line ~special:true ())
;;

let style_at spans col =
  let rec loop spans col =
    match spans with
    | [] -> failwith "cell outside spans"
    | (span : Span.t) :: rest ->
      if col < span.width then span.style else loop rest (col - span.width)
  in
  loop spans col
;;

let text spans = String.concat (List.map spans ~f:(fun (span : Span.t) -> span.text))

let%test_unit "document overlays retain independent underlying components" =
  let base = Style.document ~current_line:true ~special:true () in
  List.iter Style.Overlay.all ~f:(fun overlay ->
    match Style.with_overlay base overlay with
    | Document document ->
      assert (document.current_line);
      assert (document.special);
      assert (Style.Syntax.equal document.syntax Plain);
      assert ([%equal: Style.Overlay.t option] document.overlay (Some overlay));
      assert (Style.equal (Document { document with overlay = None }) base)
    | _ -> assert false)
;;

let%test_unit "merge compares the whole composed style, not just effective colors" =
  let base = Style.document () in
  let selected = Style.document ~overlay:Selection () in
  let selected_current = Style.document ~current_line:true ~overlay:Selection () in
  let spans =
    [ Span.create base "a" ~width:1
    ; Span.create base "b" ~width:1
    ; Span.create selected "c" ~width:1
    ; Span.create selected_current "d" ~width:1
    ; Span.create selected_current "" ~width:0
    ]
    |> Span.merge
  in
  assert (List.length spans = 3);
  assert (String.equal (List.hd_exn spans).text "ab");
  assert (Span.total_width spans = 4)
;;

let%test_unit "current-line fill and padding have no interaction overlay" =
  List.iter [ ""; "ab"; "\t" ] ~f:(fun source ->
    let spans = render source ~current_line:true ~left:0 ~cols:10 in
    assert (Span.total_width spans = 10);
    List.iter spans ~f:(fun span ->
      assert (Style.equal span.style (Style.document ~current_line:true ()))));
  let spans = render "a" ~current_line:true ~left:0 ~cols:4 ~highlight:(fun _ -> Some `Current) in
  assert (Style.equal (style_at spans 0) (Style.document ~current_line:true ~overlay:Search_current ()));
  assert (Style.equal (style_at spans 1) (Style.document ~current_line:true ()))
;;

let%test_unit "all overlays compose on plain text, TABs, and complete control escapes" =
  List.iter
    [ `Match, Style.Overlay.Search_match
    ; `Current, Search_current
    ; `Selection, Selection
    ; `Insert_cursor, Insert_cursor
    ; `Insert_point, Insert_point
    ]
    ~f:(fun (highlight, overlay) ->
      let spans = render "a\t\001" ~current_line:true ~left:0 ~cols:10 ~highlight:(fun _ -> Some highlight) in
      assert (Span.total_width spans = 10);
      assert (String.equal (text spans) "a       ^A");
      List.iter [ 0; 1; 7 ] ~f:(fun col ->
        assert (Style.equal (style_at spans col) (Style.document ~current_line:true ~overlay ())));
      List.iter [ 8; 9 ] ~f:(fun col ->
        assert (Style.equal (style_at spans col) (Style.document ~current_line:true ~special:true ~overlay ()))))
;;

let%test_unit "clipped TAB keeps its overlay; partial escapes and wide markers stay special" =
  let highlight _ = Some `Selection in
  let tab = render "\t" ~left:3 ~cols:2 ~highlight in
  assert (String.equal (text tab) "  ");
  assert (Style.equal (style_at tab 0) (Style.document ~overlay:Selection ()));
  List.iter [ 0, ">"; 1, "<" ] ~f:(fun (left, marker) ->
    let spans = render "界" ~current_line:true ~left ~cols:1 ~highlight in
    assert (String.equal (text spans) marker);
    assert (Span.total_width spans = 1);
    assert (Style.equal (style_at spans 0) (Style.document ~current_line:true ~special:true ())));
  let escape = render "\001" ~left:1 ~cols:1 ~highlight in
  assert (String.equal (text escape) "A");
  assert (Style.equal (style_at escape 0) (Style.document ~special:true ()))
;;

let%test_unit "combining attachment and suppression preserve existing geometry and styles" =
  let combining = "\204\129" in
  let spans = render ("e" ^ combining) ~current_line:true ~left:0 ~cols:3 in
  assert (String.equal (text spans) ("e" ^ combining ^ "  "));
  assert (Span.total_width spans = 3);
  assert (List.length spans = 1);
  (* Historically the zero-width code point uses the base text style even if its
     preceding glyph has an interaction overlay; do not change that in phase 1. *)
  let spans = render ("e" ^ combining) ~left:0 ~cols:1 ~highlight:(fun _ -> Some `Match) in
  assert (List.length spans = 2);
  assert ((List.nth_exn spans 1).width = 0);
  assert (Style.equal (List.nth_exn spans 1).style (Style.document ()));
  List.iter
    [ combining ^ "a", 0, 1, "a"
    ; "\t" ^ combining, 0, 8, "        "
    ; "\001" ^ combining, 0, 2, "^A"
    ; "界" ^ combining, 1, 1, "<"
    ; "e" ^ combining ^ "a", 1, 1, "a"
    ]
    ~f:(fun (source, left, cols, expected) ->
      let spans = render source ~left ~cols in
      assert (String.equal (text spans) expected);
      assert (Span.total_width spans = cols))
;;
