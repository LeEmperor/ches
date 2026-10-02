open! Core
open Ches_core
open Command

let of_string_exn s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

let create ?(path = "f.txt") s = Editor.create ~path (of_string_exn s)
let move ?count motion = Move { motion; count }
let insert = Enter_insert Before_cursor

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

(* Mode, zero-based line:column, and revision. *)
let show_position t =
  printf
    "%s %d:%d rev=%d\n"
    (Mode.to_string (Editor.mode t))
    (Editor.cursor_line t)
    (Editor.cursor_column t)
    (Editor.revision t)
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
  let t = run (create "abcdef\nab\n\nabcdef") (List.init 4 ~f:(fun _ -> move Right)) in
  show t;
  [%expect
    {|
    NORMAL 0:4 rev=0
    > abcd|ef
    > ab
    >
    > abcdef
    |}];
  let t = run t [ move Down ] in
  show t;
  [%expect
    {|
    NORMAL 1:1 rev=0
    > abcdef
    > a|b
    >
    > abcdef
    |}];
  let t = run t [ move Down ] in
  show t;
  [%expect
    {|
    NORMAL 2:0 rev=0
    > abcdef
    > ab
    > |
    > abcdef
    |}];
  let t = run t [ move Down ] in
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
  let t = run t [ move Down; move Up; move Up; move Up ] in
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
  let t = run t [ insert; move Down ] in
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
  let t = run (create "ab\ncd") [ move Left ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |ab
    > cd
    |}];
  (* Normal mode stops on the last character... *)
  let t = run t [ move Right; move Right; move Right ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=0
    > a|b
    > cd
    |}];
  (* ...Insert mode can reach the line end but not cross the LF. *)
  let t = run t [ insert; move Right; move Right ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=0
    > ab|
    > cd
    |}];
  let t = run t [ move Down; move Left; move Left; move Left ] in
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
      [ move Left; move Right; move Up; move Down; Delete_char; Undo; Redo ]
  in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=0 (Info"Already at newest change")
    > |
    |}];
  let t = run (create "abc\n") [ move Right; move Right; move Down ] in
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
  show (run t [ move Up ]);
  [%expect
    {|
    NORMAL 0:2 rev=0
    > ab|c
    >
    |}];
  (* h/l are horizontal moves even when blocked: they reset the preference to 0. *)
  show (run t [ move Right; move Left; move Up ]);
  [%expect
    {|
    NORMAL 0:0 rev=0
    > |abc
    >
    |}];
  let t = run t [ move Down; insert; Insert_text "x" ] in
  show t;
  [%expect
    {|
    INSERT 1:1 rev=1 dirty
    > abc
    > x|
    |}]
;;

