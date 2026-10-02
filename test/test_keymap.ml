open! Core
open Ches_core
open Ches_input

let keys = Key_notation.keys

type session =
  { editor : Editor.t
  ; keymap : Keymap.t
  }

let create ?(config = Keymap.Config.default) ?(path = "f.txt") s =
  let text =
    Text_buffer.of_string s
    |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith
  in
  { editor = Editor.create ~path text; keymap = Keymap.create config }
;;

(* Feed [inputs] through the keymap and the editor, as a frontend would, printing the
   actions produced and the effects requested. *)
let run session inputs =
  List.fold inputs ~init:session ~f:(fun session input ->
    let keymap, actions =
      Keymap.feed session.keymap ~mode:(Editor.mode session.editor) input
    in
    let editor =
      List.fold actions ~init:session.editor ~f:(fun editor action ->
        print_endline (Sexp.to_string [%sexp (action : Keymap.Action.t)]);
        match action with
        | View _ -> editor
        | Editor command ->
          let editor, effects = Editor.dispatch editor command in
          List.iter effects ~f:(fun effect -> print_s [%sexp (effect : Effect.t)]);
          editor)
    in
    { editor; keymap })
;;

(* Mode, zero-based line:column, dirty flag, pending keys, keymap notice and editor
   message; then the text with [|] at the cursor. *)
let show { editor; keymap } =
  let text = Text_buffer.to_string (Editor.text editor) in
  let cursor = Editor.cursor editor in
  printf
    "%s %d:%d%s%s%s%s\n"
    (Mode.to_string (Editor.mode editor))
    (Editor.cursor_line editor)
    (Editor.cursor_column editor)
    (if Editor.is_dirty editor then " dirty" else "")
    (match Keymap.pending keymap with
     | None -> ""
     | Some pending -> sprintf " pending=%S" pending)
    (match Keymap.notice keymap with
     | None -> ""
     | Some notice -> sprintf " notice=%S" notice)
    (match Editor.message editor with
     | None -> ""
     | Some message -> " " ^ Sexp.to_string [%sexp (message : Editor.Message.t)]);
  String.prefix text cursor ^ "|" ^ String.drop_prefix text cursor
  |> String.split ~on:'\n'
  |> List.iter ~f:(fun line -> print_endline ("> " ^ line))
;;

let%expect_test "Space w saves; the leader is shown while pending" =
  let t = run (create "abc") (keys " ") in
  show t;
  [%expect
    {|
    NORMAL 0:0 pending="Space"
    > |abc
    |}];
  let t = run t (keys "w") in
  show t;
  [%expect
    {|
    Save
    (Write_file (path f.txt) (text abc) (revision 0))
    NORMAL 0:0
    > |abc
    |}]
;;

let%expect_test "Space q exits a clean document and refuses a dirty one" =
  let _ = run (create "abc") (keys " q") in
  [%expect {|
    Quit
    Exit
    |}];
  let t = run (create "abc") (keys "x q") in
  show t;
  [%expect
    {|
    Delete_char
    Quit
    NORMAL 0:0 dirty (Error"Unsaved changes: save them or force quit")
    > |bc
    |}]
;;

let%expect_test "Space Q exits even with unsaved changes" =
  let _ = run (create "abc") (keys "x Q") in
  [%expect {|
    Delete_char
    Force_quit
    Exit
    |}]
;;

let%expect_test "Escape cancels a pending leader silently" =
  let t = run (create "abc") (keys " <Esc>") in
  show t;
  [%expect
    {|
    NORMAL 0:0
    > |abc
    |}];
  (* Nothing leaks: [w] is no longer a continuation, and [x] acts normally. *)
  let t = run t (keys "wx") in
  show t;
  [%expect
    {|
    Delete_char
    NORMAL 0:0 dirty
    > |bc
    |}]
;;

let%expect_test "an unknown continuation cancels the sequence without editing" =
  let t = run (create "abc") (keys " x") in
  show t;
  [%expect
    {|
    NORMAL 0:0 notice="Space x is not bound"
    > |abc
    |}];
  let t = run t (keys "  ") in
  show t;
  [%expect
    {|
    NORMAL 0:0 notice="Space Space is not bound"
    > |abc
    |}];
  (* A continuation that is bound on its own, like [i], is still consumed without
     effect; the notice clears on the next key. *)
  let t = run t (keys " il") in
  show t;
  [%expect
    {|
    (Move Right)
    NORMAL 0:1
    > a|bc
    |}]
