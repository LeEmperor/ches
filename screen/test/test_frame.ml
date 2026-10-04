open! Core
open Ches_screen
open Helpers

let lines n = String.concat (List.init n ~f:(fun i -> sprintf "line %d\n" (i + 1)))

(* The default has padding and no line numbers; tests about line numbers start from
   hybrid, without padding. *)
let hybrid = { Geometry.Prefs.default with line_numbers = Hybrid; left_padding = 0 }

let%expect_test "a small file at 80x24 in the centered tile" =
  show ~width:80 ~height:24 (ui "let foo x = x + 1\n\nlet bar = foo 41\n");
  [%expect
    {|
    ╭─ f.txt ──────────────────────────────────────────────────────────────────────╮|
    │  let foo x = x + 1                                                           │|
    │                                                                              │|
    │  let bar = foo 41                                                            │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    ╰──────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  f.txt                                                              1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "styles" =
  show_styled ~width:30 ~height:7 (ui "ab\tc\001\n\nx");
  [%expect
    {|
    Border[╭─] Title[ f.txt ] Border[────────────────────╮]
    Border[│] Text_cursor_line[  ab      c] Special_cursor_line[^A] Text_cursor_line[               ] Border[│]
    Border[│] Text[                            ] Border[│]
    Border[│] Text[  x                         ] Border[│]
    Border[│] Text[                            ] Border[│]
    Border[╰────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ f.txt            1:1 ]
    |}]
;;

let%expect_test "search matches and the current match have distinct styles" =
  let t = run ~width:40 ~height:6 (ui "one two one") (keys "/one<CR>") in
  show_styled ~width:40 ~height:6 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  ] Search_match[one] Text_cursor_line[ two ] Search_match_current[one] Text_cursor_line[                         ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ f.txt                      1:9 ]
    |}]
;;

let%expect_test "a search prompt previews highlights without moving the cursor" =
  let t = run ~width:40 ~height:6 (ui "word two word") (keys "/wo") in
  show_styled ~width:40 ~height:6 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  ] Search_match[wo] Text_cursor_line[rd t] Search_match[wo] Text_cursor_line[ ] Search_match[wo] Text_cursor_line[rd                       ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ f.txt                  ] Pending[/wo] Status[ 1:1 ]
    |}]
;;

let%test_unit "offscreen dense matches do not change viewport highlights" =
  let visible = "signal assign\nsignal assign\nsignal assign\n" in
  let render source =
    let prefs = { Geometry.Prefs.default with line_numbers = Off } in
    let t = run ~width:40 ~height:6 (ui ~prefs source) (keys "/sign") in
    Frame.render t ~width:40 ~height:6
  in
  let small = render (visible ^ "tail") in
  let large = render (visible ^ String.concat (List.init 20_000 ~f:(fun _ -> "signal assign\n"))) in
  (* The status line includes the document length; compare the text rows. *)
  [%test_result: string]
    (Frame.to_string_styled { large with rows = List.take large.rows 5 })
    ~expect:(Frame.to_string_styled { small with rows = List.take small.rows 5 })
;;

let%test_unit "overlapping search highlights survive horizontal scrolling" =
  let t = run ~width:30 ~height:6 (ui (String.make 80 'a')) (keys "50l/aaa") in
  let scroll = Ui_state.fitted_scroll t ~width:30 ~height:6 in
  assert (scroll.left > 0);
  let frame = Frame.render t ~width:30 ~height:6 in
  let row = List.nth_exn frame.rows 1 in
  let is_match (span : Span.t) =
    match span.style with
    | Document { overlay = Some Search_match; _ } -> true
    | _ -> false
  in
  assert (List.exists row ~f:is_match);
  List.iter row ~f:(fun span ->
    if String.contains span.text 'a' then assert (is_match span))
;;