let%expect_test "mode transitions" =
  let t = run (create "abc\ndef") [ move Down; insert; Exit_insert ] in
  (* Escape at a line start does not cross onto the previous line. *)
  show t;
  [%expect
    {|
    NORMAL 1:0 rev=0
    > abc
    > |def
    |}];
  let t = run t [ move Right; insert; Insert_text "X" ] in
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
  let t = run t [ insert; move Right; move Right; move Right; Exit_insert ] in
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
  let t = run t [ insert ] in
  let t' = run t [ insert; Delete_char ] in
  print_s [%sexp (phys_equal t t' : bool)];
  [%expect {| true |}]
;;

let%expect_test "Backspace and Delete join lines" =
  let t = run (create "ab\ncd") [ move Down; insert; Delete_backward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > ab|cd
    |}];
  let t = run (create "ab\ncd") [ insert; move Right; move Right; Delete_forward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=1 dirty
    > ab|cd
    |}];
  (* At the very start and end of the text they do nothing. *)
  let t = run (create "ab") [ insert; Delete_backward ] in
  show t;
  [%expect
    {|
    INSERT 0:0 rev=0
    > |ab
    |}];
  let t = run t [ move Right; move Right; Delete_forward ] in
  show t;
  [%expect
    {|
    INSERT 0:2 rev=0
    > ab|
    |}];
  (* Enter is just an inserted LF. *)
  let t = run (create "abcd") [ move Right; move Right; insert; Insert_text "\n" ] in
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
  let t = run (create "a日🐹b") [ move Right ] in
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
  let t = run t [ insert; move Right ] in
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
  let t = run t [ Exit_insert; move Right; Delete_char ] in
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
      ([ insert ] @ typed "abc" @ [ Delete_backward ] @ typed "d" @ [ Exit_insert ])
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
      ([ insert ]
       @ typed "ab"
       @ [ move Left ]
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
  let t = run (create "hello") ([ move Right; move Right; insert ] @ typed "XY") in
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
  let t = run t [ insert; Exit_insert; Redo ] in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=3 dirty
    > |bc
    |}];
  (* Typing with no net change does not record a step, so redo survives it too. *)
  let t = run t ([ Undo; insert ] @ typed "q" @ [ Delete_backward; Exit_insert; Redo ]) in
  show t;
  [%expect
    {|
    NORMAL 0:0 rev=7 dirty
    > |bc
    |}];
  let t = run t ([ Undo; insert ] @ typed "z" @ [ Exit_insert; Redo ]) in
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
      [ move Down; move Right; insert; move Left; Exit_insert; move Up ]
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
  let t = run (create "ab") [ insert; Insert_text "x\r\ny" ] in
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
  let t = run (create "abc") [ Delete_char; insert; Quit ] in
  show t;
  [%expect
    {|
    INSERT 0:0 rev=1 dirty (Error"Unsaved changes: save them or force quit")
    > |bc
    |}];
  let _ = run t [ Force_quit ] in
  [%expect {| Exit |}]
;;

let%expect_test "counted vertical moves keep the preferred column across short lines" =
  let lines = List.init 30 ~f:(fun i -> if i % 3 = 1 then "ab" else sprintf "line %02d" i) in
  let t = create (String.concat lines ~sep:"\n") in
  let t = run t [ move ~count:5 Right; move ~count:20 Down ] in
  show_position t;
  [%expect {| NORMAL 20:5 rev=0 |}];
  (* Line 19 is short: the cursor lands on its last character, keeping column 5. *)
  let t = run t [ move Up ] in
  show_position t;
  [%expect {| NORMAL 19:1 rev=0 |}];
  let t = run t [ move ~count:19 Up ] in
  show_position t;
  [%expect {| NORMAL 0:5 rev=0 |}]
;;

let%expect_test "counted moves clamp at line and document boundaries" =
  let t = create "abc\ndefgh\nij" in
  let t = run t [ move ~count:20 Down ] in
  show_position t;
  [%expect {| NORMAL 2:0 rev=0 |}];
  let t = run t [ move ~count:max_count Right ] in
  show_position t;
  [%expect {| NORMAL 2:1 rev=0 |}];
  let t = run t [ move ~count:max_count Up ] in
  show_position t;
  [%expect {| NORMAL 0:1 rev=0 |}];
  let t = run t [ move ~count:5 Left ] in
  show_position t;
  [%expect {| NORMAL 0:0 rev=0 |}];
  (* Insert mode allows the line end. *)
  let t = run t [ insert; move ~count:99 Right ] in
  show_position t;
  [%expect {| INSERT 0:3 rev=0 |}];
  let t = run (create "a\nb") [ move ~count:3 Right; move ~count:2 Left ] in
  show_position t;
  [%expect {| NORMAL 0:0 rev=0 |}]
;;

let%expect_test "counted moves with multibyte text" =
  let t = run (create "a日🐹bé\nx") [ move ~count:3 Right ] in
  show t;
  [%expect
    {|
    NORMAL 0:3 rev=0
    > a日🐹|bé
    > x
    |}];
  let t = run t [ move ~count:2 Left ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=0
    > a|日🐹bé
    > x
    |}]
;;