;;

let%expect_test "repeated sequences leave no pending state behind" =
  let t = run (create "abc") (keys " w wx w") in
  show t;
  [%expect
    {|
    Save
    (Write_file (path f.txt) (text abc) (revision 0))
    Save
    (Write_file (path f.txt) (text abc) (revision 0))
    Delete_char
    Save
    (Write_file (path f.txt) (text bc) (revision 1))
    NORMAL 0:0 dirty
    > |bc
    |}]
;;

let%expect_test "unbound Normal-mode keys and a lone Escape do nothing" =
  let t = run (create "abc") (keys "z<Esc><CR><BS><Del><Tab>Q<C-r>") in
  show t;
  [%expect
    {|
    Redo
    NORMAL 0:0 (Info"Already at newest change")
    > |abc
    |}]
;;

let%expect_test "h/j/k/l move, i and Escape change mode" =
  let t = run (create "abc\ndef") (keys "ljl") in
  show t;
  [%expect
    {|
    (Move Right)
    (Move Down)
    (Move Right)
    NORMAL 1:2
    > abc
    > de|f
    |}];
  let t = run t (keys "khi") in
  show t;
  [%expect
    {|
    (Move Up)
    (Move Left)
    Enter_insert
    INSERT 0:1
    > a|bc
    > def
    |}];
  let t = run t (keys "<Esc>") in
  show t;
  [%expect
    {|
    Exit_insert
    NORMAL 0:0
    > |abc
    > def
    |}]
;;

let%expect_test "Insert mode inserts Space and Normal-mode keys literally" =
  let t = run (create "") (keys "i w q<C-r>é<Tab>x<CR>y") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text" ")
    (Insert_text w)
    (Insert_text" ")
    (Insert_text q)
    (Insert_text"\195\169")
    (Insert_soft_tab 2)
    (Insert_text x)
    (Insert_text"\n")
    (Insert_text y)
    INSERT 1:1 dirty
    >  w qé x
    > y|
    |}];
  let t = run t (keys "<BS><BS><Esc>") in
  show t;
  [%expect
    {|
    (Delete_soft_tab_backward 2)
    (Delete_soft_tab_backward 2)
    Exit_insert
    NORMAL 0:6 dirty
    >  w qé |x
    |}];
  let t = run t (keys "hhi<Del><Esc>") in
  show t;
  [%expect
    {|
    (Move Left)
    (Move Left)
    Enter_insert
    Delete_forward
    Exit_insert
    NORMAL 0:3 dirty
    >  w |q x
    |}]
;;

let%expect_test "u undoes and Ctrl-r redoes" =
  let t = run (create "abc") (keys "xx") in
  let t = run t (keys "u") in
  show t;
  [%expect
    {|
    Delete_char
    Delete_char
    Undo
    NORMAL 0:0 dirty
    > |bc
    |}];
  let t = run t (keys "uu") in
  show t;
  [%expect
    {|
    Undo
    Undo
    NORMAL 0:0 (Info"Already at oldest change")
    > |abc
    |}];
  let t = run t (keys "<C-r><C-r>") in
  show t;
  [%expect
    {|
    Redo
    Redo
    NORMAL 0:0 dirty
    > |c
    |}]
;;

let%expect_test "Insert-mode paste is one literal insertion" =
  let t = run (create "ab") (keys "li") in
  let t = run t [ Paste " w\n<Esc>u\tQ" ] in
  show t;
  [%expect
    {|
    (Move Right)
    Enter_insert
    (Insert_text" w\n<Esc>u\tQ")
    INSERT 1:8 dirty
    > a w
    > <Esc>u	Q|b
    |}];
  (* The paste and the surrounding typing are one undo step. *)
  let t = run t (keys "!<Esc>u") in
  show t;
  [%expect
    {|
    (Insert_text !)
    Exit_insert
    Undo
    NORMAL 0:1
    > a|b
    |}]
;;

