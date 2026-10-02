open! Core
open Ches_core
open Ches_screen
open Helpers

let text t =
  Text_buffer.to_string
    (Editor.text (Ches_app.Controller.editor (Ui_state.controller t)))
;;

let message t = print_s [%sexp (Ui_state.message t : Ui_state.Message.t option)]

let%expect_test "message slot: notice, else editor message when a command ran, else \
                 unchanged"
  =
  let t = ui "abc" in
  (* An unbound continuation sets a notice. *)
  let t = run t (keys " z") in
  message t;
  [%expect {| (((kind Warning) (text "Space z is not bound"))) |}];
  (* Ignored keys and the first key of a sequence leave the slot alone. *)
  let t = run t (keys "Z ") in
  message t;
  [%expect {| (((kind Warning) (text "Space z is not bound"))) |}];
  (* A command with no message of its own clears it. *)
  let t = run t (keys "<Esc>l") in
  message t;
  [%expect {| () |}];
  (* Editor feedback appears, info or error. *)
  let t = run t (keys "u") in
  message t;
  [%expect {| (((kind Info) (text "Already at oldest change"))) |}];
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys " w") in
  message t;
  [%expect
    {|
    (((kind Error)
      (text "Failed to write /nonexistent-dir/f.txt: No such file or directory")))
    |}]
;;

let%expect_test "Ctrl-c hints at Space q, in either mode, and never exits" =
  let t = run (ui "abc") (keys "<C-c>") in
  message t;
  show ~width:50 ~height:3 t;
  [%expect
    {|
    (((kind Warning) (text "To quit, use Space q in Normal mode")))
    1   abc                                           |
                                                      |
     NORMAL  f.txt To quit, use Space q in Norma> 1:1 |
    cursor: 4,0 Block
    |}];
  let t = run t (keys "ix<C-c>") in
  print_s [%sexp (text t : string)];
  message t;
  [%expect
    {|
    xabc
    (((kind Warning) (text "To quit, use Space q in Normal mode")))
    |}]
;;

let%expect_test "a bracketed paste is one literal insertion, even of Normal-mode keys"
  =
  let t = run (ui "") (keys "i" @ paste " q<Tab>jk<Esc>u" @ keys "<Esc>") in
  print_s [%sexp (text t : string)];
  [%expect {| " q\tjku" |}];
  (* One undo removes the whole paste: it was one insertion inside one transaction. *)
  let t = run t (keys "u") in
  print_s [%sexp (text t : string)];
  [%expect {| "" |}];
  (* In Normal mode a paste is ignored, with a notice, and runs nothing. *)
  let t = run (ui "abc") (paste " Qx") in
  print_s [%sexp (text t : string)];
  message t;
  [%expect
    {|
    abc
    (((kind Warning) (text "Paste ignored in Normal mode")))
    |}];
  print_s [%sexp (Ui_state.pasting t : bool)];
  [%expect {| false |}]
;;

let%expect_test "quitting: refused while dirty, forced, and clean" =
  let t = run (ui "abc") (keys "x q") in
  message t;
  [%expect {| (((kind Error) (text "Unsaved changes: save them or force quit"))) |}];
  let (_ : Ui_state.t) = run t (keys " Q") in
  [%expect {| EXIT |}];
  (* Inputs after the exit are not applied. *)
  let t, status = Ui_state.apply_all (ui "abc") ~width:40 ~height:8 (keys " qx") in
  print_s [%message (status : Ches_app.Controller.Status.t) (text t : string)];
  [%expect {| ((status Exit) ("text t" abc)) |}];
  (* Nor are later batches: a save typed right after a forced quit does nothing. *)
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys "x Q") in
  let t = run t (keys " w") in
  print_s
    [%message
      (Ui_state.exited t : bool) (Ui_state.message t : Ui_state.Message.t option)];
  [%expect
    {|
    EXIT
    EXIT
    (("Ui_state.exited t" true) ("Ui_state.message t" ()))
    |}]
;;

let%expect_test "a burst of keys in one batch equals the keys one at a time" =
  let inputs = keys "ihello<CR>world<Esc>kx" @ paste "!" @ keys "u<C-r>" in
  let batch, _ = Ui_state.apply_all (ui "") ~width:30 ~height:5 inputs in
  let one_by_one =
    List.fold inputs ~init:(ui "") ~f:(fun t input ->
      fst (Ui_state.apply t ~width:30 ~height:5 input))
  in
  print_s [%sexp (text batch : string), (text one_by_one : string)];
  [%expect {|
    ( "hell\
     \nworld"  "hell\
              \nworld")
    |}]
