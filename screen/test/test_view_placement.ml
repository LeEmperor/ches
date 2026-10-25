open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Counter = Test_view_registry.Counter

(* The test-only counter view (see [Test_view_registry]) in tabs and the major split,
   moved by the generic commands alone: default [Space s] bindings for the focused
   view, and test bindings naming the counter by id. *)

let width = 80
let height = 16

let create ?(path = "a") () =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let place c (placement : View_command.Placement.t) =
    leader_v c, Bindings.Target.View (Place_view { view = Some Counter.id; placement })
  in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view Counter.id)
         ; leader_v 'X', View (Toggle_view Counter.id)
         ; place 'T' Tab
         ; place 'S' Split
         ; place 'B' Band
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path "first\nsecond")) in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ View_registry.Entry.install Counter.adapter { count = 0 } ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run ?(width = width) t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let resize t ~width = Helpers.run ~width ~height t [ Resize ]
let focused ?(width = width) t = View_id.to_string (Ui_state.focused_view t ~width ~height)
let count t = (Option.value_exn (View_registry.find (Ui_state.views t) Counter.key)).count

let message t =
  Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)
;;

let placement t =
  Option.value_exn (View_registry.placement (Ui_state.views t) Counter.id)
;;

let rect ({ x; y; width; height } : Geometry.Rect.t) =
  sprintf "%d,%d %dx%d" x y width height
;;

let show ?(width = width) t =
  let w = Ui_state.workspace t ~width ~height in
  printf "%s; focused %s; count %d; %s; notice %s\n"
    (Sexp.to_string [%sexp (placement t : View_registry.Placement.t)])
    (focused ~width t) (count t) (message t)
    (Option.value (Ui_state.capture_notice t) ~default:"(none)");
  printf "document %s%s\n" (rect w.document.rect)
    (String.concat
       (List.map w.minors ~f:(fun pane ->
          sprintf "; %s %s"
            (Sexp.to_string [%sexp (pane.id : Workspace.Pane_id.t)])
            (rect pane.rect))))
;;

let tabs t =
  List.map (Ui_state.tab_items t) ~f:(fun (item : Tab_strip.Item.t) ->
    let label = item.label ^ if item.modified then "*" else "" in
    if item.active then "[" ^ label ^ "]" else label)
  |> String.concat ~sep:" "
  |> print_endline
;;

let screen ?(width = width) t = Frame.to_string (Frame.render t ~width ~height)

let rows ?(width = width) t lines =
  let all = String.split_lines (screen ~width t) in
  List.iter lines ~f:(fun i -> print_endline (List.nth_exn all i))
;;

