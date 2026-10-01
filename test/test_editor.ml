open! Core
open Ches_core
open Command

let of_string_exn s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

let create ?(path = "f.txt") s = Editor.create ~path (of_string_exn s)

(* Mode, zero-based line:column, revision, dirty flag, message; then the text with
   [|] at the cursor. *)
let show t =
  let text = Text_buffer.to_string (Editor.text t) in
  let cursor = Editor.cursor t in
  printf
    "%s %d:%d rev=%d%s%s\n"
    (Mode.to_string (Editor.mode t))
    (Editor.cursor_line t)
    (Editor.cursor_column t)
    (Editor.revision t)
    (if Editor.is_dirty t then " dirty" else "")
    (match Editor.message t with
     | None -> ""
     | Some message -> " " ^ Sexp.to_string [%sexp (message : Editor.Message.t)]);
  String.prefix text cursor ^ "|" ^ String.drop_prefix text cursor
  |> String.split ~on:'\n'
  |> List.iter ~f:(fun line -> print_endline ("> " ^ line))
;;

(* Dispatch [commands], printing any effects. *)
let run t commands =
  List.fold commands ~init:t ~f:(fun t command ->
    let t, effects = Editor.dispatch t command in
    List.iter effects ~f:(fun effect -> print_s [%sexp (effect : Effect.t)]);
    t)
;;

let typed s = String.to_list s |> List.map ~f:(fun c -> Insert_text (String.of_char c))

let undo_steps t =
  let rec loop t n =
    let t, _ = Editor.dispatch t Undo in
    match Editor.message t with
    | Some (Info "Already at oldest change") -> n
    | _ -> loop t (n + 1)
  in
  loop t 0
;;

let%expect_test "vertical movement keeps a preferred column across shorter lines" =
  let t = run (create "abcdef\nab\n\nabcdef") (List.init 4 ~f:(fun _ -> Move Right)) in
  show t;
  [%expect
    {|
    NORMAL 0:4 rev=0
    > abcd|ef
    > ab
    >
    > abcdef
    |}];
  let t = run t [ Move Down ] in
  show t;
  [%expect
    {|
    NORMAL 1:1 rev=0
    > abcdef
    > a|b
    >
    > abcdef
    |}];
  let t = run t [ Move Down ] in
  show t;
  [%expect
    {|
    NORMAL 2:0 rev=0
    > abcdef
    > ab
    > |
    > abcdef
    |}];
  let t = run t [ Move Down ] in
  show t;
  [%expect
    {|
    NORMAL 3:4 rev=0
    > abcdef
    > ab
    >
    > abcd|ef
    |}];
  (* At the last line, Down is a no-op and keeps the preference. *)
  let t = run t [ Move Down; Move Up; Move Up; Move Up ] in
  show t;
  [%expect
    {|
    NORMAL 0:4 rev=0
    > abcd|ef
    > ab
    >
    > abcdef
    |}];
  (* Insert mode may sit at the end of a shorter line. *)
  let t = run t [ Enter_insert; Move Down ] in
  show t;
  [%expect
    {|
    INSERT 1:2 rev=0
    > abcdef
    > ab|
    >
    > abcdef
    |}]
;;

let%expect_test "h and l stop at line boundaries" =
  let t = run (create "ab\ncd") [ Move Left ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |ab
    > cd
    |}];
  (* Normal mode stops on the last character... *)
  let t = run t [ Move Right; Move Right; Move Right ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=0
    > a|b
    > cd
    |}];
  (* ...Insert mode can reach the line end but not cross the LF. *)
  let t = run t [ Enter_insert; Move Right; Move Right ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=0
    > ab|
    > cd
    |}];
  let t = run t [ Move Down; Move Left; Move Left; Move Left ] in
  show t;
  [%expect
    {|
    INSERT 1:0 rev=0
    > ab
    > |cd
    |}]
;;

