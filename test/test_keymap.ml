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
  { editor = Editor.create ~path ~cell_width:Cell_width.f text; keymap = Keymap.create config }
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

let%expect_test "Visual bindings select, cancel, and apply a selection" =
  let t = run (create "abc") (keys "vld") in
  show t;
  let t = run (create "abc") (keys "vl<Esc>") in
  show t;
  [%expect {|
    (Enter_visual Characterwise)
    (Move(motion Right))
    Visual_delete
    NORMAL 0:0 dirty
    > |c
    (Enter_visual Characterwise)
    (Move(motion Right))
    Exit_visual
    NORMAL 0:1
    > a|bc
    |}]
;;

let%expect_test "Ctrl-v selects a block; counts extend it; v, V and Ctrl-v switch kinds" =
  let t = run (create "abcd\nefgh\nijkl") (keys "l<C-v>2jl") in
  show t;
  print_s [%sexp (Editor.block t.editor : Block.t option)];
  [%expect {|
    (Move(motion Right))
    (Enter_visual Blockwise)
    (Move(motion Down)(count 2))
    (Move(motion Right))
    VISUAL BLOCK 2:2
    > abcd
    > efgh
    > ij|kl
    (((first_line 0) (last_line 2) (left 1) (right (3))))
    |}];
  let t = run t (keys "vV<C-v>") in
  show t;
  print_s [%sexp (Editor.selection t.editor : Editor.Selection.t option)];
  [%expect {|
    (Enter_visual Characterwise)
    (Enter_visual Linewise)
    (Enter_visual Blockwise)
    VISUAL BLOCK 2:2
    > abcd
    > efgh
    > ij|kl
    (((anchor 1) (active 12) (kind Blockwise)))
    |}];
  (* A count before Ctrl-v is rejected; Escape leaves the cursor where it is. *)
  let t = run t (keys "<Esc>3<C-v>") in
  show t;
  [%expect {|
    Exit_visual
    NORMAL 2:2 notice="Ctrl-v does not take a count"
    > abcd
    > efgh
    > ij|kl
    |}]
;;

let%expect_test "delete grammar composes motions, counts, doubled lines, and cancellation" =
  let t = run (create "one two three\nfour\nfive") (keys "dwe") in
  show t;
  [%expect {|
    (Delete_motion(motion(Word_forward Small)))
    (Move(motion(Word_end Small)))
    NORMAL 0:2 dirty
    > tw|o three
    > four
    > five
    |}];
  let t = run (create "a b c d") (keys "2d3w") in
  show t;
  [%expect {|
    (Delete_motion(motion(Word_forward Small))(count 6))
    NORMAL 0:0 dirty
    > |
    |}];
  let t = run (create "a\nb\nc") (keys "2dd") in
  show t;
  [%expect {|
    (Delete_lines 2)
    NORMAL 0:0 dirty
    > |c
    |}];
  let t = run (create "abc") (keys "d<Esc>x") in
  show t;
  [%expect {|
    (Delete_chars_forward 1)
    NORMAL 0:0 dirty
    > |bc
    |}]
;;

let%expect_test "yank grammar composes motions and counts; paste repeats once" =
  let t = run (create "a\nb\nc\nd") (keys "2yyP") in
  show t;
  let t = run (create "one two") (keys "yw2p") in
  show t;
  [%expect {|
    (Yank_lines 2)
    (Paste(before true)(count 1))
    NORMAL 0:0 dirty
    > |a
    > b
    > a
    > b
    > c
    > d
    (Yank_motion(motion(Word_forward Small)))
    (Paste(before false)(count 2))
    NORMAL 0:8 dirty
    > oone one| ne two
    |}]
;;

let%expect_test "diw deletes the small word at the cursor" =
  let t = run (create "foo + bar") (keys "lldiw") in
  show t;
  [%expect {|
    (Move(motion Right))
    (Move(motion Right))
    Delete_inner_word
    NORMAL 0:0 dirty
    > | + bar
    |}]
;;

