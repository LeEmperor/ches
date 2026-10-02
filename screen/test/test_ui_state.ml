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
      1 abc                                           |
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
    " vl"  ((centered true) (width 100) (offset 2)) Offset +2 | tile x=29 w=106, text w=100
    " vL"  ((centered true) (width 100) (offset 12)) Offset +12 | tile x=39 w=106, text w=100
    " vH"  ((centered true) (width 100) (offset 2)) Offset +2 | tile x=29 w=106, text w=100
    " vH"  ((centered true) (width 100) (offset -8)) Offset -8 | tile x=19 w=106, text w=100
    " vh"  ((centered true) (width 100) (offset -10)) Offset -10 | tile x=17 w=106, text w=100
    " v-"  ((centered true) (width 90) (offset -10)) Width 90 | tile x=22 w=96, text w=90
    " v+"  ((centered true) (width 100) (offset -10)) Width 100 | tile x=17 w=106, text w=100
    " v="  ((centered true) (width 110) (offset -10)) Width 110 | tile x=12 w=116, text w=110
    " vc"  ((centered false) (width 110) (offset -10)) Full width | tile x=0 w=160, text w=154
    " vc"  ((centered true) (width 110) (offset -10)) Centered | tile x=12 w=116, text w=110
    " vr"  ((centered true) (width 100) (offset 0)) Layout reset | tile x=27 w=106, text w=100
    |}];
  (* Nudges and width changes select centered mode, from full width. *)
  let t = step (step t " vc") " vl" in
  let t = step (step t " vc") " v-" in
  [%expect {|
    " vc"  ((centered false) (width 100) (offset 0)) Full width | tile x=0 w=160, text w=154
    " vl"  ((centered true) (width 100) (offset 2)) Offset +2 | tile x=29 w=106, text w=100
    " vc"  ((centered false) (width 100) (offset 2)) Full width | tile x=0 w=160, text w=154
    " v-"  ((centered true) (width 90) (offset 2)) Width 90 | tile x=34 w=96, text w=90
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
    ((centered true) (width 20) (offset 2)) Width 20 | tile x=69 w=26, text w=20
    ((centered true) (width 500) (offset 2)) Width 500 (34 fit) | tile x=0 w=160, text w=154
    ((centered true) (width 500) (offset 500)) Offset +500 (0 fit) | tile x=0 w=160, text w=154
    ((centered true) (width 500) (offset -500)) Offset -500 (0 fit) | tile x=0 w=160, text w=154
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
    ((centered true) (width 110) (offset 20)) Width 110 (74 fit) | tile x=0 w=80, text w=74
    ((centered true) (width 110) (offset 20)) Width 110 (74 fit) | tile x=4 w=116, text w=110
    ((centered true) (width 110) (offset 20)) Width 110 (74 fit) | tile x=42 w=116, text w=110
    |}];
  (* The feedback shows the effective value of the screen it was given. *)
  let t = run ~width:140 ~height:40 t (keys " vl") in
  layout ~width:140 ~height:40 t;
  [%expect {| ((centered true) (width 110) (offset 22)) Offset +22 (+12 fit) | tile x=24 w=116, text w=110 |}]
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
    │  2 world                                       │|
    │  3                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt                                2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │  2 world                                       │|
    │  3                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt                        Space v 2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │  2 world                                       │|
    │  3                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt Width 90 (44 fit)              2:3 |
    cursor: 7,2 Block
           ╭─ f.txt ──────────────────────────╮       |
           │  1 hello                         │       |
           │  2 world                         │       |
           │  3                               │       |
           │                                  │       |
           ╰──────────────────────────────────╯       |
     NORMAL  f.txt Width 30                       2:3 |
    cursor: 14,2 Block
    ╭─ f.txt ──────────────────────────╮              |
    │  1 hello                         │              |
    │  2 world                         │              |
    │  3                               │              |
    │                                  │              |
    ╰──────────────────────────────────╯              |
     NORMAL  f.txt Offset -10 (-7 fit)            2:3 |
    cursor: 7,2 Block
    ╭─ f.txt ────────────────────────────────────────╮|
    │  1 hello                                       │|
    │  2 world                                       │|
    │  3                                             │|
    │                                                │|
    ╰────────────────────────────────────────────────╯|
     NORMAL  f.txt Full width                     2:3 |
    cursor: 7,2 Block
    |}]
;;
