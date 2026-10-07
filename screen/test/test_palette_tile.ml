(* The command palette on the shared host: opening, query input and paste, accepting
   through the controller's shared route, cancelling, and layout changes. *)

open! Core
open Ches_core
open Ches_screen
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller
module Palette = Ches_palette.Palette

let width = 80
let height = 16
let run ?(width = width) ?(height = height) t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let create () = Helpers.ui ~path:"a" "first\nsecond\nthird"

let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let palette t = Option.map (Ui_state.palette t) ~f:Palette_tile.palette

let focused ?(width = width) ?(height = height) t =
  Ches_tile.View_id.to_string (Ui_state.focused_view t ~width ~height)
;;

let%test_unit "floating open/filter/cancel preserves all tiled rectangles, document and scroll" =
  let width, height = 120, 40 in
  let contents = String.concat ~sep:"\n" (List.init 100 ~f:(fun n -> sprintf "line %d 界́" n)) in
  List.iter [ false; true ] ~f:(fun zen ->
    let initial = Ui_state.create ~report:Report_tile.demo
        (Ui_state.controller (Helpers.ui contents)) in
    let initial = run ~width ~height initial (if zen then " vzG" else "G") in
    let workspace = Ui_state.workspace initial ~width ~height in
    let geometry = Ui_state.geometry initial ~width ~height in
    let scroll = Ui_state.scroll initial in
    let before_frame = Frame.render initial ~width ~height in
    if not zen then assert (List.length workspace.minors = 3 && Option.is_some workspace.status);
    let check t =
      assert ([%equal: Workspace.t] workspace (Ui_state.workspace t ~width ~height));
      assert ([%equal: Geometry.Rect.t] geometry.text (Ui_state.geometry t ~width ~height).text);
      assert (Scroll.equal scroll (Ui_state.scroll t));
      assert (String.equal contents (text t));
      assert (Editor.cursor (editor t) = Editor.cursor (editor initial));
      assert (Option.is_none (Ui_state.minor_layout t ~width ~height Palette_tile.id))
    in
    let opened = run ~width ~height initial " cc" in
    check opened;
    let layout = Option.value_exn (Ui_state.palette_layout opened ~width ~height) in
    assert ([%equal: Geometry.Rect.t] layout.outer
      { x = 20; y = 13; width = 80; height = 14 });
    let queried = run ~width ~height opened "###" in
    check queried;
    assert ([%equal: Tile_shell.Layout.t option]
      (Some layout) (Ui_state.palette_layout queried ~width ~height));
    let closed = run ~width ~height queried "<Esc>" in
    check closed;
    assert (Option.is_none (Ui_state.palette closed));
    assert (String.equal (Frame.to_string before_frame)
      (Frame.to_string (Frame.render closed ~width ~height))))
;;

let%test_unit "result selection scrolls within the stable float and survives fitting resizes" =
  let t = run ~width:120 ~height:40 (create ())
      (" cc" ^ String.concat (List.init 20 ~f:(fun _ -> "<C-n>"))) in
  let selected = Option.bind (palette t) ~f:Palette.selected in
  List.iter [ 120, 40; 80, 16; 14, 4; 50, 12; 120, 40 ] ~f:(fun (width, height) ->
    let resized = Helpers.run ~width ~height t [ Resize ] in
    assert ([%equal: Ches_palette.Catalog.Id.t option]
      selected (Option.bind (palette resized) ~f:Palette.selected));
    let tile = Option.value_exn (Ui_state.palette resized) in
    let layout = Option.value_exn (Ui_state.palette_layout resized ~width ~height) in
    let view = Palette_tile.view tile in
    assert (view.index >= view.top && view.index < view.top + layout.content.height - 1);
    assert (layout.framed && layout.content.width >= 12 && layout.content.height >= 2);
    let frame = Frame.render resized ~width ~height in
    let cursor = Option.value_exn frame.cursor in
    let x, y, shape = Option.value_exn (Ui_state.minor_cursor resized ~width ~height) in
    assert (cursor.x = x && cursor.y = y && Ches_tile.Cursor.Shape.equal shape Bar);
    assert (List.is_empty frame.smear))
;;

let%test_unit "unfitting resize closes without execution; interrupted paste remains owned after growth" =
  List.iter [ 13, 40; 120, 3; 0, 0 ] ~f:(fun (small_width, small_height) ->
    let initial = run ~width:120 ~height:40 (create ()) " ccrel num" in
    let prefs = Ui_state.prefs initial in
    let t = Helpers.run ~width:120 ~height:40 initial
        (Ui_state.Input.Paste_start :: Helpers.keys "iXYZ") in
    let t = Helpers.run ~width:small_width ~height:small_height t [ Resize ] in
    assert (Option.is_none (Ui_state.palette t));
    assert (Ui_state.pasting t);
    let t = Helpers.run ~width:120 ~height:40 t
        ([ Ui_state.Input.Resize ] @ Helpers.keys "remaining<CR>" @ [ Ui_state.Input.Paste_end ]) in
    assert (not (Ui_state.pasting t));
    assert (String.equal (text initial) (text t));
    assert (Geometry.Prefs.equal prefs (Ui_state.prefs t));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width:120 ~height:40) Ui_state.document_id);
    assert (String.equal (Option.value_exn (Ui_state.message t)).text "Commands closed; paste dropped"))