let%expect_test "finds take literal arguments, repeat, and compose with operators" =
  let t = run (create "a,b,c,d") (keys "f,;,") in
  show t;
  let t = run (create "one) two") (keys "df)") in
  show t;
  let t = run (create "one,two,three") (keys "dt,") in
  show t;
  [%expect {|
    (Move(motion(Find((target U+002C)(direction Forward)(till false)))))
    (Repeat_find(opposite false)(count 1))
    (Repeat_find(opposite true)(count 1))
    NORMAL 0:1
    > a|,b,c,d
    (Delete_motion(motion(Find((target U+0029)(direction Forward)(till false)))))
    NORMAL 0:0 dirty
    > | two
    (Delete_motion(motion(Find((target U+002C)(direction Forward)(till true)))))
    NORMAL 0:0 dirty
    > |e,two,three
    |}]
;;

let%expect_test "search prompts and n/N search literally with wrapping" =
  let t = run (create "one two two") (keys "/two<CR>nN") in
  show t;
  let t = run (create "a 日 a") (keys "?日<CR>n") in
  show t;
  let t = run (create "abc") (keys "/zzz<CR>/<CR>") in
  show t;
  [%expect {|
    (Search(query two)(forward true)(count 1)(whole_word false))
    (Search(forward true)(count 1)(whole_word false))
    (Search(forward false)(count 1)(whole_word false))
    NORMAL 0:4
    > one |two two
    (Search(query"\230\151\165")(forward false)(count 1)(whole_word false))
    (Search(forward true)(count 1)(whole_word false))
    NORMAL 0:2 (Info"Search wrapped")
    > a |日 a
    (Search(query zzz)(forward true)(count 1)(whole_word false))
    (Search(query"")(forward true)(count 1)(whole_word false))
    NORMAL 0:0 (Error"Pattern not found: zzz")
    > |abc
    |}]
;;

let%expect_test "star and hash search whole small words" =
  let t = run (create "cat scatter cat") (keys "*n#") in
  show t;
  let t = run (create "cat scatter") (keys "lll*") in
  show t;
  [%expect {|
    (Search_word(forward true))
    (Search(forward true)(count 1)(whole_word false))
    (Search_word(forward false))
    NORMAL 0:12 (Info"Search wrapped")
    > cat scatter |cat
    (Move(motion Right))
    (Move(motion Right))
    (Move(motion Right))
    (Search_word(forward true))
    NORMAL 0:3 (Error"No word under cursor")
    > cat| scatter
    |}]
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
    (Delete_chars_forward 1)
    Quit
    NORMAL 0:0 dirty (Error"Unsaved changes: save them or force quit")
    > |bc
    |}]
;;

let%expect_test "Space Q exits even with unsaved changes" =
  let _ = run (create "abc") (keys "x Q") in
  [%expect {|
    (Delete_chars_forward 1)
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
    (Move(motion(Word_forward Small)))
    (Delete_chars_forward 1)
    NORMAL 0:1 dirty
    > a|b
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
    (Move(motion Right))
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
    (Delete_chars_forward 1)
    Save
    (Write_file (path f.txt) (text bc) (revision 1))
    NORMAL 0:0 dirty
    > |bc
    |}]
;;

let%expect_test "unbound Normal-mode keys and a lone Escape do nothing" =
  let t = run (create "abc") (keys "q<Esc><CR><BS><Del><Tab>Q<C-r>") in
  show t;
  [%expect
    {|
    Clear_search_highlight
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
    (Move(motion Right))
    (Move(motion Down))
    (Move(motion Right))
    NORMAL 1:2
    > abc
    > de|f
    |}];
  let t = run t (keys "khi") in
  show t;
  [%expect
    {|
    (Move(motion Up))
    (Move(motion Left))
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
    (Insert_text" ")
    (Insert_text w)
    (Insert_text" ")
    (Insert_text q)
    (Insert_text"\195\169")
    (Insert_soft_tab 2)
    (Insert_text x)
    Insert_newline
    (Insert_text y)
    INSERT 1:2 dirty
    >  w qé x
    >  y|
    |}];
  let t = run t (keys "<BS><BS><BS><Esc>") in
  show t;
  [%expect
    {|
    (Delete_soft_tab_backward 2)
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
    (Move(motion Left))
    (Move(motion Left))
    (Enter_insert Before_cursor)
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
    (Delete_chars_forward 1)
    (Delete_chars_forward 1)
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
    (Move(motion Right))
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Move(motion(Word_forward Small)))
    NORMAL 0:1
    > a|b
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
    (Insert_soft_tab 4)
    Exit_insert
    NORMAL 0:3 dirty
    >    | x
    |}];
  tab_with Literal_tab;
  [%expect
    {|
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Move(motion Down))
    (Move(motion Right))
    (Move(motion Up))
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Enter_insert Before_cursor)
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
    (Delete_chars_forward 1)
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
    (Move(motion Right))
    NORMAL 0:1
    > a|bc
    |}]
