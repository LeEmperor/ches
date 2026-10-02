open! Core
open Ches_screen
open Helpers

let lines n = String.concat (List.init n ~f:(fun i -> sprintf "line %d\n" (i + 1)))

let%expect_test "a small file at 80x24 in the centered tile" =
  show ~width:80 ~height:24 (ui "let foo x = x + 1\n\nlet bar = foo 41\n");
  [%expect
    {|
    ╭─ f.txt ──────────────────────────────────────────────────────────────────────╮|
    │1   let foo x = x + 1                                                         │|
    │  1                                                                           │|
    │  2 let bar = foo 41                                                          │|
    │  3                                                                           │|
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
    cursor: 5,1 Block
    |}]
;;

let%expect_test "styles" =
  show_styled ~width:30 ~height:7 (ui "ab\tc\001\n\nx");
  [%expect
    {|
    Border[╭─] Title[ f.txt ] Border[────────────────────╮]
    Border[│] Gutter_cursor_line[1   ] Text_cursor_line[ab      c] Special_cursor_line[^A] Text_cursor_line[             ] Border[│]
    Border[│] Gutter[  1 ] Text[                        ] Border[│]
    Border[│] Gutter[  2 ] Text[x                       ] Border[│]
    Border[│] Gutter[    ] Text[                        ] Border[│]
    Border[╰────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ f.txt            1:1 ]
    |}]
;;

let%expect_test "an empty file" =
  show ~width:30 ~height:6 (ui "");
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │1                           │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "a tall file scrolls to keep the cursor visible" =
  let t = run ~width:30 ~height:8 (ui (lines 30)) (keys "jjjjjjjj") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │  4 line 5                  │|
    │  3 line 6                  │|
    │  2 line 7                  │|
    │  1 line 8                  │|
    │9   line 9                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            9:1 |
    cursor: 5,5 Block
    |}];
  let t = run ~width:30 ~height:8 t (keys "kkkkkkkkk") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ╭─ f.txt ────────────────────╮|
    │1   line 1                  │|
    │  1 line 2                  │|
    │  2 line 3                  │|
    │  3 line 4                  │|
    │  4 line 5                  │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            1:1 |
    cursor: 5,1 Block
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
    │1   _______1________2_______│|
    │  1 ort                     │|
    │  2                         │|
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
    │  1 0________1________2_____│|
    │2   short                   │|
    │  1                         │|
    ╰────────────────────────────╯|
     NORMAL  f.txt            2:5 |
    cursor: 9,2 Block
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
    │1   ^[[31mred^[[0m                    │|
    │  1 <85>x<202e>y<feff>z               │|
    │  2                                   │|
    ╰──────────────────────────────────────╯|
     NORMAL  f.txt                      1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "tabs, wide and zero-width characters" =
  show ~width:40 ~height:6 (ui "\tx\n中文e\204\129!\n");
  [%expect
    {|
    ╭─ f.txt ──────────────────────────────╮|
    │1           x                         │|
    │  1 中文é!                            │|
    │  2                                   │|
    ╰──────────────────────────────────────╯|
     NORMAL  f.txt                      1:1 |
    cursor: 5,1 Block
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
      2       cd        |
      1 23456789abcde中 |
    3   23456789abc^[[0m|
      1 <x              |
      2 [x              |
     NORMAL  f.txt 3:17 |
    cursor: 19,2 Block
    |}];
  let t = run ~width:20 ~height:6 t (keys "kk") in
  show ~width:20 ~height:6 t;
  [%expect
    {|
    1   ab      cd      |
      1 0123456789abcde>|
      2 0123456789abc^[[|
      3 0中x            |
      4 0^[x            |
     NORMAL  f.txt  1:5 |
    cursor: 13,0 Block
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
    cursor: 4,0 Block
    cursor: 12,0 Block
    cursor: 13,0 Block
    cursor: 15,0 Block
    cursor: 15,0 Bar
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
    Border[│] Gutter_cursor_line[1   ] Text_cursor_line[                        ] Border[│]
    Border[│] Gutter[    ] Text[                        ] Border[│]
    Border[│] Gutter[    ] Text[                        ] Border[│]
    Border[╰────────────────────────────╯]
    (Mode Normal)[ NORMAL ] Status[ a] Status_special[^[] Status[b.txt         1:1 ]
    |}];
  (* With no path, the border is unbroken. *)
  let no_path =
    Ui_state.create (Ches_app.Controller.create (Ches_core.Editor.create Ches_core.Text_buffer.empty))
  in
  show ~width:30 ~height:6 no_path;
  [%expect {|
    ╭────────────────────────────╮|
    │1                           │|
    │                            │|
    │                            │|
    ╰────────────────────────────╯|
     NORMAL                   1:1 |
    cursor: 5,1 Block
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
    List.fold [ "jj"; " vn"; " vN"; " vn" ] ~init:(ui text) ~f:(fun t k ->
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
    ui text |> after "" |> after "G" |> after "kkonew<Esc>" |> after "u" |> after " vN"
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
    let t = run ~width:30 ~height:6 (ui (text n)) (keys "500G") in
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
  let t = run ~width:18 ~height:6 (ui "abc\ndef\n") (keys " vn vN") in
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
  let t = run ~width:30 ~height:5 (ui "0123456789abcdefghijklmnopqrstuvwxyz") (keys "$") in
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