;;

let%expect_test "after a resize the cursor stays visible, and the next input starts \
                 from what was on screen"
  =
  let lines = String.concat (List.init 40 ~f:(fun i -> sprintf "%d\n" (i + 1))) in
  let t = run ~width:30 ~height:30 (ui lines) (keys (String.make 25 'j')) in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  [%expect {| ((top 0) (left 0)) |}];
  (* Shrink: the render fits the scroll to the new size. *)
  print_s [%sexp (Ui_state.fitted_scroll t ~width:30 ~height:8 : Scroll.t)];
  show_cursor ~width:30 ~height:8 t;
  [%expect {|
    ((top 21) (left 0))
    cursor: 5,5 Block
    |}];
  (* One line up from there keeps the view where it was. *)
  let t = run ~width:30 ~height:8 t (keys "k") in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  [%expect {| ((top 21) (left 0)) |}]
;;

(* The requested preferences, the message, and where the tile and text are. *)
let layout ?(width = 160) ?(height = 48) t =
  let { Geometry.tile; text; _ } = Ui_state.geometry t ~width ~height in
  printf
    !"%{sexp:Geometry.Prefs.t} %s | tile x=%d w=%d, text w=%d\n"
    (Ui_state.prefs t)
    (match Ui_state.message t with
     | None -> "-"
     | Some { kind = _; text } -> text)
    tile.x
    tile.width
    text.width
;;

let%expect_test "Space v commands: feedback, centering, and clamped requests" =
  let step ?(width = 160) ?(height = 48) t k =
    let t = run ~width ~height t (keys k) in
    printf "%-6S " k;
    layout ~width ~height t;
    t
  in
  let t = ui "abc" in
  let t =
    List.fold [ " vl"; " vL"; " vH"; " vH"; " vh"; " v-"; " v+"; " v="; " vc"; " vc"; " vr" ]
      ~init:t
      ~f:(fun t k -> step t k)
  in
  [%expect {|
    " vl"  ((centered true) (width 100) (offset 2) (line_numbers Hybrid)) Offset +2 | tile x=29 w=106, text w=100
    " vL"  ((centered true) (width 100) (offset 12) (line_numbers Hybrid)) Offset +12 | tile x=39 w=106, text w=100
    " vH"  ((centered true) (width 100) (offset 2) (line_numbers Hybrid)) Offset +2 | tile x=29 w=106, text w=100
    " vH"  ((centered true) (width 100) (offset -8) (line_numbers Hybrid)) Offset -8 | tile x=19 w=106, text w=100
    " vh"  ((centered true) (width 100) (offset -10) (line_numbers Hybrid)) Offset -10 | tile x=17 w=106, text w=100
    " v-"  ((centered true) (width 90) (offset -10) (line_numbers Hybrid)) Width 90 | tile x=22 w=96, text w=90
    " v+"  ((centered true) (width 100) (offset -10) (line_numbers Hybrid)) Width 100 | tile x=17 w=106, text w=100
    " v="  ((centered true) (width 110) (offset -10) (line_numbers Hybrid)) Width 110 | tile x=12 w=116, text w=110
    " vc"  ((centered false) (width 110) (offset -10) (line_numbers Hybrid)) Full width | tile x=0 w=160, text w=154
    " vc"  ((centered true) (width 110) (offset -10) (line_numbers Hybrid)) Centered | tile x=12 w=116, text w=110
    " vr"  ((centered true) (width 100) (offset 0) (line_numbers Hybrid)) Layout reset | tile x=27 w=106, text w=100
    |}];
  (* Nudges and width changes select centered mode, from full width. *)
  let t = step (step t " vc") " vl" in
  let t = step (step t " vc") " v-" in
  [%expect {|
    " vc"  ((centered false) (width 100) (offset 0) (line_numbers Hybrid)) Full width | tile x=0 w=160, text w=154
    " vl"  ((centered true) (width 100) (offset 2) (line_numbers Hybrid)) Offset +2 | tile x=29 w=106, text w=100
    " vc"  ((centered false) (width 100) (offset 2) (line_numbers Hybrid)) Full width | tile x=0 w=160, text w=154
    " v-"  ((centered true) (width 90) (offset 2) (line_numbers Hybrid)) Width 90 | tile x=34 w=96, text w=90
    |}];
  (* Requests are clamped: width to 20..500, offset to -500..500. *)
  let t = List.fold (List.init 20 ~f:(fun _ -> " v-")) ~init:t ~f:(fun t k -> run t (keys k)) in
  layout t;
  let t = List.fold (List.init 60 ~f:(fun _ -> " v+")) ~init:t ~f:(fun t k -> run t (keys k)) in
  layout t;
  let t = List.fold (List.init 60 ~f:(fun _ -> " vL")) ~init:t ~f:(fun t k -> run t (keys k)) in
  layout t;
  let t = List.fold (List.init 120 ~f:(fun _ -> " vH")) ~init:t ~f:(fun t k -> run t (keys k)) in
  layout t;
  [%expect {|
    ((centered true) (width 20) (offset 2) (line_numbers Hybrid)) Width 20 | tile x=69 w=26, text w=20
    ((centered true) (width 500) (offset 2) (line_numbers Hybrid)) Width 500 (34 fit) | tile x=0 w=160, text w=154
    ((centered true) (width 500) (offset 500) (line_numbers Hybrid)) Offset +500 (0 fit) | tile x=0 w=160, text w=154
    ((centered true) (width 500) (offset -500) (line_numbers Hybrid)) Offset -500 (0 fit) | tile x=0 w=160, text w=154
    |}]