;;

let%expect_test "Insert mode types Space v sequences literally" =
  let t = run (create "") (keys "i vc vL v=<Esc>") in
  show t;
  [%expect {|
    (Enter_insert Before_cursor)
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

(* Counts *)

let lines n = List.init n ~f:(sprintf "line %02d") |> String.concat ~sep:"\n"

(* Mode, zero-based line:column, pending keys and keymap notice, without the text. *)
let show_position { editor; keymap } =
  printf
    "%s %d:%d%s%s\n"
    (Mode.to_string (Editor.mode editor))
    (Editor.cursor_line editor)
    (Editor.cursor_column editor)
    (match Keymap.pending keymap with
     | None -> ""
     | Some pending -> sprintf " pending=%S" pending)
    (match Keymap.notice keymap with
     | None -> ""
     | Some notice -> sprintf " notice=%S" notice)
;;

let%expect_test "digits before h/j/k/l make one counted move, shown while pending" =
  let t = run (create (lines 30)) (keys "2") in
  show_position t;
  [%expect {| NORMAL 0:0 pending="2" |}];
  let t = run t (keys "0") in
  show_position t;
  [%expect {| NORMAL 0:0 pending="20" |}];
  let t = run t (keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 20))
    NORMAL 20:0
    |}];
  let t = run t (keys "5l") in
  show_position t;
  [%expect
    {|
    (Move(motion Right)(count 5))
    NORMAL 20:5
    |}];
  let t = run t (keys "5h") in
  show_position t;
  [%expect
    {|
    (Move(motion Left)(count 5))
    NORMAL 20:0
    |}];
  let t = run t (keys "20k") in
  show_position t;
  [%expect
    {|
    (Move(motion Up)(count 20))
    NORMAL 0:0
    |}];
  (* The count does not outlive its command. *)
  let t = run t (keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 1:0
    |}]
;;

let%expect_test "counts clamp on a tiny file" =
  let t = run (create "ab\ncd") (keys "20j999999l20k") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 20))
    (Move(motion Right)(count 999999))
    (Move(motion Up)(count 20))
    NORMAL 0:1
    |}];
  let t = run (create "") (keys "5j5l") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 5))
    (Move(motion Right)(count 5))
    NORMAL 0:0
    |}]
;;

let%expect_test "a bare 0 is Line_start, but 0 extends a count" =
  let t = run (create (lines 30)) (keys "0") in
  show_position t;
  [%expect {|
    (Move(motion Line_start))
    NORMAL 0:0
    |}];
  let t = run t (keys "10j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 10))
    NORMAL 10:0
    |}];
  let t = run t (keys "00j") in
  show_position t;
  [%expect
    {|
    (Move(motion Line_start))
    (Move(motion Line_start))
    (Move(motion Down))
    NORMAL 11:0
    |}]
;;

let%expect_test "Escape cancels a pending count silently; nothing leaks" =
  let t = run (create (lines 30)) (keys "12<Esc>") in
  show_position t;
  [%expect {| NORMAL 0:0 |}];
  let t = run t (keys "3 <Esc>j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 1:0
    |}]
;;

let%expect_test "an invalid continuation cancels the count with a notice" =
  let t = run (create (lines 30)) (keys "3q") in
  show_position t;
  [%expect {| NORMAL 0:0 notice="3 q is not bound" |}];
  let t = run t (keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 1:0
    |}];
  let t = run t (keys "3<CR>") in
  show_position t;
  [%expect {| NORMAL 1:0 notice="3 Enter is not bound" |}];
  let t = run t (keys "3 z") in
  show_position t;
  [%expect {| NORMAL 1:0 notice="3 Space z is not bound" |}];
  (* A count comes only before a sequence. *)
  let t = run t (keys " 3") in
  show_position t;
  [%expect {| NORMAL 1:0 notice="Space 3 is not bound" |}];
  let t = run t (keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 2:0
    |}]
;;