let%expect_test "a view tab fills the editor area, takes the strip, and keeps focus" =
  let t = run (create ()) " vT" in
  show t;
  tabs t;
  [%expect
    {|
    Tab; focused counter; count 0; Counter in tab strip; notice Counter in tab strip
    document 0,0 80x16
    a [Counter]
    |}];
  let t = run t "++" in
  rows t [ 0; 1; 2; 14; 15 ];
  [%expect
    {|
     1:a [2:Counter]                                                                |
    ╭─ Counter: 2 ─────────────────────────────────────────────────────────────────╮|
    │ **                                                                           │|
    ╰──────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  Counter Counter in tab strip                                           |
    |}];
  (* Returning from the view (Escape, Tab, a closed float) comes back to it: it is
     the editor area's input owner, and the hidden document never has focus. *)
  let t = run t "<Esc>" in
  print_endline (focused t);
  let t = run t "<Tab> cc<Esc>" in
  print_endline (focused t);
  [%expect
    {|
    counter
    counter
    |}];
  (* The palette over it lists its commands first; other commands return to it. *)
  let t = run t " cc<CR>" in
  printf "%s %d\n" (focused t) (count t);
  let t = run t " cczen<CR>" in
  printf "%s %b\n" (focused t) (Ui_state.zen t);
  [%expect
    {|
    counter 3
    counter true
    |}];
  (* Zen hides the strip, not the active view tab. *)
  rows t [ 0; 1 ];
  let t = run t " vz" in
  [%expect
    {|
    ╭─ Counter: 3 ─────────────────────────────────────────────────────────────────╮|
    │ ***                                                                          │|
    |}];
  (* Focusing the focused active tab shows the file tab; again shows the view. *)
  let t = run t " vx" in
  printf "%s; " (focused t);
  tabs t;
  let t = run t " vx" in
  printf "%s; " (focused t);
  tabs t;
  [%expect
    {|
    document; [a] Counter
    counter; a [Counter]
    |}]
;;

let%expect_test "file and view tabs cycle and close together; file tabs are unchanged" =
  let dir = Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "ches-placement-") in
  let file name =
    let path = Filename.concat dir name in
    Out_channel.write_all path ~data:"text\n";
    path
  in
  let b = file "b.txt"
  and c = file "c.txt" in
  Exn.protect
    ~finally:(fun () ->
      List.iter [ b; c ] ~f:Core_unix.unlink;
      Core_unix.rmdir dir)
    ~f:(fun () ->
      let t = create ~path:(Filename.concat dir "a.txt") () in
      let t, _ = Ui_state.open_file t ~width ~height b |> Or_error.ok_exn in
      (* Added after the active entry. *)
      let t = run t " bp vT" in
      tabs t;
      let t, _ = Ui_state.open_file t ~width ~height c |> Or_error.ok_exn in
      tabs t;
      [%expect
        {|
        a.txt [Counter] b.txt
        a.txt Counter b.txt [c.txt]
        |}];
      let t = run t " bn" in
      tabs t;
      let t = run t " bp" in
      tabs t;
      let t = run t " bp bp" in
      tabs t;
      let t = run t " bn" in
      tabs t;
      [%expect
        {|
        [a.txt] Counter b.txt c.txt
        a.txt Counter b.txt [c.txt]
        a.txt [Counter] b.txt c.txt
        a.txt Counter [b.txt] c.txt
        |}];
      (* Closing the active view tab hides the view through the registry and shows
         the active file tab; files and their dirty checks are untouched. *)
      let t = run t "iX<Esc> bp bc" in
      tabs t;
      show t;
      [%expect
        {|
        a.txt [b.txt*] c.txt
        Hidden; focused document; count 0; (none); notice (none)
        document 0,0 80x16
        |}];
      let t = run t " bc" in
      print_endline (String.prefix (message t) 15);
      tabs t;
      [%expect
        {|
        Unsaved buffer:
        a.txt [b.txt*] c.txt
        |}];
      (* Opening a file, even the active one, shows it instead of a view tab. *)
      let t = run t " vT" in
      let t, _ = Ui_state.open_file t ~width ~height b |> Or_error.ok_exn in
      printf "%s; " (focused t);
      tabs t;
      [%expect {| document; a.txt [b.txt*] Counter c.txt |}];
      (* Status rows show the same entries as the top strip. *)
      let t = run t " bn vt bs" in
      rows t [ 0; 1; 2; 3; 4; 5; 6; 7 ];
      [%expect
        {|
        ╭─ Counter: 0 ────────────────────────────────────╮ ╭─ Status ─────────────────╮|
        │                                                 │ │ NORMAL                   │|
        │                                                 │ │ Counter in tab strip     │|
        │                                                 │ │                          │|
        │                                                 │ │  1: a.txt                │|
        │                                                 │ │  2:* b.txt               │|
        │                                                 │ │ >3: Counter              │|
        │                                                 │ │  4: c.txt                │|
        |}];
      ignore (Ui_state.quit_session t ~width ~height ~force:true : _ * _))
;;