let%test_unit "multiline highlights overlap both viewport edges and retain overlap precedence" =
  let open Ches_core in
  let source = "éaaa\néaaa\néaaa\néaaa\néaaa\néaaa\néaaa" in
  let text = Text_buffer.of_string source
             |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
             |> Result.ok_or_failwith in
  List.iter [ "aaa"; "a\néa"; "éaaa\néaaa\néaaa" ] ~f:(fun query ->
    let editor = Editor.create ~cell_width:Cell_map.width text in
    let editor, _ = Editor.dispatch editor
        (Search { query = Some query; forward = true; count = 1; whole_word = false }) in
    let t = Ui_state.create (Ches_app.Controller.create editor)
            |> fun t -> run ~width:40 ~height:6 t (keys "3jzt") in
    let geometry = Ui_state.geometry t ~width:40 ~height:6 in
    let scroll = Ui_state.fitted_scroll t ~width:40 ~height:6 in
    assert (scroll.top > 0);
    let frame = Frame.render t ~width:40 ~height:6 in
    let candidates = List.init (Text_buffer.length text) ~f:Fn.id
        |> List.filter ~f:(fun at -> Text_buffer.is_boundary text at
             && Search_match.matches text ~query ~whole_word:false ~case_sensitive:false ~at) in
    let current = Option.bind (Editor.search_state editor) ~f:(fun (_, _, _, at) -> at) in
    List.iteri frame.rows ~f:(fun y spans ->
      if y >= geometry.text.y && y < geometry.text.y + geometry.text.height then (
        let line = scroll.top + y - geometry.text.y in
        let glyphs = Cell_map.glyphs (Text_buffer.line_text text line) in
        let cells = List.concat_map spans ~f:(fun span -> List.init span.width ~f:(fun _ -> span.style)) in
        Array.iter glyphs ~f:(fun glyph ->
          let offset = Text_buffer.line_start text line + glyph.pos in
          let matched = List.find candidates ~f:(fun start -> start <= offset && offset < start + String.length query) in
           let overlay = match matched with
             | Some start when Option.value_map current ~default:false ~f:(Int.equal start) -> Some Style.Overlay.Search_current
             | Some _ -> Some Style.Overlay.Search_match
             | None -> None in
           let expected = Style.document ?overlay
               ~current_line:(line = Editor.cursor_line (Ches_app.Controller.editor (Ui_state.controller t))) () in
          assert (Style.equal (List.nth_exn cells (geometry.text.x + glyph.col)) expected)))))
;;

let%expect_test "an empty file" =
  show ~width:30 ~height:6 (ui "");
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │                            │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "a tall file scrolls to keep the cursor visible" =
  let t = run ~width:30 ~height:8 (ui (lines 30)) (keys "jjjjjjjj") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │  line 5                    │|
    │  line 6                    │|
    │  line 7                    │|
    │  line 8                    │|
    │  line 9                    │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            9:1 |
    cursor: 3,5 Block
    |}];
  let t = run ~width:30 ~height:8 t (keys "kkkkkkkkk") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │  line 1                    │|
    │  line 2                    │|
    │  line 3                    │|
    │  line 4                    │|
    │  line 5                    │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "a wide line scrolls horizontally, and the cursor follows" =
  let line = String.concat (List.init 6 ~f:(fun i -> sprintf "%d________" i)) in
  let t = ui (line ^ "\nshort\n") in
  let t = run ~width:30 ~height:6 t (keys (String.make 25 'l')) in
  show ~width:30 ~height:6 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │  0________1________2_______│|
    │  short                     │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt           1:26 |
    cursor: 28,1 Block
    |}];
  (* Moving to a short line returns to cell 0. *)
  let t = run ~width:30 ~height:6 t (keys "j") in
  show ~width:30 ~height:6 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │  0________1________2_______│|
    │  short                     │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            2:5 |
    cursor: 7,2 Block
    |}]
;;