let%expect_test "empty buffer and empty final line" =
  let t =
    run
      (create "")
      [ Move Left; Move Right; Move Up; Move Down; Delete_char; Undo; Redo ]
  in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0 (Info"Already at newest change")
    > |
    |}];
  let t = run (create "abc\n") [ Move Right; Move Right; Move Down ] in
  show t;
  [%expect
    {|
    NORMAL 1:0 rev=0
    > abc
    > |
    |}];
  (* [x] on an empty line deletes nothing (in particular, not the previous LF), and
     leaves the preferred column alone. *)
  let t = run t [ Delete_char ] in
  show t;
  [%expect
    {|
    NORMAL 1:0 rev=0
    > abc
    > |
    |}];
  show (run t [ Move Up ]);
  [%expect
    {|
    NORMAL 0:2 rev=0
    > ab|c
    >
    |}];
  (* h/l are horizontal moves even when blocked: they reset the preference to 0. *)
  show (run t [ Move Right; Move Left; Move Up ]);
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |abc
    >
    |}];
  let t = run t [ Move Down; Enter_insert; Insert_text "x" ] in
  show t;
  [%expect
    {|
    INSERT 1:1 rev=1 dirty
    > abc
    > x|
    |}]
;;

let%expect_test "mode transitions" =
  let t = run (create "abc\ndef") [ Move Down; Enter_insert; Exit_insert ] in
  (* Escape at a line start does not cross onto the previous line. *)
  show t;
  [%expect
    {|
    NORMAL 1:0 rev=0
    > abc
    > |def
    |}];
  let t = run t [ Move Right; Enter_insert; Insert_text "X" ] in
  show t;
  [%expect
    {|
    INSERT 1:2 rev=1 dirty
    > abc
    > dX|ef
    |}];
  let t = run t [ Exit_insert ] in
  show t;
  [%expect
    {|
    NORMAL 1:1 rev=1 dirty
    > abc
    > d|Xef
    |}];
  (* Escape from the end of a line lands on its last character. *)
  let t = run t [ Enter_insert; Move Right; Move Right; Move Right; Exit_insert ] in
  show t;
  [%expect
    {|
    NORMAL 1:3 rev=1 dirty
    > abc
    > dXe|f
    |}];
  (* Commands for the other mode change nothing. *)
  let t' =
    run
      t
      [ Exit_insert; Insert_text "zz"; Delete_backward; Delete_forward ]
  in
  print_s [%sexp (phys_equal t t' : bool)];
  [%expect {| true |}];
  let t = run t [ Enter_insert ] in
  let t' = run t [ Enter_insert; Delete_char ] in
  print_s [%sexp (phys_equal t t' : bool)];
  [%expect {| true |}]
;;

let%expect_test "Backspace and Delete join lines" =
  let t = run (create "ab\ncd") [ Move Down; Enter_insert; Delete_backward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > ab|cd
    |}];
  let t = run (create "ab\ncd") [ Enter_insert; Move Right; Move Right; Delete_forward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > ab|cd
    |}];
  (* At the very start and end of the text they do nothing. *)
  let t = run (create "ab") [ Enter_insert; Delete_backward ] in
  show t;
  [%expect
    {|
    INSERT 0:0 rev=0
    > |ab
    |}];
  let t = run t [ Move Right; Move Right; Delete_forward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=0
    > ab|
    |}];
  (* Enter is just an inserted LF. *)
  let t = run (create "abcd") [ Move Right; Move Right; Enter_insert; Insert_text "\n" ] in
  show t;
  [%expect
    {|
    INSERT 1:0 rev=1 dirty
    > ab
    > |cd
    |}]
;;

(* a = 1 byte, 日 = 3, 🐹 = 4 *)
let%expect_test "multibyte movement and deletion" =
  let t = run (create "a日🐹b") [ Move Right ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=0
    > a|日🐹b
    |}];
  let t = run t [ Delete_char ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=1 dirty
    > a|🐹b
    |}];
  let t = run t [ Enter_insert; Move Right ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > a🐹|b
    |}];
  let t = run t [ Delete_backward ] in
  show t;
  [%expect
    {|
    INSERT 0:1 rev=2 dirty
    > a|b
    |}];
  (* [x] on the last character moves the cursor back onto the new last character. *)
  let t = run t [ Exit_insert; Move Right; Delete_char ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=3 dirty
    > |a
    |}]