let%expect_test "counted moves change no text or history; a count outside the bound \
                 raises" =
  let t = run (create "ab\ncd") [ insert; Insert_text "x"; Exit_insert ] in
  let t = run t [ move ~count:4 Down; move ~count:4 Right; move ~count:4 Up ] in
  show t;
  [%expect
    {|
    NORMAL 0:1 rev=1 dirty
    > x|ab
    > cd
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 1 |}];
  List.iter [ 0; -1; max_count + 1 ] ~f:(fun count ->
    Expect_test_helpers_core.require_does_raise (fun () ->
      Editor.dispatch t (move ~count Down)));
  [%expect
    {|
    (Invalid_argument "count 0 is not between 1 and 999999")
    (Invalid_argument "count -1 is not between 1 and 999999")
    (Invalid_argument "count 1000000 is not between 1 and 999999")
    |}]
;;

(* Random command sequences preserve the cursor invariants; undoing everything restores
   the original text, and redoing the same number of steps restores the final text. *)

let gen_text =
  Quickcheck.Generator.(
    list (of_list [ "a"; "b"; "\n"; "日"; "🐹"; " "; "\t"; "."; "_" ]) |> map ~f:String.concat)
;;

let gen_command =
  Quickcheck.Generator.of_list
    ([ Enter_insert Before_cursor
     ; Enter_insert After_cursor
     ; Enter_insert Line_end
     ; Enter_insert First_nonblank
     ; Open_line_below
     ; Open_line_above
     ; Exit_insert
     ; Insert_text "x"
     ; Insert_text "\n"
     ; Insert_newline
     ; Insert_text "é\n日"
     ; Insert_text "\r"
     ; Delete_backward
     ; Delete_forward
     ; Delete_char
     ; Undo
     ; Redo
     ; Save
     ]
     @ List.concat_map Motion.all ~f:(fun m ->
       if Motion.takes_count m
       then [ move m; move ~count:3 m; move ~count:max_count m ]
       else [ move m ]))
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
  let t = run (create "") [ insert; Insert_soft_tab 2 ] in
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
    let t = run (create text) [ insert ] in
    let t = run t (List.init cursor_after ~f:(fun _ -> move Right)) in
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
      [ move Down; move Right; move Right; insert; Delete_soft_tab_backward 2 ]
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
  let t = run (create "  x") [ move Right; move Right ] in
  let t = run t [ Insert_soft_tab 2; Delete_soft_tab_backward 2 ] in
  show t;
  [%expect
    {|
    NORMAL 0:2 rev=0
    >   |x
    |}];
  let t = run t [ insert ] in
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

let%test_unit "a counted move is the same as that many single moves" =
  Quickcheck.test
    Quickcheck.Generator.(
      tuple4
        gen_text
        (of_list
           ([ Motion.Left; Right; Up; Down ]
            @ List.concat_map Motion.Word.all ~f:(fun word ->
              [ Motion.Word_forward word; Word_backward word; Word_end word ])))
        (Int.gen_incl 1 8)
        bool)
    ~sexp_of:[%sexp_of: string * Motion.t * int * bool]
    ~f:(fun (initial, direction, count, insert) ->
      let start =
        run (create initial) (if insert then [ Enter_insert Before_cursor ] else [])
      in
      (* Probe the preferred column with a vertical move afterwards, too. *)
      let probe = [ move Down; move Up ] in
      let counted = run start ([ move ~count direction ] @ probe) in
      let single = run start (List.init count ~f:(fun _ -> move direction) @ probe) in
      [%test_result: int] (Editor.cursor counted) ~expect:(Editor.cursor single))
;;

(* Like [show], with spaces as [.] and TABs as [>], so indentation is visible. *)
let show_blanks t =
  let text = Text_buffer.to_string (Editor.text t) in
  let cursor = Editor.cursor t in
  let visible s =
    String.map s ~f:(function
      | ' ' -> '.'
      | '\t' -> '>'
      | c -> c)
  in
  printf
    "%s %d:%d rev=%d%s\n"
    (Mode.to_string (Editor.mode t))
    (Editor.cursor_line t)
    (Editor.cursor_column t)
    (Editor.revision t)
    (if Editor.is_dirty t then " dirty" else "");
  visible (String.prefix text cursor) ^ "|" ^ visible (String.drop_prefix text cursor)
  |> String.split ~on:'\n'
  |> List.iter ~f:(fun line -> print_endline ("> " ^ line))