let%expect_test "counted x works while unsupported commands reject a count" =
  let t = run (create "abc") (keys "3x") in
  show t;
  [%expect
    {|
    (Delete_chars_forward 3)
    NORMAL 0:0 dirty
    > |
    |}];
  let t = run t (keys "2i") in
  show t;
  [%expect
    {|
    NORMAL 0:0 dirty notice="i does not take a count"
    > |
    |}];
  let t = run t (keys "2 ") in
  show t;
  [%expect
    {|
    NORMAL 0:0 dirty pending="2 Space"
    > |
    |}];
  let t = run t (keys "w") in
  show t;
  [%expect
    {|
    NORMAL 0:0 dirty notice="Space w does not take a count"
    > |
    |}];
  let t = run t (keys "4 vl2<C-r>5 Q") in
  show t;
  [%expect
    {|
    NORMAL 0:0 dirty notice="Space Q does not take a count"
    > |
    |}];
  (* Nothing leaks into the next command. *)
  let t = run t (keys "x") in
  show t;
  [%expect
    {|
    (Delete_chars_forward 1)
    NORMAL 0:0 dirty
    > |
    |}]
;;

let%expect_test "a count above 999999 is rejected and reset" =
  let t = run (create (lines 3)) (keys "999999") in
  show_position t;
  [%expect {| NORMAL 0:0 pending="999999" |}];
  let t = run t (keys "9") in
  show_position t;
  [%expect {| NORMAL 0:0 notice="Count is too large: the maximum is 999999" |}];
  let t = run t (keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 1:0
    |}];
  (* Each rejection resets the count, so the digits after it start a new one: 7 + 7 +
     7 nines are rejected three times, and the last 2 nines count. *)
  let t = run t (keys "99999999999999999999999k") in
  show_position t;
  [%expect
    {|
    (Move(motion Up)(count 99))
    NORMAL 0:0
    |}]
;;

let%expect_test "Ctrl-c and paste cancel a pending count" =
  let t = run (create (lines 30)) (keys "5<C-c>j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 1:0
    |}];
  let t = run t (keys "5<C-c>") in
  show_position t;
  [%expect {| NORMAL 1:0 notice="To quit, use Space q in Normal mode" |}];
  let t = run t (keys "5" @ [ Keymap.Input.Paste "j" ] @ keys "j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 2:0
    |}]
;;

let%expect_test "digits are text in Insert mode" =
  let t = run (create "") (keys "i20j<Esc>") in
  show t;
  [%expect
    {|
    (Enter_insert Before_cursor)
    (Insert_text 2)
    (Insert_text 0)
    (Insert_text j)
    Exit_insert
    NORMAL 0:2 dirty
    > 20|j
    |}]
;;

(* Bindings *)

let%expect_test "alternate bindings drive counted movement without editor changes" =
  let normal =
    Bindings.create
      [ [ Key.char 'n' ], Move Down
      ; [ Key.char 'g'; Key.char 'u' ], Move Up
      ; [ Key.char '0' ], Editor Undo
      ; [ Key.char ' '; Key.char 'w' ], Editor Save
      ]
    |> ok_exn
  in
  let config = { Keymap.Config.default with normal } in
  let t = run (create ~config (lines 30)) (keys "12n") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 12))
    NORMAL 12:0
    |}];
  let t = run t (keys "3g") in
  show_position t;
  [%expect {| NORMAL 12:0 pending="3 g" |}];
  let t = run t (keys "u") in
  show_position t;
  [%expect
    {|
    (Move(motion Up)(count 3))
    NORMAL 9:0
    |}];
  (* The defaults are gone; a bare [0] is a binding, and still extends a count. *)
  let t = run t (keys "jx0") in
  show_position t;
  [%expect
    {|
    Undo
    NORMAL 9:0
    |}];
  let t = run t (keys "20") in
  show_position t;
  [%expect {| NORMAL 9:0 pending="20" |}]
;;