let%expect_test "a paste of invalid text is rejected by the editor" =
  let t = run (create "ab") (keys "i") in
  let t = run t [ Paste "x\r\ny" ] in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text"x\r\ny")
    INSERT 0:0 (Error"Rejected text: CRLF line ending (only LF line endings are supported) at byte offset 1")
    > |ab
    |}];
  (* An empty paste dispatches nothing, so the editor's message is unchanged. *)
  let t = run t [ Paste "" ] in
  show t;
  [%expect
    {|
    INSERT 0:0 (Error"Rejected text: CRLF line ending (only LF line endings are supported) at byte offset 1")
    > |ab
    |}]
;;

let%expect_test "Normal-mode paste is ignored and cancels a pending leader" =
  let t = run (create "ab") (keys " ") in
  let t = run t [ Paste "w x i" ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 notice="Paste ignored in Normal mode"
    > |ab
    |}];
  let t = run t (keys "w") in
  show t;
  [%expect
    {|
    NORMAL 0:0
    > |ab
    |}]
;;

let%expect_test "Ctrl-c runs nothing, cancels sequences, and hints at Space q" =
  let t = run (create "ab") (keys " <C-c>") in
  show t;
  [%expect
    {|
    NORMAL 0:0 notice="To quit, use Space q in Normal mode"
    > |ab
    |}];
  (* The cancelled leader does not combine with what follows. *)
  let t = run t (keys "q") in
  show t;
  [%expect
    {|
    NORMAL 0:0
    > |ab
    |}];
  (* In Insert mode it inserts nothing and ends a [j k] sequence. *)
  let t = run t (keys "ij<C-c>k") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    (Insert_text k)
    INSERT 0:2 dirty
    > jk|ab
    |}]
;;

let%expect_test "type, leave Insert, undo, redo, and save" =
  let t = run (create ~path:"notes.txt" "") (keys "ihello world<Esc>u<C-r> w") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text h)
    (Insert_text e)
    (Insert_text l)
    (Insert_text l)
    (Insert_text o)
    (Insert_text" ")
    (Insert_text w)
    (Insert_text o)
    (Insert_text r)
    (Insert_text l)
    (Insert_text d)
    Exit_insert
    Undo
    Redo
    Save
    (Write_file (path notes.txt) (text "hello world") (revision 13))
    NORMAL 0:10 dirty
    > hello worl|d
    |}]
;;

let%expect_test "Key.to_string_hum and Key.text" =
  List.iter
    Key.
      [ char 'x'
      ; char ' '
      ; char 'Q'
      ; Char (Uchar.of_scalar_exn 0xe9)
      ; Char (Uchar.of_scalar_exn 0x1b)
      ; Ctrl 'r'
      ; Enter
      ; Tab
      ; Backspace
      ; Delete
      ; Escape
      ]
    ~f:(fun key ->
      print_s [%sexp (Key.to_string_hum key : string), (Key.text key : string option)]);
  [%expect
    {|
    (x (x))
    (Space (" "))
    (Q (Q))
    ("\195\169" ("\195\169"))
    (U+001B ())
    (Ctrl-r ())
    (Enter ("\n"))
    (Tab ("\t"))
    (Backspace ())
    (Delete ())
    (Escape ())
    |}]
;;

let%expect_test "Tab inserts spaces or a TAB, as configured" =
  let tab_with tab =
    let t =
      run (create ~config:{ Keymap.Config.default with tab } "x") (keys "i<Tab><Esc>")
    in
    show t
  in
  tab_with (Spaces 4);
  [%expect
    {|
    Enter_insert
    (Insert_soft_tab 4)
    Exit_insert
    NORMAL 0:3 dirty
    >    | x
    |}];
  tab_with Literal_tab;
  [%expect
    {|
    Enter_insert
    (Insert_text"\t")
    Exit_insert
    NORMAL 0:0 dirty
    > |	x
    |}];
  Expect_test_helpers_core.require_does_raise (fun () ->
    Keymap.create { Keymap.Config.default with tab = Spaces 0 });
  [%expect {| "Keymap.create: [Spaces n] needs n >= 1" |}]
;;

let%expect_test "j k leaves Insert mode without leaving the j behind" =
  let t = run (create "") (keys "iabjk") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text a)
    (Insert_text b)
    (Insert_text j)
    Delete_backward
    Exit_insert
    NORMAL 0:1 dirty
    > a|b
    |}];
  (* The whole typing session, j and all, is one undo step. *)
  let t = run t (keys "u") in
  show t;
  [%expect
    {|
    Undo
    NORMAL 0:0
    > |
    |}];
  (* In Normal mode, j and k are movement again. *)
  let t = run (create "ab\ncd") (keys "jlk") in
  show t;
  [%expect
    {|
    (Move Down)
    (Move Right)
    (Move Up)
    NORMAL 0:1
    > a|b
    > cd
    |}]