;;

let%expect_test "requests that do not fit are kept, and restored on a larger screen" =
  let t = run (ui "abc") (keys " vr") in
  let t =
    List.fold [ " vL"; " vL"; " v+" ] ~init:t ~f:(fun t k ->
      run ~width:80 ~height:24 t (keys k))
  in
  layout ~width:80 ~height:24 t;
  layout ~width:120 ~height:40 t;
  layout ~width:160 ~height:48 t;
  [%expect {|
    ((centered true) (width 110) (offset 20) (line_numbers Hybrid)) Width 110 (74 fit) | tile x=0 w=80, text w=74
    ((centered true) (width 110) (offset 20) (line_numbers Hybrid)) Width 110 (74 fit) | tile x=4 w=116, text w=110
    ((centered true) (width 110) (offset 20) (line_numbers Hybrid)) Width 110 (74 fit) | tile x=42 w=116, text w=110
    |}];
  (* The feedback shows the effective value of the screen it was given. *)
  let t = run ~width:140 ~height:40 t (keys " vl") in
  layout ~width:140 ~height:40 t;
  [%expect {| ((centered true) (width 110) (offset 22) (line_numbers Hybrid)) Offset +22 (+12 fit) | tile x=24 w=116, text w=110 |}]
;;

let%expect_test "layout commands leave the document, cursor, history, and dirty state \
                 alone"
  =
  let t = run (ui "abc\ndef\n") (keys "jlx") in
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  let state (e : Editor.t) =
    [%sexp
      (Text_buffer.to_string (Editor.text e) : string)
      , (Editor.cursor e : int)
      , (Editor.revision e : int)
      , (Editor.is_dirty e : bool)
      , (Editor.mode e : Mode.t)]
  in
  print_s (state editor);
  let t = run t (keys " vc vl vL v- v+ vH vh vr v=") in
  let editor' = Ches_app.Controller.editor (Ui_state.controller t) in
  print_s (state editor');
  print_s [%sexp (phys_equal editor editor' : bool)];
  (* One undo still undoes the [x]; no layout step was recorded. *)
  let t = run t (keys "u") in
  print_s (state (Ches_app.Controller.editor (Ui_state.controller t)));
  [%expect {|
    ( "abc\
     \ndf\
     \n" 5 1 true Normal)
    ( "abc\
     \ndf\
     \n" 5 1 true Normal)
    true
    ( "abc\
     \ndef\
     \n" 5 2 false Normal)
    |}]
;;

let%expect_test "the pending prefix and the cursor across layout changes" =
  let show_after k t =
    let t = run ~width:50 ~height:7 t (keys k) in
    show ~width:50 ~height:7 t;
    t
  in
  let (_ : Ui_state.t) =
    ui "hello\nworld\n"
    |> show_after "jll"
    |> show_after " v"
    |> show_after "-"
    |> show_after " v- v- v- v- v- v-"
    |> show_after " vH"
    |> show_after " vc"
  in
  [%expect {|
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │2   world                                       │|
    │  1                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt                                2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │2   world                                       │|
    │  1                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt                        Space v 2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │2   world                                       │|
    │  1                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt Width 90 (44 fit)              2:3 |
    cursor: 7,2 Block
           ╭─ f.txt ──────────────────────────╮       |
           │  1 hello                         │       |
           │2   world                         │       |
           │  1                               │       |
           │                                  │       |
           ╰──────────────────────────────────╯       |
     NORMAL  f.txt Width 30                       2:3 |
    cursor: 14,2 Block
    ╭─ f.txt ──────────────────────────╮              |
    │  1 hello                         │              |
    │2   world                         │              |
    │  1                               │              |
    │                                  │              |
    ╰──────────────────────────────────╯              |
     NORMAL  f.txt Offset -10 (-7 fit)            2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │2   world                                       │|
    │  1                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt Full width                     2:3 |
    cursor: 7,2 Block
    |}]
;;

let%expect_test "Space v n / N toggle the line-number switches, with feedback" =
  let step ?(width = 160) ?(height = 48) t k =
    let t = run ~width ~height t (keys k) in
    printf "%-6S " k;
    layout ~width ~height t;
    t
  in
  let t = ui "abc" in
  let t =
    List.fold [ " vn"; " vN"; " vn"; " vN"; " vN"; " vn"; " vN"; " vr" ] ~init:t ~f:step
  in
  [%expect {|
    " vn"  ((centered true) (width 100) (offset 0) (line_numbers Relative)) Line numbers: relative | tile x=27 w=106, text w=100
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Off)) Line numbers: off | tile x=29 w=102, text w=100
    " vn"  ((centered true) (width 100) (offset 0) (line_numbers Absolute)) Line numbers: absolute | tile x=27 w=106, text w=100
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Hybrid)) Line numbers: hybrid | tile x=27 w=106, text w=100
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Absolute)) Line numbers: absolute | tile x=27 w=106, text w=100
    " vn"  ((centered true) (width 100) (offset 0) (line_numbers Off)) Line numbers: off | tile x=29 w=102, text w=100
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Relative)) Line numbers: relative | tile x=27 w=106, text w=100
    " vr"  ((centered true) (width 100) (offset 0) (line_numbers Hybrid)) Layout reset | tile x=27 w=106, text w=100
    |}];
  (* On a screen too small for a gutter, the style is kept and the feedback says so. *)
  let t = step ~width:19 ~height:10 t " vn" in
  let t = step ~width:19 ~height:10 t " vn" in
  let t = step ~width:19 ~height:10 t " vN" in
  let (_ : Ui_state.t) = step ~width:19 ~height:10 t " vN" in
  [%expect {|
    " vn"  ((centered true) (width 100) (offset 0) (line_numbers Relative)) Line numbers: relative (no room) | tile x=0 w=19, text w=19
    " vn"  ((centered true) (width 100) (offset 0) (line_numbers Hybrid)) Line numbers: hybrid (no room) | tile x=0 w=19, text w=19
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Absolute)) Line numbers: absolute (no room) | tile x=0 w=19, text w=19
    " vN"  ((centered true) (width 100) (offset 0) (line_numbers Hybrid)) Line numbers: hybrid (no room) | tile x=0 w=19, text w=19
    |}]