let%expect_test "ambiguous or reserved bindings are a configuration error" =
  let k s = List.map (String.to_list s) ~f:Key.char in
  let check bindings =
    match Bindings.create bindings with
    | Ok _ -> print_endline "ok"
    | Error error -> print_s [%sexp (error : Error.t)]
  in
  check [ k "0", Move Left; k "g0", Move Right ];
  [%expect {| ok |}];
  check
    [ k "j", Move Down
    ; k "j", Move Up
    ; k "g", Editor Undo
    ; k "gg", Editor Redo
    ; k "gu", Editor Redo
    ; k "5x", Editor Delete_char
    ; [], Editor Save
    ; [ Key.char ' '; Escape ], Editor Save
    ; [ Ctrl 'c' ], Editor Quit
    ; k "j", Move Left
    ]
  ;
  [%expect
    {|
    ("Invalid key bindings"
     ("5 x starts with a digit, which starts a count"
      "an empty key sequence is bound"
      "Space Escape uses Escape or Ctrl-c, which always cancel"
      "Ctrl-c uses Escape or Ctrl-c, which always cancel"
      "j is bound more than once" "g is a prefix of g g, so it could never run"
      "g is a prefix of g u, so it could never run"))
    |}]
;;

(* Word, line, and document motions *)

let%expect_test "word and line motion keys" =
  let t = run (create "  foo.bar baz\nqux") (keys "wwWbBe") in
  show_position t;
  [%expect
    {|
    (Move(motion(Word_forward Small)))
    (Move(motion(Word_forward Small)))
    (Move(motion(Word_forward Big)))
    (Move(motion(Word_backward Small)))
    (Move(motion(Word_backward Big)))
    (Move(motion(Word_end Small)))
    NORMAL 0:4
    |}];
  let t = run t (keys "E$^02w2$") in
  show_position t;
  [%expect
    {|
    (Move(motion(Word_end Big)))
    (Move(motion Line_end))
    (Move(motion First_nonblank))
    (Move(motion Line_start))
    (Move(motion(Word_forward Small))(count 2))
    (Move(motion Line_end)(count 2))
    NORMAL 1:2
    |}]
;;

let%expect_test "0 and ^ reject a count; 0 after a count extends it" =
  let t = run (create (lines 30)) (keys "4l3^") in
  show_position t;
  [%expect
    {|
    (Move(motion Right)(count 4))
    NORMAL 0:4 notice="^ does not take a count"
    |}];
  let t = run t (keys "10j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down)(count 10))
    NORMAL 10:4
    |}];
  let t = run t (keys "0") in
  show_position t;
  [%expect
    {|
    (Move(motion Line_start))
    NORMAL 10:0
    |}]
;;

let%expect_test "gg and G: pending, cancellation, and explicit counts" =
  let t = run (create (lines 30)) (keys "G") in
  show_position t;
  [%expect
    {|
    (Move(motion Last_line))
    NORMAL 29:0
    |}];
  let t = run t (keys "g") in
  show_position t;
  [%expect {| NORMAL 29:0 pending="g" |}];
  let t = run t (keys "<Esc>") in
  show_position t;
  [%expect {| NORMAL 29:0 |}];
  let t = run t (keys "gx") in
  show_position t;
  [%expect {| NORMAL 29:0 notice="g x is not bound" |}];
  let t = run t (keys "gg") in
  show_position t;
  [%expect
    {|
    (Move(motion First_line))
    NORMAL 0:0
    |}];
  (* Bare G is the last line; 1G is the first. *)
  let t = run t (keys "1G") in
  show_position t;
  [%expect
    {|
    (Move(motion Last_line)(count 1))
    NORMAL 0:0
    |}];
  let t = run t (keys "20G") in
  show_position t;
  [%expect
    {|
    (Move(motion Last_line)(count 20))
    NORMAL 19:0
    |}];
  let t = run t (keys "5g") in
  show_position t;
  [%expect {| NORMAL 19:0 pending="5 g" |}];
  let t = run t (keys "g") in
  show_position t;
  [%expect
    {|
    (Move(motion First_line)(count 5))
    NORMAL 4:0
    |}];
  let t = run t (keys "999999G") in
  show_position t;
  [%expect
    {|
    (Move(motion Last_line)(count 999999))
    NORMAL 29:0
    |}];
  let t = run t (keys "3g<Esc>j") in
  show_position t;
  [%expect
    {|
    (Move(motion Down))
    NORMAL 29:0
    |}]
;;