;;

let%expect_test "j k only escapes when typed in a row" =
  (* [jjk] keeps the first j. *)
  let t = run (create "") (keys "ijjk") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    (Insert_text j)
    Delete_backward
    Exit_insert
    NORMAL 0:0 dirty
    > |j
    |}];
  (* Anything in between, including Backspace or a paste, ends the sequence. *)
  let t = run (create "") (keys "ijxk<BS><BS>j<BS>k") in
  let t = run t (keys "j") in
  let t = run t [ Paste "-" ] in
  let t = run t (keys "k") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    (Insert_text x)
    (Insert_text k)
    (Delete_soft_tab_backward 2)
    (Delete_soft_tab_backward 2)
    (Insert_text j)
    (Delete_soft_tab_backward 2)
    (Insert_text k)
    (Insert_text j)
    (Insert_text -)
    (Insert_text k)
    INSERT 0:5 dirty
    > jkj-k|
    |}];
  (* A j left at the end still exits with Escape. *)
  let t = run (create "") (keys "ij<Esc>") in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    Exit_insert
    NORMAL 0:0 dirty
    > |j
    |}]
;;

let%expect_test "the Insert-mode escape sequence can be changed or disabled" =
  let t =
    run
      (create ~config:{ Keymap.Config.default with insert_escape = None } "")
      (keys "ijk")
  in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    (Insert_text k)
    INSERT 0:2 dirty
    > jk|
    |}];
  let t =
    run
      (create ~config:{ Keymap.Config.default with insert_escape = Some ('k', 'j') } "")
      (keys "ijkj")
  in
  show t;
  [%expect
    {|
    Enter_insert
    (Insert_text j)
    (Insert_text k)
    Delete_backward
    Exit_insert
    NORMAL 0:0 dirty
    > |j
    |}]
;;

let%expect_test "Backspace deletes a whole soft tab" =
  let t = run (create "") (keys "i<Tab><Tab><BS>x<BS><BS>") in
  show t;
  [%expect {|
    Enter_insert
    (Insert_soft_tab 2)
    (Insert_soft_tab 2)
    (Delete_soft_tab_backward 2)
    (Insert_text x)
    (Delete_soft_tab_backward 2)
    (Delete_soft_tab_backward 2)
    INSERT 0:0
    > |
    |}]
;;

let%expect_test "Space v layout bindings produce view actions, shown tagged" =
  let t = run (create "abc") (keys " v") in
  show t;
  [%expect {|
    NORMAL 0:0 pending="Space v"
    > |abc
    |}];
  let t = run t (keys "c v  vh vl vH vL v- v+ v= vr") in
  show t;
  [%expect {|
    (View Toggle_centered)
    (View(Shift -2))
    (View(Shift 2))
    (View(Shift -10))
    (View(Shift 10))
    (View(Adjust_width -10))
    (View(Adjust_width 10))
    (View(Adjust_width 10))
    (View Reset)
    NORMAL 0:0
    > |abc
    |}];
  (* View actions touch nothing in the editor. *)
  let t = run (create "abc") (keys "x vl vcu") in
  show t;
  [%expect {|
    Delete_char
    (View(Shift 2))
    (View Toggle_centered)
    Undo
    NORMAL 0:0
    > |abc
    |}]
;;

let%expect_test "Space v: Escape cancels, unknown continuations give a notice" =
  let t = run (create "abc") (keys " v<Esc>") in
  show t;
  [%expect {|
    NORMAL 0:0
    > |abc
    |}];
  let t = run t (keys " vz") in
  show t;
  [%expect {|
    NORMAL 0:0 notice="Space v z is not bound"
    > |abc
    |}];
  (* Nothing leaks: [l] after a cancelled prefix moves. *)
  let t = run t (keys " vvl") in
  show t;
  [%expect {|
    (Move Right)
    NORMAL 0:1
    > a|bc
    |}]
;;

let%expect_test "Insert mode types Space v sequences literally" =
  let t = run (create "") (keys "i vc vL v=<Esc>") in
  show t;
  [%expect {|
    Enter_insert
    (Insert_text" ")
    (Insert_text v)
    (Insert_text c)
    (Insert_text" ")
    (Insert_text v)
    (Insert_text L)
    (Insert_text" ")
    (Insert_text v)
    (Insert_text =)
    Exit_insert
    NORMAL 0:8 dirty
    >  vc vL v|=
    |}]
;;