let%expect_test "the major split: focus, resize, swap, move between placements" =
  (* An absolute path keeps the document's title independent of the build sandbox. *)
  let t = run (create ~path:"/a" ()) " vS" in
  show t;
  [%expect
    {|
    Split; focused counter; count 0; Counter in split; notice Counter in split
    document 0,0 40x16; (Minor counter) 41,0 39x16
    |}];
  let t = run t "+" in
  rows t [ 0; 1; 15 ];
  [%expect {|
    ╭─ /a ─────────────────────────────────╮ ╭─ Counter: 1 ────────────────────────╮|
    │  first                               │ │ *                                   │|
     NORMAL  /a Counter in split        1:1  ╰─────────────────────────────────────╯|
    |}];
  (* Tab returns to the editor; [Space s f] toggles between the panes. *)
  let t = run t "<Tab>" in
  print_endline (focused t);
  let t = run t " sf" in
  print_endline (focused t);
  let t = run t " sf" in
  print_endline (focused t);
  [%expect
    {|
    document
    counter
    document
    |}];
  let t = run t " s+ s+" in
  show t;
  let t = run t " s+ s+" in
  show t;
  let t = run t " sx" in
  show t;
  [%expect
    {|
    Split; focused document; count 1; Split view right 70% (55 columns); notice (none)
    document 0,0 24x16; (Minor counter) 25,0 55x16
    Split; focused document; count 1; Split view right 80% (63 columns); notice (none)
    document 0,0 16x16; (Minor counter) 17,0 63x16
    Split; focused document; count 1; Split view left 80% (63 columns); notice (none)
    document 64,0 16x16; (Minor counter) 0,0 63x16
    |}];
  let t = run t " s- s- s- s-" in
  show t;
  [%expect
    {|
    Split; focused document; count 1; Split view left 40% (31 columns); notice (none)
    document 32,0 48x16; (Minor counter) 0,0 31x16
    |}];
  (* One placement at a time: the split view moves into the strip and back. *)
  let t = run t " sf st" in
  show t;
  tabs t;
  [%expect
    {|
    Tab; focused counter; count 1; Counter focused; notice Counter in tab strip
    document 0,0 80x16
    a [Counter]
    |}];
  let t = run t " ss" in
  show t;
  tabs t;
  [%expect
    {|
    Split; focused counter; count 1; Counter focused; notice Counter in split
    document 32,0 48x16; (Minor counter) 0,0 31x16
    [a]
    |}];
  let t = run t " sb" in
  show t;
  let t = run t " sh" in
  show t;
  let t = run t " sh" in
  print_endline (message t);
  [%expect
    {|
    Band; focused counter; count 1; Counter focused; notice Counter in bottom band
    document 0,0 80x11; (Minor counter) 0,11 80x5
    Hidden; focused document; count 1; Counter focused; notice Counter closed
    document 0,0 80x16
    No view focused; focus a view to move it
    |}];
  (* [Toggle_view] closes from any placement; [Focus_view] focuses the split view. *)
  let t = run t " vS vX" in
  show t;
  let t = run t " vS<Tab> vx" in
  print_endline (focused t);
  let t = run t " vx" in
  print_endline (focused t);
  [%expect
    {|
    Hidden; focused document; count 1; Counter in split; notice (none)
    document 0,0 80x16
    counter
    document
    |}]
;;

let%expect_test "a count repeats a split resize, clamped like repeated presses" =
  let t = run (create ~path:"/a" ()) " vS<Tab>" in
  let t = run t "2 s+" in
  show t;
  let t = run t "999999 s+" in
  show t;
  let t = run t "999999 s-" in
  show t;
  let t = run t "3 sx" in
  show t;
  [%expect
    {|
    Split; focused document; count 0; Split view right 70% (55 columns); notice (none)
    document 0,0 24x16; (Minor counter) 25,0 55x16
    Split; focused document; count 0; Split view right 80% (63 columns); notice (none)
    document 0,0 16x16; (Minor counter) 17,0 63x16
    Split; focused document; count 0; Split view right 20% (24 columns); notice (none)
    document 0,0 55x16; (Minor counter) 56,0 24x16
    Split; focused document; count 0; Space s x does not take a count; notice (none)
    document 0,0 55x16; (Minor counter) 56,0 24x16
    |}]
;;

let%expect_test "a split view beside a view tab, the status tile and zen" =
  let t = run (create ()) " vt vS" in
  show t;
  [%expect
    {|
    Split; focused counter; count 0; Counter in split; notice Counter in split
    document 0,0 25x16; (Minor counter) 26,0 25x16
    |}];
  (* Zen hides the split pane, keeping its placement and focus request. *)
  let t = run t " vz" in
  show t;
  let t = run t " vz" in
  show t;
  [%expect
    {|
    Split; focused document; count 0; Counter in split; notice (none)
    document 0,0 80x16
    Split; focused document; count 0; Workspace restored; notice (none)
    document 0,0 25x16; (Minor counter) 26,0 25x16
    |}];
  (* A second view in the split closes the first: here history, from the band. *)
  let t = run t " vm vM ss" in
  show t;
  print_s [%sexp (View_registry.split (Ui_state.views t) : View_id.t option)];
  [%expect
    {|
    Hidden; focused history; count 0; History focused; notice History in split
    document 0,0 25x16; (Minor history) 26,0 25x16
    (history)
    |}]
;;

let%expect_test "a narrow terminal hides the split with a notice and restores it" =
  let t = run (create ()) " vS" in
  let t = resize t ~width:40 in
  show ~width:40 t;
  [%expect
    {|
    Split; focused document; count 0; Counter split hidden: needs 41 columns; notice (none)
    document 0,0 40x16
    |}];
  (* Placing it while too narrow says so; the placement is kept. *)
  let t = run ~width:40 t " vX vS" in
  printf "%s; %s\n" (focused ~width:40 t) (message t);
  let t = run ~width:40 t " sf" in
  printf "%s; %s\n" (focused ~width:40 t) (message t);
  [%expect
    {|
    document; Counter split hidden: needs 41 columns
    document; No split view shown
    |}];
  let t = resize t ~width:41 in
  show ~width:41 t;
  [%expect
    {|
    Split; focused document; count 0; Counter split restored; notice No split view shown
    document 0,0 16x16; (Minor counter) 17,0 24x16
    |}]
;;

let%expect_test "the split coexists with the side directory, which keeps its share" =
  let dir = Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "ches-placement-") in
  let path = Filename.concat dir "a.txt" in
  Out_channel.write_all path ~data:"text\n";
  Exn.protect
    ~finally:(fun () ->
      Core_unix.unlink path;
      Core_unix.rmdir dir)
    ~f:(fun () ->
      let t = create ~path () in
      let t = run t " ds vS" in
      show t;
      [%expect
        {|
        Split; focused counter; count 0; Counter in split; notice Counter in split
        document 33,0 22x16; (Minor directory) 0,0 32x16; (Minor counter) 56,0 24x16
        |}];
      (* The split view gives way first; the side directory then shrinks too. *)
      let t = resize t ~width:72 in
      show ~width:72 t;
      [%expect
        {|
        Split; focused directory; count 0; Counter split hidden: needs 41 columns; notice (none)
        document 33,0 39x16; (Minor directory) 0,0 32x16
        |}];
      ignore (Ui_state.quit_session t ~width ~height ~force:true : _ * _))
;;