;;

let%expect_test "Insert-entry positions on first and last characters" =
  let entries : Insert_position.t list =
    [ Before_cursor; After_cursor; Line_end; First_nonblank ]
  in
  List.iter
    [ "first", "  ab日", []; "last", "  ab日", [ move Line_end ] ]
    ~f:(fun (where, text, moves) ->
      List.iter entries ~f:(fun entry ->
        let t = run (create text) (moves @ [ Enter_insert entry ]) in
        printf "%s %s: " where (Sexp.to_string [%sexp (entry : Insert_position.t)]);
        show_blanks t));
  [%expect
    {|
    first Before_cursor: INSERT 0:0 rev=0
    > |..ab日
    first After_cursor: INSERT 0:1 rev=0
    > .|.ab日
    first Line_end: INSERT 0:5 rev=0
    > ..ab日|
    first First_nonblank: INSERT 0:2 rev=0
    > ..|ab日
    last Before_cursor: INSERT 0:4 rev=0
    > ..ab|日
    last After_cursor: INSERT 0:5 rev=0
    > ..ab日|
    last Line_end: INSERT 0:5 rev=0
    > ..ab日|
    last First_nonblank: INSERT 0:2 rev=0
    > ..|ab日
    |}]
;;

let%expect_test "Insert-entry positions on empty and blank lines and at file edges" =
  let entries : Insert_position.t list =
    [ Before_cursor; After_cursor; Line_end; First_nonblank ]
  in
  List.iter
    [ "empty file", "", []
    ; "empty line", "a\n\nb", [ move Down ]
    ; "final line after LF", "ab\n", [ move Last_line ]
    ; "blank line", "\t  ", []
    ]
    ~f:(fun (where, text, moves) ->
      List.iter entries ~f:(fun entry ->
        let t = run (create text) (moves @ [ Enter_insert entry ]) in
        printf "%s %s: " where (Sexp.to_string [%sexp (entry : Insert_position.t)]);
        show_position t));
  [%expect
    {|
    empty file Before_cursor: INSERT 0:0 rev=0
    empty file After_cursor: INSERT 0:0 rev=0
    empty file Line_end: INSERT 0:0 rev=0
    empty file First_nonblank: INSERT 0:0 rev=0
    empty line Before_cursor: INSERT 1:0 rev=0
    empty line After_cursor: INSERT 1:0 rev=0
    empty line Line_end: INSERT 1:0 rev=0
    empty line First_nonblank: INSERT 1:0 rev=0
    final line after LF Before_cursor: INSERT 1:0 rev=0
    final line after LF After_cursor: INSERT 1:0 rev=0
    final line after LF Line_end: INSERT 1:0 rev=0
    final line after LF First_nonblank: INSERT 1:0 rev=0
    blank line Before_cursor: INSERT 0:0 rev=0
    blank line After_cursor: INSERT 0:1 rev=0
    blank line Line_end: INSERT 0:3 rev=0
    blank line First_nonblank: INSERT 0:3 rev=0
    |}]
;;

let%expect_test "opening lines copies the line's indentation" =
  List.iter
    [ "below, middle line", "a\n \tb\nc", [ move Down ], Open_line_below
    ; "above, middle line", "a\n \tb\nc", [ move Down ], Open_line_above
    ; "below, last line without LF", "x\n  ab", [ move Last_line ], Open_line_below
    ; "above, first line", "  ab\nx", [], Open_line_above
    ; "below, final empty line", "ab\n", [ move Last_line ], Open_line_below
    ; "above, final empty line", "ab\n", [ move Last_line ], Open_line_above
    ; "below, empty file", "", [], Open_line_below
    ; "above, empty file", "", [], Open_line_above
    ; "below, blank line", "    ", [ move Line_end ], Open_line_below
    ]
    ~f:(fun (name, text, moves, command) ->
      print_endline ("-- " ^ name);
      show_blanks (run (create text) (moves @ [ command ])));
  [%expect
    {|
    -- below, middle line
    INSERT 2:2 rev=1 dirty
    > a
    > .>b
    > .>|
    > c
    -- above, middle line
    INSERT 1:2 rev=1 dirty
    > a
    > .>|
    > .>b
    > c
    -- below, last line without LF
    INSERT 2:2 rev=1 dirty
    > x
    > ..ab
    > ..|
    -- above, first line
    INSERT 0:2 rev=1 dirty
    > ..|
    > ..ab
    > x
    -- below, final empty line
    INSERT 2:0 rev=1 dirty
    > ab
    >
    > |
    -- above, final empty line
    INSERT 1:0 rev=1 dirty
    > ab
    > |
    >
    -- below, empty file
    INSERT 1:0 rev=1 dirty
    >
    > |
    -- above, empty file
    INSERT 0:0 rev=1 dirty
    > |
    >
    -- below, blank line
    INSERT 1:4 rev=1 dirty
    > ....
    > ....|
    |}]