;;

let%expect_test "contiguous typing, including Backspace, is one undo step" =
  let t =
    run
      (create "")
      ([ Enter_insert ] @ typed "abc" @ [ Delete_backward ] @ typed "d" @ [ Exit_insert ])
  in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=5 dirty
    > ab|d
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 1 |}];
  let t = run t [ Undo ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=6
    > |
    |}];
  let t = run t [ Redo ] in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=7 dirty
    > ab|d
    |}]
;;

let%expect_test "movement and save split transactions; x is standalone" =
  let t =
    run
      (create "")
      ([ Enter_insert ]
       @ typed "ab"
       @ [ Move Left ]
       @ typed "c"
       @ [ Save ]
       @ typed "d"
       @ [ Exit_insert ])
  in
  [%expect {| (Write_file (path f.txt) (text acb) (revision 3)) |}];
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=4 dirty
    > ac|db
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 3 |}];
  let t = run t [ Undo ] in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=5 dirty
    > ac|b
    |}];
  let t = run t [ Undo ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=6 dirty
    > a|b
    |}];
  let t = run (create "abc") [ Delete_char; Delete_char ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=2 dirty
    > |c
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 2 |}]
;;

let%expect_test "undo in Insert mode closes the active transaction first" =
  let t = run (create "hello") ([ Move Right; Move Right; Enter_insert ] @ typed "XY") in
  show t;
  [%expect
    {|
    INSERT 0:4 rev=2 dirty
    > heXY|llo
    |}];
  let t = run t [ Undo ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=3
    > he|llo
    |}];
  let t = run t (typed "Z" @ [ Exit_insert ]) in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=4 dirty
    > he|Zllo
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 1 |}]
;;

let%expect_test "redo survives mode changes but not a new edit" =
  let t = run (create "abc") [ Delete_char; Undo ] in
  let t = run t [ Enter_insert; Exit_insert; Redo ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=3 dirty
    > |bc
    |}];
  (* Typing with no net change does not record a step, so redo survives it too. *)
  let t = run t ([ Undo; Enter_insert ] @ typed "q" @ [ Delete_backward; Exit_insert; Redo ]) in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=7 dirty
    > |bc
    |}];
  let t = run t ([ Undo; Enter_insert ] @ typed "z" @ [ Exit_insert; Redo ]) in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=9 dirty (Info"Already at newest change")
    > |zabc
    |}]
;;

let%expect_test "movement and mode changes record nothing and keep the revision" =
  let t =
    run
      (create "ab\ncd")
      [ Move Down; Move Right; Enter_insert; Move Left; Exit_insert; Move Up ]
  in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |ab
    > cd
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 0 |}]
;;

let%expect_test "invalid inserted text is rejected with a message" =
  let t = run (create "ab") [ Enter_insert; Insert_text "x\r\ny" ] in
  show t;
  [%expect
    {|
    INSERT 0:0 rev=0 (Error"Rejected text: CRLF line ending (only LF line endings are supported) at byte offset 1")
    > |ab
    |}];
  (* The next command clears the message. *)
  let t = run t [ Insert_text "ok" ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > ok|ab
    |}]
;;

let%expect_test "undoing back to the saved text clears dirty; revision still advances" =
  let t = run (create "abc") [ Delete_char ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=1 dirty
    > |bc
    |}];
  let t = run t [ Undo ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=2
    > |abc
    |}]
;;

(* Dispatch [Save] and return the single write request. *)
let save t =
  match Editor.dispatch t Save with
  | t, [ Write_file { path; text; revision } ] -> t, (path, text, revision)
  | _, effects -> raise_s [%message "expected one write" (effects : Effect.t list)]
;;

let finish t (path, text, revision) result =
  Editor.handle_outcome t (Write_file_finished { path; text; revision; result })
;;