;;

let%test_unit "explicit document allocation does not draw the open palette or its cursor" =
  let width, height = 80, 16 in
  let initial = create () in
  let opened = run initial " cc" in
  let allocation : Geometry.Rect.t = { x = 5; y = 2; width = 60; height = 10 } in
  let render t = Frame.render ~allocation t ~width ~height in
  assert (String.equal (Frame.to_string (render initial)) (Frame.to_string (render opened)))
;;

let%test_unit "opening from a docked capture still targets and returns to the document" =
  let initial = run (create ()) " vo" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view initial ~width ~height) Problems_tile.id);
  let workspace = Ui_state.workspace initial ~width ~height in
  let opened = run initial " cc" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view opened ~width ~height) Palette_tile.id);
  assert ([%equal: Workspace.t] workspace (Ui_state.workspace opened ~width ~height));
  let closed = run opened "<Tab>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view closed ~width ~height) Ui_state.document_id);
  assert (String.equal (text initial) (text closed))
;;

(* The open palette's query and up to [limit] result IDs, the selected one marked. *)
let results ?(limit = 3) t =
  match palette t with
  | None -> print_endline "closed"
  | Some palette ->
    printf "query: %S\n" (Palette.query palette);
    List.iter (List.take (Palette.results palette) limit) ~f:(fun result ->
      let id = Ches_palette.Catalog.Entry.id result.item in
      printf
        "%s %s\n"
        (if [%equal: Ches_palette.Catalog.Id.t option] (Some id) (Palette.selected palette)
         then ">"
         else " ")
        (Ches_palette.Catalog.Id.to_string id))
;;

let band ?(width = width) ?(height = height) t =
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  let layout = Option.value_exn (Ui_state.palette_layout t ~width ~height) in
  let outer = layout.outer in
  let preview = List.take (List.drop lines outer.y) (Int.min 4 (outer.height - 1)) in
  print_endline (String.concat ~sep:"\n"
    (preview @ [ List.nth_exn lines (outer.y + outer.height - 1); List.last_exn lines ]))
;;

let message t =
  print_s [%sexp (Option.map (Ui_state.message t) ~f:(fun m -> m.text) : string option)]
;;

let%expect_test "Space c c opens a centered floating palette, with a bar cursor" =
  let t = run (create ()) " cc" in
  print_endline (focused t);
  results t;
  [%expect
    {|
    palette
    query: ""
    > file.save
      tabs.next
      tabs.previous
    |}];
  band t;
  [%expect
    {|
    │╭─ Commands ─────────────────────────────────────────────────────────────────╮│|
    ││ >                                                                          ││|
    ││ > Save buffer                                                      Space w ││|
    ││   Next file tab                                                  Space b n ││|
    ╰╰─ 1/52 | Enter run, Ctrl-n/p, Esc ──────────────────────────────────────────╯╯|
    cursor: 5,2 Bar
    |}]
;;

let%expect_test "typed text, Space and j/k included, is query text; Enter runs the command once" =
  let t = create () in
  let before = Ui_state.prefs t in
  let t = run t " ccrel num" in
  results t;
  [%expect
    {|
    query: "rel num"
    > view.toggle-relative-numbers
      document.lines
      problems.toggle-filter
    |}];
  band t;
  [%expect {|
    │╭─ Commands ─────────────────────────────────────────────────────────────────╮│|
    ││ > rel num                                                                  ││|
    ││ > Toggle relative line numbers                                   Space v N ││|
    ││   Search current document lines                                  Space f l ││|
    ╰╰─ 1/3 | Enter run, Ctrl-n/p, Esc ───────────────────────────────────────────╯╯|
    cursor: 12,2 Bar
    |}];
  let t = run t "<CR>" in
  print_s
    [%message
      (focused t : string)
        (text t : string)
        (Editor.is_dirty (editor t) : bool)
        (Editor.cursor (editor t) : int)
        (before.line_numbers : Line_numbers.t)
        ((Ui_state.prefs t).line_numbers : Line_numbers.t)];
  results t;
  [%expect {|
    (("focused t" document) ("text t"  "first\
                                      \nsecond\
                                      \nthird")
     ("Editor.is_dirty (editor t)" false) ("Editor.cursor (editor t)" 0)
     (before.line_numbers Off) ("(Ui_state.prefs t).line_numbers" Relative))
    closed
    |}];
  (* The palette is gone: keys reach the document again. *)
  let t = run t "x" in
  print_s [%sexp (text t : string)];
  [%expect {|
     "irst\
    \nsecond\
    \nthird"
    |}]
;;

let%expect_test "realistic queries find the relative-number toggle first" =
  List.iter [ "rel num"; "rln"; "gutter relative"; "rnu" ] ~f:(fun query ->
    results ~limit:1 (run (create ()) (" cc" ^ query)));
  [%expect {|
    query: "rel num"
    > view.toggle-relative-numbers
    query: "rln"
    > view.toggle-relative-numbers
    query: "gutter relative"
    > view.toggle-relative-numbers
    query: "rnu"
    > view.toggle-relative-numbers
    |}]
;;

let%expect_test "Ctrl-n/p select; filtering keeps the selected command while it matches" =
  let t = run (create ()) " cctile" in
  results ~limit:4 t;
  let t = run t "<C-n><C-n>" in
  results ~limit:4 t;
  let t = run t " le" in
  results ~limit:4 t;
  let t = run t "<C-p><C-p><C-p>" in
  results ~limit:2 t;
  [%expect {|
    query: "tile"
    > view.move-tile-left-2
      view.move-tile-right-2
      view.move-tile-left-10
      view.move-tile-right-10
    query: "tile"
      view.move-tile-left-2
      view.move-tile-right-2
    > view.move-tile-left-10
      view.move-tile-right-10
    query: "tile le"
      view.move-tile-left-2
    > view.move-tile-left-10
      workspace.status-left
      view.move-tile-right-2
    query: "tile le"
    > view.move-tile-left-2
      view.move-tile-left-10
    |}]
;;

let%expect_test "Escape cancels: nothing runs, search and problems are untouched" =
  let t = run (create ()) "/sec<CR>" in
  let t =
    Ui_state.update_feedback t ~width ~height
      (Failed ({ source = "file"; kind = Save; resource = "a" }, Error, "Failed to write a"))
  in
  let feedback = Controller.feedback (Ui_state.controller t) in
  let prefs = Ui_state.prefs t in
  let t = run t " ccrel<Esc>" in
  print_s
    [%message
      (focused t : string)
        (Geometry.Prefs.equal prefs (Ui_state.prefs t) : bool)
        (Option.is_some (Editor.search_state (editor t)) : bool)
        (Feedback.problems feedback
         |> List.map ~f:(fun p -> p.attention)
         : bool list)
        (Feedback.problems (Controller.feedback (Ui_state.controller t))
         |> List.map ~f:(fun p -> p.attention)
         : bool list)];
  results t;
  [%expect {|
    (("focused t" document)
     ("Geometry.Prefs.equal prefs (Ui_state.prefs t)" true)
     ("Option.is_some (Editor.search_state (editor t))" true)
     ("(Feedback.problems feedback) |> (List.map ~f:(fun p -> p.attention))"
      (true))
     ( "(Feedback.problems (Controller.feedback (Ui_state.controller t))) |>\
      \n  (List.map ~f:(fun p -> p.attention))" (true)))
    closed
    |}];
  (* Reopening starts afresh: the query was discarded. *)
  results (run t " cc");
  [%expect {|
    query: ""
    > file.save
      tabs.next
      tabs.previous
    |}]
;;

let%expect_test "Tab and Ctrl-c are the host's; no match leaves the palette open" =
  let t = run (create ()) " cc###" in
  let t = run t "<CR>" in
  print_endline (focused t);
  print_s [%sexp (Ui_state.capture_notice t : string option)];
  let t = run t "<C-c>" in
  print_s [%sexp (Ui_state.capture_notice t : string option)];
  let t = run t "<Tab>" in
  print_endline (focused t);
  results t;
  [%expect {|
    palette
    ("No matching command")
    ("Escape returns to the editor")
    document
    closed
    |}]
;;

let%expect_test "Ctrl-w and Ctrl-h (Ctrl-Backspace) delete a word of the query" =
  let t = run (create ()) " ccgutter rel num" in
  let t = run t "<C-w>" in
  results ~limit:1 t;
  let t = run t "<C-h>" in
  results ~limit:1 t;
  print_s [%sexp (text t : string)];
  [%expect {|
    query: "gutter rel "
    > view.toggle-relative-numbers
    query: "gutter "
      view.toggle-absolute-numbers
     "first\
    \nsecond\
    \nthird"
    |}]
;;

let%expect_test "a paste goes into the query, never the document" =
  let t = run (create ()) " cc" in
  let t = Helpers.run ~width ~height t (Helpers.paste "rel<CR>num") in
  results ~limit:1 t;
  print_s [%sexp (text t : string)];
  [%expect {|
    query: "rel num"
    > view.toggle-relative-numbers
     "first\
    \nsecond\
    \nthird"
    |}]
;;

let%expect_test "a paste whose palette closes mid-paste is dropped, not redirected" =
  let t = run (create ()) " cc" in
  let t =
    Helpers.run ~width ~height t (Ui_state.Input.Paste_start :: Helpers.keys "iXYZ")
  in
  (* Shrinking below the framed query/result minimum closes the palette. *)
  let t = Helpers.run ~width ~height:3 t [ Resize ] in
  let t = Helpers.run ~width ~height:3 t (Helpers.keys "remaining" @ [ Paste_end ]) in
  print_endline (focused ~height:3 t);
  results t;
  print_s [%sexp (text t : string)];
  message t;
  [%expect {|
    document
    closed
     "first\
    \nsecond\
    \nthird"
    ("Commands closed; paste dropped")
    |}]
;;

let%expect_test "resizing keeps the query and selected command" =
  let t = run (create ()) " cctile<C-n><C-n><C-n>" in
  let selected t = Option.bind (palette t) ~f:Palette.selected in
  let before = selected t in
  let t = Helpers.run ~width:50 ~height:12 t [ Resize ] in
  print_s
    [%message
      (Option.map (palette t) ~f:Palette.query : string option)
        ([%equal: Ches_palette.Catalog.Id.t option] before (selected t) : bool)];
  band ~width:50 ~height:12 t;
  [%expect {|
    (("Option.map (palette t) ~f:Palette.query" (tile))
     ("([%equal : Ches_palette.Catalog.Id.t option]) before (selected t)" true))
    │╭─ Commands ───────────────────────────────────╮│|
    ││ > tile                                       ││|
    ││   Move document tile left by 2 columns       ││|
    ││   Move document tile right by 2 columns      ││|
    ╰╰─ 4/17 | Enter run, Ctrl-n/p, Esc ────────────╯╯|
    cursor: 9,2 Bar
    |}]
;;

let%expect_test "palette commands share the keyboard's effects and feedback" =
  (* Undo, as [u] would. *)
  let t = run (create ()) "x cc" in
  let t = run t "undo<CR>" in
  print_s [%sexp (text t : string)];
  (* Quit is refused with unsaved changes, as [Space q] is. *)
  let t = run t "x ccquit<CR>" in
  print_s [%sexp (text t : string), (focused t : string)];
  message t;
  (* Focusing another view from the palette works like its binding. *)
  let t = run t " ccfocus problems<CR>" in
  print_endline (focused t);
  (* Forced quit exits. *)
  let (_ : Ui_state.t) = run t "<Esc> ccquit discarding<CR>" in
  [%expect {|
     "first\
    \nsecond\
    \nthird"
    ( "irst\
     \nsecond\
     \nthird" document)
    ("Unsaved changes: a; save them or force quit (Space Q)")
    problems
    EXIT
    |}]
;;

let%expect_test "zen and compact workspaces allow it; undersized terminals refuse with feedback" =
  let t = run (create ()) " vz cc" in
  print_endline (focused t);
  message t;
  let t = run ~height:4 (create ()) " cc" in
  print_endline (focused ~height:4 t);
  message t;
  let t = run ~height:3 (create ()) " cc" in
  print_endline (focused ~height:3 t);
  message t;
  let t = run ~width:13 (create ()) " cc" in
  print_endline (focused ~width:13 t);
  message t;
  [%expect {|
    palette
    ("Zen (status hidden)")
    palette
    ()
    document
    ("Command palette cannot fit; needs at least 14 columns and 4 rows")
    document
    ("Command palette cannot fit; needs at least 14 columns and 4 rows")
    |}]
;;

let%expect_test "with the band full, the palette does not take a tiled slot" =
  let t = Ui_state.create ~tiles_visible:false ~report:Report_tile.demo (Ui_state.controller (create ())) in
  let t = run ~width:40 t " vb vd vm cc" in
  print_s
    [%sexp
      (List.map (Ui_state.workspace t ~width:40 ~height).minors ~f:(fun p -> p.id)
       : Workspace.Pane_id.t list)];
  print_endline (focused ~width:40 t);
  [%expect {|
    ((Minor problems) (Minor demo-report))
    palette
    |}]
;;

let%expect_test "every size renders bounded rows, and the cursor stays in the content" =
  List.iter [ 80, 4; 80, 5; 20, 6; 20, 8; 24, 9; 30, 10; 40, 8; 80, 16; 120, 40 ] ~f:(fun (width, height) ->
    let t = run ~width ~height (create ()) " ccsome long query text that will not fit" in
    let frame = Frame.render t ~width ~height in
    assert (List.length frame.rows = height);
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width));
    match Ui_state.palette_layout t ~width ~height, frame.cursor with
    | Some layout, Some cursor ->
      let c = layout.content in
      assert (cursor.x >= c.x && cursor.x < c.x + c.width && cursor.y = c.y);
      printf "%dx%d: palette, cursor %d,%d\n" width height cursor.x cursor.y
    | Some _, None -> printf "%dx%d: palette, no cursor\n" width height
    | None, _ -> printf "%dx%d: %s\n" width height (focused ~width ~height t));
  [%expect {|
    80x4: palette, cursor 43,1
    80x5: palette, cursor 43,1
    20x6: palette, cursor 16,2
    20x8: palette, cursor 16,2
    24x9: palette, cursor 20,2
    30x10: palette, cursor 26,2
    40x8: palette, cursor 36,2
    80x16: palette, cursor 43,2
    120x40: palette, cursor 62,14
    |}]
;;