;;

let%expect_test "open line plus typing is one undo step restoring text and cursor" =
  let t = run (create "  if x:\n  y") [ move Right; move Right; move Right ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 0:3 rev=0
    > ..i|f.x:
    > ..y
    |}];
  let t = run t ([ Open_line_below ] @ typed "z" @ [ Insert_newline ] @ typed "w") in
  let t = run t [ Delete_backward; Exit_insert ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 2:1 rev=5 dirty
    > ..if.x:
    > ..z
    > .|.
    > ..y
    |}];
  print_s [%sexp (undo_steps t : int)];
  [%expect {| 1 |}];
  let t = run t [ Undo ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 0:3 rev=6
    > ..i|f.x:
    > ..y
    |}];
  let t = run t [ Redo ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 2:1 rev=7 dirty
    > ..if.x:
    > ..z
    > .|.
    > ..y
    |}]
;;

let%expect_test "leaving Insert right after opening a line keeps the indentation" =
  let t = run (create "a\n    b") [ move Last_line; Open_line_above; Exit_insert ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 1:3 rev=1 dirty
    > a
    > ...|.
    > ....b
    |}];
  (* A save, then an undo of the opened line, recovers the saved state as dirty; redo
     makes it clean again. *)
  let t = run t [ Save ] in
  let t =
    Editor.handle_outcome
      t
      (Write_file_finished
         { path = "f.txt"
         ; text = Editor.text t
         ; revision = Editor.revision t
         ; result = Ok ()
         })
  in
  let t = run t [ Undo ] in
  show_blanks t;
  let t = run t [ Redo ] in
  show_blanks t;
  [%expect
    {|
    (Write_file (path f.txt) (text  "a\
                                   \n    \
                                   \n    b") (revision 1))
    NORMAL 1:4 rev=2 dirty
    > a
    > ....|b
    NORMAL 1:3 rev=3
    > a
    > ...|.
    > ....b
    |}]
;;

let%expect_test "Insert_newline copies the indentation before the cursor" =
  let newline_at name text moves =
    print_endline ("-- " ^ name);
    show_blanks (run (create text) (moves @ [ Insert_newline ]))
  in
  let right n = List.init n ~f:(fun _ -> move Right) in
  newline_at "after text" "  ab cd" (Enter_insert Before_cursor :: right 4);
  newline_at "at line end" "\t ab" [ Enter_insert Line_end ];
  newline_at "at line start" "  ab" [ Enter_insert Before_cursor ];
  newline_at "inside the indentation" "    ab" (Enter_insert Before_cursor :: right 1);
  newline_at "unindented" "ab" [ Enter_insert Line_end ];
  newline_at "blank line" "   " [ Enter_insert Line_end ];
  [%expect
    {|
    -- after text
    INSERT 1:2 rev=1 dirty
    > ..ab
    > ..|.cd
    -- at line end
    INSERT 1:2 rev=1 dirty
    > >.ab
    > >.|
    -- at line start
    INSERT 1:0 rev=1 dirty
    >
    > |..ab
    -- inside the indentation
    INSERT 1:1 rev=1 dirty
    > .
    > .|...ab
    -- unindented
    INSERT 1:0 rev=1 dirty
    > ab
    > |
    -- blank line
    INSERT 1:3 rev=1 dirty
    > ...
    > ...|
    |}];
  (* Literal text, e.g. a paste, is not indented. *)
  show_blanks (run (create "  ab") [ Enter_insert Line_end; Insert_text "\nc\n" ]);
  [%expect
    {|
    INSERT 2:0 rev=1 dirty
    > ..ab
    > c
    > |
    |}]