let%expect_test "successful save marks the text saved" =
  let t, write = save (run (create "abc") [ Delete_char ]) in
  show (finish t write (Ok ()));
  [%expect
    {|
    NORMAL 0:0 rev=1 (Info"Wrote f.txt (2 bytes)")
    > |bc
    |}]
;;

let%expect_test "failed save keeps the document dirty" =
  let t, write = save (run (create "abc") [ Delete_char ]) in
  show (finish t write (Error (Error.of_string "Permission denied")));
  [%expect
    {|
    NORMAL 0:0 rev=1 dirty (Error"Failed to write f.txt: Permission denied")
    > |bc
    |}]
;;

let%expect_test "completing an older save leaves newer text dirty" =
  let t, older = save (run (create "abc") [ Delete_char ]) in
  let t = run t [ Delete_char ] in
  let t = finish t older (Ok ()) in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=2 dirty (Info"Wrote f.txt (2 bytes)")
    > |c
    |}];
  (* The saved text is the one that was written, so undoing back to it is clean. *)
  show (run t [ Undo ]);
  [%expect
    {|
    NORMAL 0:0 rev=3
    > |bc
    |}];
  (* An older success reported after a newer one does not roll the saved state back. *)
  let t, newer = save t in
  let t = finish t newer (Ok ()) in
  let t = finish t older (Ok ()) in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=2 (Info"Wrote f.txt (2 bytes)")
    > |c
    |}]
;;

let%expect_test "a new file starts clean and empty and can still be saved" =
  let t = create ~path:"new.txt" "" in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |
    |}];
  let _ = run t [ Save; Quit ] in
  [%expect
    {|
    (Write_file (path new.txt) (text "") (revision 0))
    Exit
    |}]
;;

let%expect_test "save without a path" =
  show (run (Editor.create Text_buffer.empty) [ Save ]);
  [%expect
    {|
    NORMAL 0:0 rev=0 (Error"No file name")
    > |
    |}]
;;

let%expect_test "quit refuses unsaved changes; force quit does not" =
  let _ = run (create "abc") [ Quit ] in
  [%expect {| Exit |}];
  let t = run (create "abc") [ Delete_char; Enter_insert; Quit ] in
  show t;
  [%expect
    {|
    INSERT 0:0 rev=1 dirty (Error"Unsaved changes: save them or force quit")
    > |bc
    |}];
  let _ = run t [ Force_quit ] in
  [%expect {| Exit |}]
;;

(* Random command sequences preserve the cursor invariants; undoing everything restores
   the original text, and redoing the same number of steps restores the final text. *)

let gen_text =
  Quickcheck.Generator.(
    list (of_list [ "a"; "b"; "\n"; "日"; "🐹" ]) |> map ~f:String.concat)
;;

let gen_command =
  Quickcheck.Generator.of_list
    ([ Enter_insert
     ; Exit_insert
     ; Insert_text "x"
     ; Insert_text "\n"
     ; Insert_text "é\n日"
     ; Insert_text "\r"
     ; Delete_backward
     ; Delete_forward
     ; Delete_char
     ; Undo
     ; Redo
     ; Save
     ]
     @ List.map Direction.all ~f:(fun d -> Move d))
;;

let check_cursor t =
  let text = Editor.text t in
  let cursor = Editor.cursor t in
  assert (Text_buffer.is_boundary text cursor);
  match Editor.mode t with
  | Insert -> ()
  | Normal ->
    let line = Text_buffer.line_of_offset text cursor in
    let start = Text_buffer.line_start text line in
    let stop = Text_buffer.line_end text line in
    if not (cursor < stop || (start = stop && cursor = start))
    then raise_s [%message "bad Normal cursor" (t |> show : unit) (cursor : int)]
;;

(* Undo until there is nothing left to undo, returning the number of steps taken. *)
let undo_all t =
  let rec loop t n =
    let t', _ = Editor.dispatch t Undo in
    match Editor.message t' with
    | Some (Info "Already at oldest change") -> t', n
    | _ -> loop t' (n + 1)
  in
  loop t 0