let%expect_test "control characters, C1 controls and bidi overrides show escape forms"
  =
  show
    ~width:40
    ~height:6
    (ui "\027[31mred\027[0m\n\194\133x\226\128\174y\239\187\191z\n");
  [%expect
    {|
    ╭─ f.txt ──────────────────────────────╮|
    │  ^[[31mred^[[0m                      │|
    │  <85>x<202e>y<feff>z                 │|
    │                                      │|
    ╰──────────────────────────────────────╯|
     NORMAL  f.txt                      1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "tabs, wide and zero-width characters" =
  show ~width:40 ~height:6 (ui "\tx\n中文e\204\129!\n");
  [%expect
    {|
    ╭─ f.txt ──────────────────────────────╮|
    │          x                           │|
    │  中文é!                              │|
    │                                      │|
    ╰──────────────────────────────────────╯|
     NORMAL  f.txt                      1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "clipping at the text viewport's edges is exact to the cell" =
  (* Text viewport is 16 cells wide (20 - 4 for the gutter). *)
  let t = ui "ab\tcd\n0123456789abcde中\n0123456789abc\027[0m\n0中x\n0\027x\n" in
  let t = run ~width:20 ~height:6 t (keys "jjllllllllllllllll") in
  (* Lines 4 and 5 show the left edge cutting a wide character and an escape form. *)
  show ~width:20 ~height:6 t;
  [%expect
    {|
    ╭─ f.txt ──────────╮|
    │        cd        │|
    │  23456789abcde中 │|
    │  23456789abc^[[0m│|
    ╰──────────────────╯|
     NORMAL  f.txt 3:17 |
    cursor: 18,3 Block
    |}];
  let t = run ~width:20 ~height:6 t (keys "kk") in
  show ~width:20 ~height:6 t;
  [%expect
    {|
    ╭─ f.txt ──────────╮|
    │  ab      cd      │|
    │  0123456789abcde>│|
    │  0123456789abc^[[│|
    ╰──────────────────╯|
     NORMAL  f.txt  1:5 |
    cursor: 12,1 Block
    |}]
;;

let%expect_test "the cursor sits on the first cell of a TAB, wide character, or \
                 escape form"
  =
  (* The text starts at x = 4, after the gutter. *)
  ignore
    (List.fold [ ""; "l"; "l"; "l"; "i" ] ~init:(ui "\tx中\001") ~f:(fun t k ->
       let t = run ~width:30 ~height:4 t (keys k) in
       show_cursor ~width:30 ~height:4 t;
       t)
     : Ui_state.t);
  [%expect
    {|
    cursor: 2,0 Block
    cursor: 10,0 Block
    cursor: 11,0 Block
    cursor: 13,0 Block
    cursor: 13,0 Bar
    |}]
;;

let%expect_test "tiny and zero dimensions" =
  let t = ui "hello\nworld\n" in
  List.iter
    [ 1, 1; 10, 3; 3, 2; 1, 2; 0, 0; 5, 0; 0, 5 ]
    ~f:(fun (width, height) ->
      printf "-- %dx%d\n" width height;
      show ~width ~height t);
  [%expect
    {|
    -- 1x1
     |
    cursor: none
    -- 10x3
    hello     |
    world     |
     NORMAL   |
    cursor: 0,0 Block
    -- 3x2
    hel|
     NO|
    cursor: 0,0 Block
    -- 1x2
    h|
     |
    cursor: 0,0 Block
    -- 0x0
    cursor: none
    -- 5x0
    cursor: none
    -- 0x5
    |
    |
    |
    |
    |
    cursor: none
    |}]
;;

let%expect_test "status line fields drop by priority as it narrows" =
  let t =
    run
      ~width:80
      (ui ~path:"/home/user/projects/ches/src/some_long_name.ml" "abc")
      (keys "ix<Esc> ")
  in
  List.iter [ 80; 60; 40; 30; 20; 16; 12; 8; 4 ] ~f:(fun width ->
    show ~width ~height:1 t);
  [%expect
    {|
     NORMAL  /home/user/projects/ches/src/some_long_name.ml [+]           Space 1:1 |
    cursor: none
     NORMAL  <projects/ches/src/some_long_name.ml [+] Space 1:1 |
    cursor: none
     NORMAL  <me_long_name.ml [+] Space 1:1 |
    cursor: none
     NORMAL  <me.ml [+] Space 1:1 |
    cursor: none
     NORMAL  [+]  Space |
    cursor: none
     NORMAL   Space |
    cursor: none
     NORMAL     |
    cursor: none
     NORMAL |
    cursor: none
     NOR|
    cursor: none
    |}];
  (* An error message outlasts the other fields. *)
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys "x w") in
  List.iter [ 80; 40; 20 ] ~f:(fun width -> show ~width ~height:1 t);
  [%expect
    {|
     NORMAL  [+] Failed to write /nonexistent-dir/f.txt: No such file or directory  |
    cursor: none
     NORMAL  Failed to write /nonexistent-> |
    cursor: none
     NORMAL  Failed to> |
    cursor: none
    |}]
;;

let%expect_test "the filename in the top border is cut from the left, then omitted" =
  let t = ui ~path:"/home/user/projects/ches/src/some_long_name.ml" "abc" in
  List.iter [ 60; 40; 26; 24; 23 ] ~f:(fun width ->
    let frame = Frame.render t ~width ~height:6 in
    print_endline (List.hd_exn (String.split_lines (Frame.to_string frame))));
  [%expect {|
    ╭─ /home/user/projects/ches/src/some_long_name.ml ─────────╮|
    ╭─ <ojects/ches/src/some_long_name.ml ─╮|
    ╭─ <c/some_long_name.ml ─╮|
    ╭─ <some_long_name.ml ─╮|
    ╭─ <ome_long_name.ml ─╮|
    |}];
  (* Escape forms in the name are mapped, as in the status line. *)
  show_styled ~width:30 ~height:6 (ui ~path:"a\027b.txt" "");
  [%expect {|
    Border[╭─] Title[ a] Title_special[^[] Title[b.txt ] Border[─────────────────╮]
    Border[│] Text_cursor_line[                            ] Border[│]
    Border[│] Text[                            ] Border[│]
    Border[│] Text[                            ] Border[│]
    Border[╰────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ a] Status_special[^[] Status[b.txt         1:1 ]
    |}];
  (* With no path, the border is unbroken. *)
  let no_path =
    Ui_state.create (Ches_app.Controller.create (Ches_core.Editor.create ~cell_width:Cell_map.width Ches_core.Text_buffer.empty))
  in
  show ~width:30 ~height:6 no_path;
  [%expect {|
    ╭────────────────────────────╮|
    │                            │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL                   1:1 |
    cursor: 3,1 Block
    |}]
;;

let%expect_test "status fields as data" =
  let t = run (ui "abc") (keys "x ") in
  print_s [%sexp (Status.fields t : Status_field.t list)];
  [%expect {|
    (((id Mode) (spans (((text " NORMAL ") (width 8) (style (Mode Normal)))))
      (priority 0) (fit Whole) (side Left))
     ((id Filename) (spans (((text f.txt) (width 5) (style Status))))
      (priority 5) (fit Cut_left) (side Left))
     ((id Dirty) (spans (((text [+]) (width 3) (style Dirty)))) (priority 3)
      (fit Whole) (side Left))
     ((id Pending) (spans (((text Space) (width 5) (style Pending))))
      (priority 2) (fit Whole) (side Right))
     ((id Position) (spans (((text 1:1) (width 3) (style Status)))) (priority 4)
      (fit Whole) (side Right)))
    |}]
;;

let%expect_test "line-number styles" =
  let text = String.concat (List.init 4 ~f:(fun i -> sprintf "line %d\n" (i + 1))) in
  (* Hybrid, relative, off, absolute; the cursor on the third line, and a row past the
     end of the document. *)
  let (_ : Ui_state.t) =
    List.fold [ "jj"; " vn"; " vN"; " vn" ] ~init:(ui ~prefs:hybrid text) ~f:(fun t k ->
      let t = run ~width:30 ~height:9 t (keys k) in
      printf "%S\n" k;
      show ~width:30 ~height:9 t;
      t)
  in
  [%expect {|
    "jj"
    ╭─ f.txt ────────────────────╮|
    │  2 line 1                  │|
    │  1 line 2                  │|
    │3   line 3                  │|
    │  1 line 4                  │|
    │  2                         │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            3:1 |
    cursor: 5,3 Block
    " vn"
    ╭─ f.txt ────────────────────╮|
    │  2 line 1                  │|
    │  1 line 2                  │|
    │  0 line 3                  │|
    │  1 line 4                  │|
    │  2                         │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line numb> 3:1 |
    cursor: 5,3 Block
    " vN"
    ╭─ f.txt ────────────────────╮|
    │line 1                      │|
    │line 2                      │|
    │line 3                      │|
    │line 4                      │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line numb> 3:1 |
    cursor: 1,3 Block
    " vn"
    ╭─ f.txt ────────────────────╮|
    │  1 line 1                  │|
    │  2 line 2                  │|
    │  3 line 3                  │|
    │  4 line 4                  │|
    │  5                         │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line numb> 3:1 |
    cursor: 5,3 Block
    |}]
;;

let%expect_test "line numbers at both ends, and after edits add or remove lines" =
  let text = String.concat (List.init 6 ~f:(fun i -> sprintf "line %d\n" (i + 1))) in
  let after k t =
    let t = run ~width:30 ~height:9 t (keys k) in
    printf "%S\n" k;
    show ~width:30 ~height:9 t;
    t
  in
  let (_ : Ui_state.t) =
    ui ~prefs:hybrid text
    |> after ""
    |> after "G"
    |> after "kkonew<Esc>"
    |> after "u"
    |> after " vN"
  in
  [%expect {|
    ""
    ╭─ f.txt ────────────────────╮|
    │1   line 1                  │|
    │  1 line 2                  │|
    │  2 line 3                  │|
    │  3 line 4                  │|
    │  4 line 5                  │|
    │  5 line 6                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            1:1 |
    cursor: 5,1 Block
    "G"
    ╭─ f.txt ────────────────────╮|
    │  5 line 2                  │|
    │  4 line 3                  │|
    │  3 line 4                  │|
    │  2 line 5                  │|
    │  1 line 6                  │|
    │7                           │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            7:1 |
    cursor: 5,6 Block
    "kkonew<Esc>"
    ╭─ f.txt ────────────────────╮|
    │  4 line 2                  │|
    │  3 line 3                  │|
    │  2 line 4                  │|
    │  1 line 5                  │|
    │6   new                     │|
    │  1 line 6                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt [+]        6:3 |
    cursor: 7,5 Block
    "u"
    ╭─ f.txt ────────────────────╮|
    │  3 line 2                  │|
    │  2 line 3                  │|
    │  1 line 4                  │|
    │5   line 5                  │|
    │  1 line 6                  │|
    │  2                         │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            5:1 |
    cursor: 5,4 Block
    " vN"
    ╭─ f.txt ────────────────────╮|
    │  2 line 2                  │|
    │  3 line 3                  │|
    │  4 line 4                  │|
    │  5 line 5                  │|
    │  6 line 6                  │|
    │  7                         │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line numb> 5:1 |
    cursor: 5,4 Block
    |}]
;;

let%expect_test "wide line counts keep the gutter width in every style" =
  let text n = String.concat (List.init n ~f:(fun i -> sprintf "%d\n" (i + 1))) in
  List.iter [ 1000; 120000 ] ~f:(fun n ->
    let t = run ~width:30 ~height:6 (ui ~prefs:hybrid (text n)) (keys "500G") in
    List.iter [ ""; " vN"; " vn" ] ~f:(fun k ->
      let t = run ~width:30 ~height:6 t (keys k) in
      show ~width:30 ~height:6 t));
  [%expect {|
    ╭─ f.txt ────────────────────╮|
    │   2 498                    │|
    │   1 499                    │|
    │500  500                    │|
    ╰────────────────────────────╯|
     NORMAL  f.txt          500:1 |
    cursor: 6,3 Block
    ╭─ f.txt ────────────────────╮|
    │ 498 498                    │|
    │ 499 499                    │|
    │ 500 500                    │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line nu> 500:1 |
    cursor: 6,3 Block
    ╭─ f.txt ────────────────────╮|
    │   2 498                    │|
    │   1 499                    │|
    │   0 500                    │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line nu> 500:1 |
    cursor: 6,3 Block
    ╭─ f.txt ────────────────────╮|
    │     2 498                  │|
    │     1 499                  │|
    │500    500                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt          500:1 |
    cursor: 8,3 Block
    ╭─ f.txt ────────────────────╮|
    │   498 498                  │|
    │   499 499                  │|
    │   500 500                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line nu> 500:1 |
    cursor: 8,3 Block
    ╭─ f.txt ────────────────────╮|
    │     2 498                  │|
    │     1 499                  │|
    │     0 500                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt Line nu> 500:1 |
    cursor: 8,3 Block
    |}]
;;

let%expect_test "line numbers off on a tiny screen" =
  let t = run ~width:18 ~height:6 (ui ~prefs:hybrid "abc\ndef\n") (keys " vn vN") in
  show ~width:18 ~height:6 t;
  let t = run ~width:18 ~height:6 t (keys " vn") in
  show ~width:18 ~height:6 t;
  [%expect {|
    ╭─ f.txt ────────╮|
    │abc             │|
    │def             │|
    │                │|
    ╰────────────────╯|
     NORMAL  <txt 1:1 |
    cursor: 1,1 Block
    abc               |
    def               |
                      |
                      |
                      |
     NORMAL  <txt 1:1 |
    cursor: 0,0 Block
    |}]
;;

let%expect_test "toggling the gutter keeps the cursor on its cell of a wide line" =
  let t =
    run
      ~width:30
      ~height:5
      (ui ~prefs:hybrid "0123456789abcdefghijklmnopqrstuvwxyz")
      (keys "$")
  in
  let (_ : Ui_state.t) =
    List.fold [ ""; " vn vN"; " vn" ] ~init:t ~f:(fun t k ->
      let t = run ~width:30 ~height:5 t (keys k) in
      show ~width:30 ~height:5 t;
      t)
  in
  [%expect {|
    1   abcdefghijklmnopqrstuvwxyz|
                                  |
                                  |
                                  |
     NORMAL  f.txt           1:36 |
    cursor: 29,0 Block
    abcdefghijklmnopqrstuvwxyz    |
                                  |
                                  |
                                  |
     NORMAL  f.txt Line num> 1:36 |
    cursor: 25,0 Block
      1 abcdefghijklmnopqrstuvwxyz|
                                  |
                                  |
                                  |
     NORMAL  f.txt Line num> 1:36 |
    cursor: 29,0 Block
    |}]
;;

let%expect_test "a block selection is drawn by display cells" =
  (* Block 2-4: TAB cells inside it only, a wide glyph cut by its edge whole, and
     nothing on short and empty lines. *)
  let t = run ~width:40 ~height:9 (ui "0123456789\n\tabc\na界bcd\nab\n\n0123456789") (keys "2l<C-v>5j2l") in
  show_styled ~width:40 ~height:9 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text[  01] Selection[234] Text[56789                          ] Border[│]
    Border[│] Text[    ] Selection[   ] Text[   abc                         ] Border[│]
    Border[│] Text[  a] Selection[界bc] Text[d                              ] Border[│]
    Border[│] Text[  ab                                  ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text_cursor_line[  01] Selection[234] Text_cursor_line[56789                          ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode (Visual Blockwise))[ VISUAL BLOCK ] Status[ f.txt                6:5 ]
    |}];
  (* After $, each line to its own end. *)
  let t = run ~width:40 ~height:9 t (keys "$") in
  show_styled ~width:40 ~height:9 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text[  01] Selection[23456789] Text[                          ] Border[│]
    Border[│] Text[    ] Selection[      abc] Text[                         ] Border[│]
    Border[│] Text[  a] Selection[界bcd] Text[                              ] Border[│]
    Border[│] Text[  ab                                  ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text_cursor_line[  01] Selection[23456789] Text_cursor_line[                          ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode (Visual Blockwise))[ VISUAL BLOCK ] Status[ f.txt               6:11 ]
    |}]
;;

let%expect_test "a block selection clips at the viewport's edges" =
  let line = String.concat (List.init 6 ~f:(fun i -> sprintf "%d________" i)) in
  let t = run ~width:30 ~height:6 (ui (line ^ "\n" ^ line)) (keys "10l<C-v>j25l") in
  show_styled ~width:30 ~height:6 t;
  show ~width:30 ~height:6 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[────────────────────╮]
    Border[│] Text[  ] Selection[________2________3________] Border[│]
    Border[│] Text_cursor_line[  ] Selection[________2________3________] Border[│]
    Border[│] Text[                            ] Border[│]
    Border[╰────────────────────────────╯]
    (Mode (Visual Blockwise))[ VISUAL BLOCK ] Status[ f.txt     2:36 ]
    ╭─ f.txt ────────────────────╮|
    │  ________2________3________│|
    │  ________2________3________│|
    │                            │|
    ╰────────────────────────────╯|
     VISUAL BLOCK  f.txt     2:36 |
    cursor: 28,2 Block
    |}]
;;

let%test_unit "a TAB cut by the viewport's edge keeps its block highlight" =
  (* Block from the TAB at cells 16-23 to cell 41 on the next line. *)
  let t =
    run
      ~width:30
      ~height:6
      (ui
         ~prefs:hybrid
         (String.make 16 'a' ^ "\t" ^ String.make 40 'b' ^ "\n" ^ String.make 60 'a'))
      (keys "16l<C-v>j18l")
  in
  let scroll = Ui_state.fitted_scroll t ~width:30 ~height:6 in
  assert (scroll.left > 16 && scroll.left < 24);
  let frame = Frame.render t ~width:30 ~height:6 in
  let row = List.nth_exn frame.rows 1 in
  (* The first text cell is part of a TAB inside the block. *)
  let gutter = 1 + 4 in
  let rec style_at spans x =
    match spans with
    | [] -> assert false
    | (s : Span.t) :: rest -> if x < s.width then s.style else style_at rest (x - s.width)
  in
  assert (match style_at row gutter with
    | Document { overlay = Some Selection; _ } -> true
    | _ -> false)
;;

let%expect_test "block insert draws its cursor and a copy on each other line" =
  (* [A] after cells 3-4: the short line's point is past its end until text is typed
     there. The top line's point is the cursor, in its own style; the terminal
     cursor is hidden. *)
  let t = run (ui "abcdefgh\nab\nabcdefgh") (keys "3l<C-v>2jlA") in
  show_styled t;
  show_cursor t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  abcde] Insert_cursor[f] Text_cursor_line[gh                            ] Border[│]
    Border[│] Text[  ab   ] Insert_point[ ] Text[                              ] Border[│]
    Border[│] Text[  abcde] Insert_point[f] Text[gh                            ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Insert)[ INSERT ] Status[ f.txt                      1:6 ]
    cursor: none
    |}];
  let t = run t (keys "X") in
  show_styled t;
  show_cursor t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  abcdeX] Insert_cursor[f] Text_cursor_line[gh                           ] Border[│]
    Border[│] Text[  ab   X] Insert_point[ ] Text[                             ] Border[│]
    Border[│] Text[  abcdeX] Insert_point[f] Text[gh                           ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Insert)[ INSERT ] Status[ f.txt ] Dirty[[+]] Status[                  1:7 ]
    cursor: none
    |}];
  (* Leaving removes them. *)
  let t = run t (keys "<Esc>") in
  show_styled t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  abcdeXfgh                           ] Border[│]
    Border[│] Text[  ab   X                              ] Border[│]
    Border[│] Text[  abcdeXfgh                           ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ f.txt ] Dirty[[+]] Status[                  1:4 ]
    |}]