;;

let%expect_test "autoindent with soft tabs, Backspace, undo, and redo" =
  let t =
    run
      (create "  a")
      ([ Enter_insert Line_end; Insert_newline; Insert_soft_tab 2 ] @ typed "b")
  in
  show_blanks t;
  [%expect
    {|
    INSERT 1:5 rev=3 dirty
    > ..a
    > ....b|
    |}];
  let t =
    run
      t
      [ Delete_backward
      ; Delete_soft_tab_backward 2
      ; Delete_soft_tab_backward 2
      ; Delete_soft_tab_backward 2
      ; Exit_insert
      ]
  in
  show_blanks t;
  [%expect
    {|
    NORMAL 0:2 rev=7
    > ..|a
    |}];
  (* The session changed nothing overall, so it left no undo step. *)
  let t = run t [ Undo ] in
  show_blanks t;
  let t = run t [ Redo ] in
  show_blanks t;
  [%expect
    {|
    NORMAL 0:2 rev=7
    > ..|a
    NORMAL 0:2 rev=7
    > ..|a
    |}]
;;

let%expect_test "Insert-entry commands are Normal-only; Insert_newline is Insert-only" =
  let t = run (create "  ab") [ Enter_insert Line_end ] in
  let t' = run t [ Enter_insert First_nonblank; Open_line_below; Open_line_above ] in
  print_s [%sexp (Editor.cursor t' = Editor.cursor t : bool)];
  print_s [%sexp (Text_buffer.equal (Editor.text t') (Editor.text t) : bool)];
  let t = run (create "  ab") [ Insert_newline ] in
  show_blanks t;
  [%expect
    {|
    true
    true
    NORMAL 0:0 rev=0
    > |..ab
    |}]
;;

let%expect_test "%: moves without editing; a failure leaves a message and the cursor" =
  let t = run (create "f (a,\n   b)\nx") [ move Matching_delimiter ] in
  show t;
  let t = run t [ move Matching_delimiter ] in
  show t;
  (* The preferred column is the destination's: Down goes to column 2. *)
  let t = run t [ move Down ] in
  show_position t;
  let t = run t [ move Up; move Line_end; move Matching_delimiter ] in
  show t;
  (* The next command clears the message. *)
  let t = run t [ move Left ] in
  show t;
  print_s [%sexp (undo_steps t : int)];
  [%expect {|
    NORMAL 1:4 rev=0
    > f (a,
    >    b|)
    > x
    NORMAL 0:2 rev=0
    > f |(a,
    >    b)
    > x
    NORMAL 1:2 rev=0
    NORMAL 0:4 rev=0 (Error"No delimiter on this line")
    > f (a|,
    >    b)
    > x
    NORMAL 0:3 rev=0
    > f (|a,
    >    b)
    > x
    0
    |}]
;;

let%expect_test "%: a count is rejected by the editor" =
  Expect_test_helpers_core.require_does_raise (fun () ->
    Editor.dispatch (create "()") (move ~count:50 Matching_delimiter));
  [%expect {| (Invalid_argument "Matching_delimiter takes no count") |}]
;;

let%expect_test "%: an Insert transaction is closed, and a failed % still closes it" =
  let t = run (create "(x)") ([ Enter_insert Line_end ] @ typed "ab" @ [ move Matching_delimiter ]) in
  show t;
  let t = run t (typed "c" @ [ move Matching_delimiter ] @ typed "d" @ [ Exit_insert ]) in
  show t;
  print_s [%sexp (undo_steps t : int)];
  [%expect {|
    INSERT 0:5 rev=2 dirty (Error"No delimiter on this line")
    > (x)ab|
    NORMAL 0:6 rev=4 dirty
    > (x)abc|d
    3
    |}]
;;