let%expect_test "a / A / I / o / O enter Insert mode; counts are rejected" =
  let t = run (create "  ab\ncd") (keys "aX<Esc>AY<Esc>IZ<Esc>") in
  show t;
  [%expect
    {|
    (Enter_insert After_cursor)
    (Insert_text X)
    Exit_insert
    (Enter_insert Line_end)
    (Insert_text Y)
    Exit_insert
    (Enter_insert First_nonblank)
    (Insert_text Z)
    Exit_insert
    NORMAL 0:1 dirty
    >  |ZX abY
    > cd
    |}];
  let t = run t (keys "oq<Esc>Or<Esc>") in
  show t;
  [%expect
    {|
    Open_line_below
    (Insert_text q)
    Exit_insert
    Open_line_above
    (Insert_text r)
    Exit_insert
    NORMAL 1:1 dirty
    >  ZX abY
    >  |r
    >  q
    > cd
    |}];
  let t = run t (keys "u") in
  show t;
  [%expect
    {|
    Undo
    NORMAL 1:1 dirty
    >  ZX abY
    >  |q
    > cd
    |}];
  let t = run t (keys "3o") in
  show t;
  [%expect
    {|
    NORMAL 1:1 dirty notice="o does not take a count"
    >  ZX abY
    >  |q
    > cd
    |}];
  let t = run t (keys "2a") in
  show t;
  [%expect
    {|
    NORMAL 1:1 dirty notice="a does not take a count"
    >  ZX abY
    >  |q
    > cd
    |}]
;;

let%expect_test "o then j k, paste, and Enter keep the indentation literal" =
  let t = run (create "\tab") (keys "ojk") in
  show t;
  print_s [%sexp (Text_buffer.to_string (Editor.text t.editor) : string)];
  [%expect
    {|
    Open_line_below
    (Insert_text j)
    Delete_backward
    Exit_insert
    NORMAL 1:0 dirty
    > 	ab
    > |
     "\tab\
    \n\t"
    |}];
  (* The paste is literal; Enter after it indents like the pasted line. *)
  let t = run t (keys "o" @ [ Keymap.Input.Paste "x\n  y" ] @ keys "<CR>z<Esc>") in
  show t;
  print_s [%sexp (Text_buffer.to_string (Editor.text t.editor) : string)];
  [%expect
    {|
    Open_line_below
    (Insert_text"x\n  y")
    Insert_newline
    (Insert_text z)
    Exit_insert
    NORMAL 4:2 dirty
    > 	ab
    >
    > 	x
    >   y
    >   |z
     "\tab\
    \n\t\
    \n\tx\
    \n  y\
    \n  z"
    |}]
;;

let%expect_test "_ and g _ go to the first and last non-blank, with counts" =
  let t = run (create "  ab  \n  cd\n\tef") (keys "$_") in
  show t;
  [%expect
    {|
    (Move(motion Line_end))
    (Move(motion First_nonblank_down))
    NORMAL 0:2
    >   |ab
    >   cd
    > 	ef
    |}];
  let t = run t (keys "g") in
  show t;
  [%expect
    {|
    NORMAL 0:2 pending="g"
    >   |ab
    >   cd
    > 	ef
    |}];
  let t = run t (keys "_2_3g_") in
  show t;
  [%expect
    {|
    (Move(motion Last_nonblank))
    (Move(motion First_nonblank_down)(count 2))
    (Move(motion Last_nonblank)(count 3))
    NORMAL 2:2
    >   ab
    >   cd
    > 	e|f
    |}]
;;

let%expect_test "Space v n / N toggle line-number switches and reject a count" =
  let t = run (create "abc") (keys " vn vN") in
  show t;
  [%expect {|
    (View Toggle_absolute_numbers)
    (View Toggle_relative_numbers)
    NORMAL 0:0
    > |abc
    |}];
  let t = run t (keys "3 vnl") in
  show t;
  [%expect {|
    (Move(motion Right))
    NORMAL 0:1
    > a|bc
    |}]
;;

let%expect_test "% is a motion that rejects a count, even a huge one" =
  let t = run (create "(a)") (keys "%%") in
  show t;
  [%expect {|
    (Move(motion Matching_delimiter))
    (Move(motion Matching_delimiter))
    NORMAL 0:0
    > |(a)
    |}];
  let t = run t (keys "50%") in
  show t;
  [%expect {|
    NORMAL 0:0 notice="% does not take a count"
    > |(a)
    |}];
  let t = run t (keys "999999%l") in
  show t;
  [%expect {|
    (Move(motion Right))
    NORMAL 0:1
    > (|a)
    |}]
;;