;;

let%expect_test "software cursors inside a TAB or wide character, and past a short top line" =
  let t = run ~height:7 (ui "0123456789\n\tabc\na界bcd") (keys "2l<C-v>2jI") in
  show_styled ~height:7 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  0] Insert_cursor[1] Text_cursor_line[23456789                          ] Border[│]
    Border[│] Text[   ] Insert_point[ ] Text[      abc                         ] Border[│]
    Border[│] Text[  a] Insert_point[界] Text[bcd                              ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Insert)[ INSERT ] Status[ f.txt                      1:2 ]
    |}];
  (* The cursor's own point can be past its line's end too, where typing will put the
     text; the terminal cursor is hidden while the points are drawn. *)
  let t = run ~height:7 (ui "ab\nabcdefgh") (keys "j5l<C-v>kA") in
  show_styled ~height:7 t;
  show_cursor ~height:7 t;
  [%expect {|
    Border[╭─] Title[ f.txt ] Border[──────────────────────────────╮]
    Border[│] Text_cursor_line[  ab    ] Insert_cursor[ ] Text_cursor_line[                             ] Border[│]
    Border[│] Text[  abcdef] Insert_point[g] Text[h                            ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[│] Text[                                      ] Border[│]
    Border[╰──────────────────────────────────────╯]
    (Mode Insert)[ INSERT ] Status[ f.txt                      1:3 ]
    cursor: none
    |}]
;;

let%expect_test "software cursors off screen are not drawn but keep their places" =
  let t = run ~height:5 (ui (String.concat ~sep:"\n" (List.init 8 ~f:(fun i -> sprintf "abc%d" i)))) (keys "l<C-v>7jI") in
  show ~height:5 t;
  print_s [%sexp (Ches_core.Editor.block_insert_points (Ches_app.Controller.editor (Ui_state.controller t)) : (int * int) list)];
  [%expect {|
      abc0                                  |
      abc1                                  |
      abc2                                  |
      abc3                                  |
     INSERT  f.txt                      1:2 |
    cursor: none
    ((0 1) (1 1) (2 1) (3 1) (4 1) (5 1) (6 1) (7 1))
    |}];
  (* Typing reaches them all the same. *)
  let t = run ~height:5 t (keys "X<Esc>G") in
  show ~height:5 t;
  [%expect {|
      aXbc4                                 |
      aXbc5                                 |
      aXbc6                                 |
      aXbc7                                 |
     NORMAL  f.txt [+]                  8:1 |
    cursor: 2,3 Block
    |}];
  (* After $, [A] aims at each line's end: a short line's point is left of the view. *)
  let t = run ~width:30 ~height:6 (ui (String.make 40 'a' ^ "\nbbbbb")) (keys "<C-v>j$AX") in
  show ~width:30 ~height:6 t;
  [%expect {|
    ╭─ f.txt ────────────────────╮|
    │  aaaaaaaaaaaaaaaaaaaaaaaaX │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     INSERT  f.txt [+]       1:42 |
    cursor: none
    |}]
;;

let%expect_test "left padding, with and without line numbers" =
  let text = "abc\ndef\n" in
  List.iter [ Line_numbers.Off; Hybrid ] ~f:(fun line_numbers ->
    let prefs = { Geometry.Prefs.default with line_numbers; left_padding = 2 } in
    show ~width:30 ~height:6 (run ~width:30 ~height:6 (ui ~prefs text) (keys "j")));
  [%expect {|
    ╭─ f.txt ────────────────────╮|
    │  abc                       │|
    │  def                       │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            2:1 |
    cursor: 3,2 Block
    ╭─ f.txt ────────────────────╮|
    │    1 abc                   │|
    │  2   def                   │|
    │    1                       │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            2:1 |
    cursor: 7,2 Block
    |}]
;;

let%expect_test "left padding takes the cursor line's style" =
  let prefs = { Geometry.Prefs.default with left_padding = 2 } in
  show_styled ~width:20 ~height:5 (ui ~prefs "ab\ncd");
  [%expect {|
    Text_cursor_line[  ab                ]
    Text[  cd                ]
    Text[                    ]
    Text[                    ]
    (Mode Normal)[ NORMAL ] Status[ f.txt  1:1 ]
    |}]
;;