;;

let%expect_test "line-number toggles leave the document, cursor, history, and dirty state \
                 alone"
  =
  let t = run (ui "abc\ndef\n") (keys "jlx") in
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  let t = run t (keys " vn vN vn vN vN") in
  let editor' = Ches_app.Controller.editor (Ui_state.controller t) in
  print_s [%sexp (phys_equal editor editor' : bool)];
  (* A count is rejected, with feedback, and the style is unchanged. *)
  let t = run t (keys "3 vn") in
  layout t;
  [%expect {|
    true
    ((centered true) (width 100) (offset 0) (line_numbers Absolute)) Space v n does not take a count | tile x=27 w=106, text w=100
    |}]
;;

(* Scrolling: the first visible line, the cursor's line:column (both one-based), and
   the message when there is one. The viewport has 10 text rows. *)
let scrolled ?(width = 40) ?(height = 13) t k =
  let t = run ~width ~height t (keys k) in
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  printf
    "%-12S top %d, cursor %d:%d%s\n"
    k
    ((Ui_state.scroll t).top + 1)
    (Editor.cursor_line editor + 1)
    (Editor.cursor_column editor + 1)
    (match Ui_state.message t with
     | None -> ""
     | Some { kind = _; text } -> ", " ^ text);
  t
;;

let numbered n = String.concat (List.init n ~f:(fun i -> sprintf "line %d\n" (i + 1)))

let%expect_test "Ctrl-e / Ctrl-y keep the cursor until its line leaves the view" =
  let t = ui (numbered 50) in
  print_s [%sexp ((Ui_state.geometry t ~width:40 ~height:13).text.height : int)];
  let (_ : Ui_state.t) =
    List.fold
      [ "5j"; "<C-e>"; "3<C-e>"; "<C-e>"; "<C-e>"; "<C-y>"; "4<C-y>"; "<C-y>"; "<C-y>" ]
      ~init:t
      ~f:(scrolled ?width:None ?height:None)
  in
  [%expect {|
    10
    "5j"         top 1, cursor 6:1
    "<C-e>"      top 2, cursor 6:1
    "3<C-e>"     top 5, cursor 6:1
    "<C-e>"      top 6, cursor 6:1
    "<C-e>"      top 7, cursor 7:1
    "<C-y>"      top 6, cursor 7:1
    "4<C-y>"     top 2, cursor 7:1
    "<C-y>"      top 1, cursor 7:1
    "<C-y>"      top 1, cursor 7:1
    |}]
;;

let%expect_test "a pushed cursor keeps its preferred column" =
  let text =
    String.concat (List.init 30 ~f:(fun i -> if i % 2 = 0 then "long line here\n" else "ab\n"))
  in
  let (_ : Ui_state.t) =
    List.fold [ "9l"; "<C-e>"; "<C-e>"; "<C-e>"; "j"; "<C-y>"; "11j"; "<C-y>" ] ~init:(ui text) ~f:(scrolled ?width:None ?height:None)
  in
  [%expect {|
    "9l"         top 1, cursor 1:10
    "<C-e>"      top 2, cursor 2:2
    "<C-e>"      top 3, cursor 3:10
    "<C-e>"      top 4, cursor 4:2
    "j"          top 4, cursor 5:10
    "<C-y>"      top 3, cursor 5:10
    "11j"        top 7, cursor 16:2
    "<C-y>"      top 6, cursor 15:10
    |}]
;;

let%expect_test "Ctrl-e / Ctrl-y at both ends, in a short file, and with huge counts" =
  let (_ : Ui_state.t) =
    List.fold
      [ "<C-y>"; "999999<C-e>"; "<C-e>"; "k"; "G"; "999999<C-y>"; "<C-y>" ]
      ~init:(ui (numbered 50))
      ~f:(scrolled ?width:None ?height:None)
  in
  print_endline "short file:";
  let (_ : Ui_state.t) =
    List.fold [ "j"; "<C-e>"; "<C-e>"; "<C-e>"; "<C-y>"; "9<C-y>" ] ~init:(ui (numbered 3))
      ~f:(scrolled ?width:None ?height:None)
  in
  [%expect {|
    "<C-y>"      top 1, cursor 1:1
    "999999<C-e>" top 51, cursor 51:1
    "<C-e>"      top 51, cursor 51:1
    "k"          top 50, cursor 50:1
    "G"          top 50, cursor 51:1
    "999999<C-y>" top 1, cursor 10:1
    "<C-y>"      top 1, cursor 10:1
    short file:
    "j"          top 1, cursor 2:1
    "<C-e>"      top 2, cursor 2:1
    "<C-e>"      top 3, cursor 3:1
    "<C-e>"      top 4, cursor 4:1
    "<C-y>"      top 3, cursor 4:1
    "9<C-y>"     top 1, cursor 4:1
    |}]
;;

let%expect_test "a view past the end stays while the cursor moves inside it; a resize \
                 fills it"
  =
  let t =
    List.fold [ "G"; "5<C-e>"; "k"; "j"; "gg"; "G5<C-e>k" ] ~init:(ui (numbered 50)) ~f:(scrolled ?width:None ?height:None)
  in
  (* One more text row: drawn at once, before any key, with the view filled. *)
  printf "resized: top %d\n" ((Ui_state.fitted_scroll t ~width:40 ~height:14).top + 1);
  let (_ : Ui_state.t) = scrolled ~height:14 t "j" in
  [%expect {|
    "G"          top 42, cursor 51:1
    "5<C-e>"     top 47, cursor 51:1
    "k"          top 47, cursor 50:1
    "j"          top 47, cursor 51:1
    "gg"         top 1, cursor 1:1
    "G5<C-e>k"   top 47, cursor 50:1
    resized: top 41
    "j"          top 41, cursor 51:1
    |}]
;;

let%expect_test "Ctrl-d / Ctrl-u: half the viewport, or a count, for view and cursor" =
  let (_ : Ui_state.t) =
    List.fold
      ([ "2j"; "<C-d>"; "3<C-d>" ]
       @ List.init 8 ~f:(fun _ -> "<C-d>")
       @ [ "<C-u>"; "2<C-u>" ]
       @ List.init 10 ~f:(fun _ -> "<C-u>"))
      ~init:(ui (numbered 50))
      ~f:(scrolled ?width:None ?height:None)
  in
  [%expect {|
    "2j"         top 1, cursor 3:1
    "<C-d>"      top 6, cursor 8:1
    "3<C-d>"     top 9, cursor 11:1
    "<C-d>"      top 14, cursor 16:1
    "<C-d>"      top 19, cursor 21:1
    "<C-d>"      top 24, cursor 26:1
    "<C-d>"      top 29, cursor 31:1
    "<C-d>"      top 34, cursor 36:1
    "<C-d>"      top 39, cursor 41:1
    "<C-d>"      top 42, cursor 46:1
    "<C-d>"      top 42, cursor 51:1
    "<C-u>"      top 37, cursor 46:1
    "2<C-u>"     top 35, cursor 44:1
    "<C-u>"      top 30, cursor 39:1
    "<C-u>"      top 25, cursor 34:1
    "<C-u>"      top 20, cursor 29:1
    "<C-u>"      top 15, cursor 24:1
    "<C-u>"      top 10, cursor 19:1
    "<C-u>"      top 5, cursor 14:1
    "<C-u>"      top 1, cursor 9:1
    "<C-u>"      top 1, cursor 4:1
    "<C-u>"      top 1, cursor 1:1
    "<C-u>"      top 1, cursor 1:1
    |}]
;;

let%expect_test "zz / zt / zb move the view, not the cursor, and take no count" =
  let (_ : Ui_state.t) =
    List.fold
      [ "20G"; "zt"; "zb"; "zz"; "3zz"; "gg"; "zz"; "zb"; "zt"; "G"; "zt"; "zz"; "zb"; "k"
      ]
      ~init:(ui (numbered 50))
      ~f:(scrolled ?width:None ?height:None)
  in
  [%expect {|
    "20G"        top 11, cursor 20:1
    "zt"         top 20, cursor 20:1
    "zb"         top 11, cursor 20:1
    "zz"         top 16, cursor 20:1
    "3zz"        top 16, cursor 20:1, z z does not take a count
    "gg"         top 1, cursor 1:1
    "zz"         top 1, cursor 1:1
    "zb"         top 1, cursor 1:1
    "zt"         top 1, cursor 1:1
    "G"          top 42, cursor 51:1
    "zt"         top 51, cursor 51:1
    "zz"         top 47, cursor 51:1
    "zb"         top 42, cursor 51:1
    "k"          top 42, cursor 50:1
    |}]
;;

let%expect_test "scrolling leaves text, history, and dirty state alone, and needs rows" =
  let t = run (ui (numbered 50)) (keys "x") in
  let t = run t (keys "<C-e><C-e><C-d>zz<C-u><C-y>zt") in
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  print_s
    [%sexp
      (Editor.revision editor : int)
    , (Editor.is_dirty editor : bool)
    , (String.prefix (Text_buffer.to_string (Editor.text editor)) 12 : string)];
  (* One undo undoes the x; there is nothing more. *)
  let t = run t (keys "u") in
  let t = scrolled t "u" in
  (* With no text rows, nothing changes. *)
  let t = scrolled ~height:1 t "<C-e>" in
  let t = scrolled ~height:1 t "<C-d>" in
  let (_ : Ui_state.t) = scrolled ~height:1 t "zt" in
  [%expect {|
    (1 true  "ine 1\
            \nline 2")
    "u"          top 1, cursor 1:1, Already at oldest change
    "<C-e>"      top 1, cursor 1:1, Already at oldest change
    "<C-d>"      top 1, cursor 1:1, Already at oldest change
    "zt"         top 1, cursor 1:1, Already at oldest change
    |}]
;;

let%expect_test "horizontal scroll is kept when the cursor is not pushed" =
  let text = numbered 5 ^ String.make 100 'x' ^ "\n" ^ numbered 30 in
  let t = run (ui text) (keys "5j$") in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  let t = run t (keys "<C-e><C-e><C-y>") in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  [%expect {|
    ((top 1) (left 66))
    ((top 2) (left 66))
    |}]
;;
