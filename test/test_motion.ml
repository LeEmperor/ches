open! Core
open Ches_core

let create s =
  Editor.create
    ~path:"f.txt"
    (Text_buffer.of_string s
     |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
     |> Result.ok_or_failwith)
;;

let move ?count t motion = fst (Editor.dispatch t (Move { motion; count }))

(* The cursor's line, with [|] before the code point under the cursor, prefixed by its
   zero-based line:column. TABs are shown as [\t]. *)
let show_cursor t =
  let text = Editor.text t in
  let line = Editor.cursor_line t in
  let start = Text_buffer.line_start text line in
  let s = Text_buffer.line_text text line in
  let at = Editor.cursor t - start in
  let s = String.prefix s at ^ "|" ^ String.drop_prefix s at in
  printf
    "%d:%d %s\n"
    line
    (Editor.cursor_column t)
    (String.substr_replace_all s ~pattern:"\t" ~with_:"\\t")
;;

(* Applies [motion] from the start of [text] until the cursor stops moving, showing
   each position. *)
let trace ?(from = 0) text motion =
  let t = create text in
  let t =
    if from = 0
    then t
    else move t Motion.Right ~count:from
  in
  show_cursor t;
  let rec loop t n =
    let t' = move t motion in
    if Editor.cursor t' <> Editor.cursor t && n < 50
    then (
      show_cursor t';
      loop t' (n + 1))
  in
  loop t 0
;;

let trace_back text motion =
  let t = move (create text) Motion.Last_line in
  let t = move t Line_end in
  show_cursor t;
  let rec loop t n =
    let t' = move t motion in
    if Editor.cursor t' <> Editor.cursor t && n < 50
    then (
      show_cursor t';
      loop t' (n + 1))
  in
  loop t 0
;;

let%expect_test "w: identifiers, punctuation, underscores, and blanks" =
  trace "foo_bar(x, y) +=  baz.qux" (Word_forward Small);
  [%expect {|
    0:0 |foo_bar(x, y) +=  baz.qux
    0:7 foo_bar|(x, y) +=  baz.qux
    0:8 foo_bar(|x, y) +=  baz.qux
    0:9 foo_bar(x|, y) +=  baz.qux
    0:11 foo_bar(x, |y) +=  baz.qux
    0:12 foo_bar(x, y|) +=  baz.qux
    0:14 foo_bar(x, y) |+=  baz.qux
    0:18 foo_bar(x, y) +=  |baz.qux
    0:21 foo_bar(x, y) +=  baz|.qux
    0:22 foo_bar(x, y) +=  baz.|qux
    0:24 foo_bar(x, y) +=  baz.qu|x
    |}];
  trace "foo_bar(x, y) +=  baz.qux" (Word_forward Big);
  [%expect {|
    0:0 |foo_bar(x, y) +=  baz.qux
    0:11 foo_bar(x, |y) +=  baz.qux
    0:14 foo_bar(x, y) |+=  baz.qux
    0:18 foo_bar(x, y) +=  |baz.qux
    0:24 foo_bar(x, y) +=  baz.qu|x
    |}]
;;

let%expect_test "w across lines, empty lines, TABs, and a trailing LF" =
  trace "ab\n\n\tcd ef\n  \n\ngh\n" (Word_forward Small);
  [%expect {|
    0:0 |ab
    1:0 |
    2:1 \t|cd ef
    2:4 \tcd |ef
    4:0 |
    5:0 |gh
    6:0 |
    |}];
  (* Without a trailing LF, w stops on the last character. *)
  trace "ab cd" (Word_forward Small);
  [%expect {|
    0:0 |ab cd
    0:3 ab |cd
    0:4 ab c|d
    |}];
  trace "ab cd  " (Word_forward Small);
  [%expect {|
    0:0 |ab cd
    0:3 ab |cd
    0:6 ab cd |
    |}]
;;

let%expect_test "b: back to word starts, stopping at empty lines" =
  trace_back "foo_bar(x, y) +=  baz.qux" (Word_backward Small);
  [%expect {|
    0:24 foo_bar(x, y) +=  baz.qu|x
    0:22 foo_bar(x, y) +=  baz.|qux
    0:21 foo_bar(x, y) +=  baz|.qux
    0:18 foo_bar(x, y) +=  |baz.qux
    0:14 foo_bar(x, y) |+=  baz.qux
    0:12 foo_bar(x, y|) +=  baz.qux
    0:11 foo_bar(x, |y) +=  baz.qux
    0:9 foo_bar(x|, y) +=  baz.qux
    0:8 foo_bar(|x, y) +=  baz.qux
    0:7 foo_bar|(x, y) +=  baz.qux
    0:0 |foo_bar(x, y) +=  baz.qux
    |}];
  trace_back "foo_bar(x, y) +=  baz.qux" (Word_backward Big);
  [%expect {|
    0:24 foo_bar(x, y) +=  baz.qu|x
    0:18 foo_bar(x, y) +=  |baz.qux
    0:14 foo_bar(x, y) |+=  baz.qux
    0:11 foo_bar(x, |y) +=  baz.qux
    0:0 |foo_bar(x, y) +=  baz.qux
    |}];
  trace_back "  ab\n\n\tcd ef\n  \n\ngh" (Word_backward Small);
  [%expect {|
    5:1 g|h
    5:0 |gh
    4:0 |
    2:4 \tcd |ef
    2:1 \t|cd ef
    1:0 |
    0:2   |ab
    0:0 |  ab
    |}]
;;

let%expect_test "e: word ends, skipping empty lines" =
  trace "foo_bar(x, y) +=  baz.qux" (Word_end Small);
  [%expect {|
    0:0 |foo_bar(x, y) +=  baz.qux
    0:6 foo_ba|r(x, y) +=  baz.qux
    0:7 foo_bar|(x, y) +=  baz.qux
    0:8 foo_bar(|x, y) +=  baz.qux
    0:9 foo_bar(x|, y) +=  baz.qux
    0:11 foo_bar(x, |y) +=  baz.qux
    0:12 foo_bar(x, y|) +=  baz.qux
    0:15 foo_bar(x, y) +|=  baz.qux
    0:20 foo_bar(x, y) +=  ba|z.qux
    0:21 foo_bar(x, y) +=  baz|.qux
    0:24 foo_bar(x, y) +=  baz.qu|x
    |}];
  trace "foo_bar(x, y) +=  baz.qux" (Word_end Big);
  [%expect {|
    0:0 |foo_bar(x, y) +=  baz.qux
    0:9 foo_bar(x|, y) +=  baz.qux
    0:12 foo_bar(x, y|) +=  baz.qux
    0:15 foo_bar(x, y) +|=  baz.qux
    0:24 foo_bar(x, y) +=  baz.qu|x
    |}];
  trace "a\n\n  bc\n\nd e  \n" (Word_end Small);
  [%expect {|
    0:0 |a
    2:3   b|c
    4:0 |d e
    4:2 d |e
    |}]
;;

let%expect_test "multibyte text is identifier characters" =
  let text = "héllo, 日本語!🐹x é" in
  trace text (Word_forward Small);
  [%expect {|
    0:0 |héllo, 日本語!🐹x é
    0:5 héllo|, 日本語!🐹x é
    0:7 héllo, |日本語!🐹x é
    0:10 héllo, 日本語|!🐹x é
    0:11 héllo, 日本語!|🐹x é
    0:14 héllo, 日本語!🐹x |é
    |}];
  trace text (Word_end Small);
  [%expect {|
    0:0 |héllo, 日本語!🐹x é
    0:4 héll|o, 日本語!🐹x é
    0:5 héllo|, 日本語!🐹x é
    0:9 héllo, 日本|語!🐹x é
    0:10 héllo, 日本語|!🐹x é
    0:12 héllo, 日本語!🐹|x é
    0:14 héllo, 日本語!🐹x |é
    |}];
  trace_back text (Word_backward Small);
  [%expect {|
    0:14 héllo, 日本語!🐹x |é
    0:11 héllo, 日本語!|🐹x é
    0:10 héllo, 日本語|!🐹x é
    0:7 héllo, |日本語!🐹x é
    0:5 héllo|, 日本語!🐹x é
    0:0 |héllo, 日本語!🐹x é
    |}]
;;

let%expect_test "word motions on empty and blank documents" =
  List.iter [ ""; "\n"; "   "; "\n\n" ] ~f:(fun text ->
    List.iter
      [ Motion.Word_forward Small; Word_backward Small; Word_end Small ]
      ~f:(fun motion ->
        let t = create text in
        let t = move (move t motion) motion in
        printf "%S %s -> " text (Sexp.to_string [%sexp (motion : Motion.t)]);
        show_cursor t));
  [%expect {|
    "" (Word_forward Small) -> 0:0 |
    "" (Word_backward Small) -> 0:0 |
    "" (Word_end Small) -> 0:0 |
    "\n" (Word_forward Small) -> 1:0 |
    "\n" (Word_backward Small) -> 0:0 |
    "\n" (Word_end Small) -> 0:0 |
    "   " (Word_forward Small) -> 0:2   |
    "   " (Word_backward Small) -> 0:0 |
    "   " (Word_end Small) -> 0:0 |
    "\n\n" (Word_forward Small) -> 2:0 |
    "\n\n" (Word_backward Small) -> 0:0 |
    "\n\n" (Word_end Small) -> 0:0 |
    |}]
;;

let%expect_test "counted word motions" =
  let text = "a b c d e\nf g" in
  let t = create text in
  show_cursor (move t (Word_forward Small) ~count:3);
  show_cursor (move t (Word_forward Small) ~count:6);
  show_cursor (move t (Word_forward Small) ~count:999_999);
  show_cursor (move t (Word_end Small) ~count:2);
  show_cursor (move t (Word_end Small) ~count:999_999);
  let t = move t Last_line in
  show_cursor (move t (Word_backward Small) ~count:2);
  show_cursor (move t (Word_backward Small) ~count:999_999);
  [%expect {|
    0:6 a b c |d e
    1:2 f |g
    1:2 f |g
    0:4 a b |c d e
    1:2 f |g
    0:6 a b c |d e
    0:0 |a b c d e
    |}]
;;

let%expect_test "0, ^, and $" =
  let t = move (create "  \tab cd\nxy\n   \n") Right ~count:5 in
  show_cursor t;
  show_cursor (move t Line_start);
  show_cursor (move t First_nonblank);
  show_cursor (move t Line_end);
  show_cursor (move t Line_end ~count:2);
  show_cursor (move t Line_end ~count:999_999);
  (* A blank line's first non-blank is its last character in Normal mode. *)
  show_cursor (move (move t Down ~count:2) First_nonblank);
  [%expect {|
    0:5   \tab| cd
    0:0 |  \tab cd
    0:3   \t|ab cd
    0:7   \tab c|d
    1:1 x|y
    3:0 |
    2:2   |
    |}];
  (* In Insert mode, $ goes past the last character. *)
  let t = fst (Editor.dispatch (create "abc") (Enter_insert Before_cursor)) in
  show_cursor (move t Line_end);
  [%expect {| 0:3 abc| |}]
;;

let%expect_test "_ and g_" =
  let t = move (create "  \tab cd \t\n  xy日  \n   \n\nz") Right ~count:4 in
  show_cursor t;
  show_cursor (move t First_nonblank_down);
  show_cursor (move t Last_nonblank);
  show_cursor (move t First_nonblank_down ~count:2);
  show_cursor (move t Last_nonblank ~count:2);
  (* A blank line: _ goes to its last character (like ^), g_ to its start. *)
  show_cursor (move t First_nonblank_down ~count:3);
  show_cursor (move t Last_nonblank ~count:3);
  show_cursor (move t Last_nonblank ~count:4);
  show_cursor (move t First_nonblank_down ~count:999_999);
  show_cursor (move t Last_nonblank ~count:999_999);
  [%expect
    {|
    0:4   \ta|b cd \t
    0:3   \t|ab cd \t
    0:7   \tab c|d \t
    1:2   |xy日
    1:4   xy|日
    2:2   |
    2:0 |
    3:0 |
    4:0 |z
    4:0 |z
    |}];
  (* In Insert mode, g_ stays on the last non-blank rather than after it. *)
  let t = fst (Editor.dispatch (create "abc  ") (Enter_insert Before_cursor)) in
  show_cursor (move t Last_nonblank);
  [%expect {| 0:2 ab|c |}]
;;

let%expect_test "gg and G, with and without counts" =
  let text = "one\n  two\n\tthree\nfour" in
  let t = create text in
  show_cursor (move t Last_line);
  show_cursor (move t Last_line ~count:1);
  show_cursor (move t Last_line ~count:2);
  show_cursor (move t Last_line ~count:999_999);
  let t = move t Last_line in
  show_cursor (move t First_line);
  show_cursor (move t First_line ~count:3);
  show_cursor (move t First_line ~count:999_999);
  [%expect {|
    3:0 |four
    0:0 |one
    1:2   |two
    3:0 |four
    0:0 |one
    2:1 \t|three
    3:0 |four
    |}];
  (* With a trailing LF, the last line is the empty one after it. *)
  show_cursor (move (create "ab\n  cd\n") Last_line);
  [%expect {| 2:0 | |}]
;;

let%expect_test "motion kinds and counts" =
  List.iter Motion.all ~f:(fun motion ->
    print_s
      [%sexp
        (motion : Motion.t)
        , (Motion.kind motion : Motion.Kind.t)
        , ("takes_count", (Motion.takes_count motion : bool))]);
  [%expect {|
    (Left (Characterwise (inclusive false)) (takes_count true))
    (Right (Characterwise (inclusive false)) (takes_count true))
    (Up Linewise (takes_count true))
    (Down Linewise (takes_count true))
    ((Word_forward Small) (Characterwise (inclusive false)) (takes_count true))
    ((Word_forward Big) (Characterwise (inclusive false)) (takes_count true))
    ((Word_backward Small) (Characterwise (inclusive false)) (takes_count true))
    ((Word_backward Big) (Characterwise (inclusive false)) (takes_count true))
    ((Word_end Small) (Characterwise (inclusive true)) (takes_count true))
    ((Word_end Big) (Characterwise (inclusive true)) (takes_count true))
    (Line_start (Characterwise (inclusive false)) (takes_count false))
    (First_nonblank (Characterwise (inclusive false)) (takes_count false))
    (First_nonblank_down Linewise (takes_count true))
    (Line_end (Characterwise (inclusive true)) (takes_count true))
    (Last_nonblank (Characterwise (inclusive true)) (takes_count true))
    (First_line Linewise (takes_count true))
    (Last_line Linewise (takes_count true))
    |}];
  Expect_test_helpers_core.require_does_raise (fun () ->
    move (create "ab") First_nonblank ~count:1);
  [%expect {| (Invalid_argument "First_nonblank takes no count") |}]
;;

let%expect_test "word and line motions reset the preferred column" =
  let t = move (create "ab cdef\nx\nabcdefgh") (Word_forward Small) in
  show_cursor t;
  let t = move t Down in
  show_cursor t;
  show_cursor (move t Down);
  (* Unlike Vim, $ sets the preferred column to the last character's column; the cursor
     does not then stick to line ends. *)
  let t = move (move t Up) Line_end in
  show_cursor t;
  show_cursor (move t Down ~count:2);
  [%expect {|
    0:3 ab |cdef
    1:0 |x
    2:3 abc|defgh
    0:6 ab cde|f
    2:6 abcdef|gh
    |}]
;;

let%test_unit "motions change no text, revision, dirty state, or history" =
  Quickcheck.test
    Quickcheck.Generator.(
      tuple3
        (list (of_list [ "a"; "_"; " "; "\t"; "\n"; "."; "日"; "🐹" ])
         |> map ~f:String.concat)
        (list (tuple2 (of_list Motion.all) (Option.quickcheck_generator (Int.gen_incl 1 5))))
        bool)
    ~sexp_of:[%sexp_of: string * (Motion.t * int option) list * bool]
    ~f:(fun (text, moves, edited) ->
      (* Start from a dirty document with one undo step. *)
      let t = create text in
      let t =
        if edited
        then
          List.fold
            [ Command.Enter_insert Before_cursor; Insert_text "x"; Exit_insert ]
            ~init:t
            ~f:(fun t command -> fst (Editor.dispatch t command))
        else t
      in
      let t' =
        List.fold moves ~init:t ~f:(fun t (motion, count) ->
          let count = if Motion.takes_count motion then count else None in
          let t' = move t motion ?count in
          let text = Editor.text t' in
          let cursor = Editor.cursor t' in
          let line = Text_buffer.line_of_offset text cursor in
          assert (Text_buffer.is_boundary text cursor);
          assert (
            cursor < Text_buffer.line_end text line
            || cursor = Text_buffer.line_start text line);
          t')
      in
      assert (Text_buffer.equal (Editor.text t) (Editor.text t'));
      [%test_result: int] (Editor.revision t') ~expect:(Editor.revision t);
      [%test_result: bool] (Editor.is_dirty t') ~expect:(Editor.is_dirty t);
      let undone, _ = Editor.dispatch t' Undo in
      [%test_result: string]
        (Text_buffer.to_string (Editor.text undone))
        ~expect:text)
;;