;;

let%test_unit "random commands keep the cursor valid; undo/redo round-trips" =
  Quickcheck.test
    (Quickcheck.Generator.both gen_text (Quickcheck.Generator.list gen_command))
    ~sexp_of:[%sexp_of: string * Command.t list]
    ~f:(fun (initial, commands) ->
      let t =
        List.fold commands ~init:(create initial) ~f:(fun t command ->
          let t', _ = Editor.dispatch t command in
          check_cursor t';
          assert (Editor.revision t' >= Editor.revision t);
          t')
      in
      let final = Editor.text t in
      let t, steps = undo_all t in
      check_cursor t;
      [%test_result: string]
        (Text_buffer.to_string (Editor.text t))
        ~expect:initial;
      assert (not (Editor.is_dirty t));
      (* Redo exactly as many steps as were undone: the sequence itself may have left
         redo steps beyond [final]. *)
      let t =
        Fn.apply_n_times ~n:steps (fun t ->
          let t, _ = Editor.dispatch t Redo in
          check_cursor t;
          t) t
      in
      [%test_result: string]
        (Text_buffer.to_string (Editor.text t))
        ~expect:(Text_buffer.to_string final))
;;

let%expect_test "soft tabs insert spaces to the next multiple of the width" =
  let t = run (create "") [ Enter_insert; Insert_soft_tab 2 ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    >   |
    |}];
  let t = run t (typed "a" @ [ Insert_soft_tab 2; Insert_soft_tab 4 ]) in
  show t;
  [%expect
    {|
    INSERT 0:8 rev=4 dirty
    >   a     |
    |}];
  (* One undo step for the whole typing session. *)
  let t = run t [ Exit_insert; Undo ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=5
    > |
    |}]
;;

let%expect_test "soft-tab Backspace deletes spaces back to the previous multiple" =
  let backspace text ~cursor_after =
    let t = run (create text) [ Enter_insert ] in
    let t = run t (List.init cursor_after ~f:(fun _ -> Command.Move Right)) in
    let t = run t [ Delete_soft_tab_backward 2 ] in
    show t
  in
  (* From column 4 back to column 2. *)
  backspace "    x" ~cursor_after:4;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    >   |x
    |}];
  (* From column 3 back to column 2: one space. *)
  backspace "a  x" ~cursor_after:3;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > a |x
    |}];
  (* Stops at a non-space. *)
  backspace "abc x" ~cursor_after:4;
  [%expect
    {|
    INSERT 0:3 rev=1 dirty
    > abc|x
    |}];
  (* No space before the cursor: an ordinary Backspace, which may join lines. *)
  backspace "ab" ~cursor_after:2;
  [%expect
    {|
    INSERT 0:1 rev=1 dirty
    > a|
    |}];
  let t =
    run
      (create "a\n  b")
      [ Move Down; Move Right; Move Right; Enter_insert; Delete_soft_tab_backward 2 ]
  in
  show t;
  [%expect
    {|
    INSERT 1:0 rev=1 dirty
    > a
    > |b
    |}];
  let t = run t [ Delete_soft_tab_backward 2 ] in
  show t;
  [%expect
    {|
    INSERT 0:1 rev=2 dirty
    > a|b
    |}]
;;

let%expect_test "soft-tab commands are Insert-only and reject a width below 1" =
  let t = run (create "  x") [ Move Right; Move Right ] in
  let t = run t [ Insert_soft_tab 2; Delete_soft_tab_backward 2 ] in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=0
    >   |x
    |}];
  let t = run t [ Enter_insert ] in
  Expect_test_helpers_core.require_does_raise (fun () ->
    Editor.dispatch t (Insert_soft_tab 0));
  Expect_test_helpers_core.require_does_raise (fun () ->
    Editor.dispatch t (Delete_soft_tab_backward (-1)));
  [%expect
    {|
    (Invalid_argument "soft tab width 0 is less than 1")
    (Invalid_argument "soft tab width -1 is less than 1")
    |}]
;;
