(* Conflict markers: the pure parser ([Conflict]), and the editor's commands and
   motions on them, typed through the default bindings of a headless controller. *)

open! Core
open Ches_core
open Ches_app

let of_string_exn s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

(* Each region, then the lines each side keeps. *)
let show_regions s =
  let text = of_string_exn s in
  match Conflict.regions text with
  | [] -> print_endline "no regions"
  | regions ->
    List.iter regions ~f:(fun region ->
      print_s [%sexp (region : Conflict.Region.t)];
      List.iter Conflict.Side.all ~f:(fun side ->
        printf
          "  %-5s %s\n"
          (Conflict.Side.to_string side)
          (match Conflict.Region.lines region side with
           | None -> "-"
           | Some lines ->
             Sexp.to_string_hum
               [%sexp (List.map lines ~f:(Text_buffer.line_text text) : string list)])))
;;

let plain =
  "a\n<<<<<<< HEAD\nours 1\nours 2\n=======\ntheirs\n>>>>>>> feature\nb\n"
;;

let%expect_test "a plain region, its labels and sides" =
  show_regions plain;
  [%expect
    {|
    ((start 1) (base ()) (separator 4) (stop 6) (upper_label HEAD)
     (base_label "") (lower_label feature))
      upper ("ours 1" "ours 2")
      lower (theirs)
      both  ("ours 1" "ours 2" theirs)
      base  -
    |}]
;;

let diff3 =
  "<<<<<<< HEAD (my branch)\n\
   ours\n\
   ||||||| merged common ancestors\n\
   base\n\
   =======\n\
   theirs\n\
   >>>>>>> 3f2a1b9 (Add the parser)\n"
;;

let%expect_test "a diff3 region; labels keep their spaces" =
  show_regions diff3;
  [%expect
    {|
    ((start 0) (base (2)) (separator 4) (stop 6) (upper_label "HEAD (my branch)")
     (base_label "merged common ancestors")
     (lower_label "3f2a1b9 (Add the parser)"))
      upper (ours)
      lower (theirs)
      both  (ours theirs)
      base  (base)
    |}]
;;

let%expect_test "bare markers have empty labels; sides may be empty" =
  show_regions "<<<<<<<\n|||||||\n=======\n>>>>>>>\n";
  [%expect
    {|
    ((start 0) (base (1)) (separator 2) (stop 3) (upper_label "") (base_label "")
     (lower_label ""))
      upper ()
      lower ()
      both  ()
      base  ()
    |}];
  (* Only the space after the marker is dropped from a label. *)
  show_regions "<<<<<<<  two\n=======\nx\n>>>>>>> \n";
  [%expect
    {|
    ((start 0) (base ()) (separator 1) (stop 3) (upper_label " two")
     (base_label "") (lower_label ""))
      upper ()
      lower (x)
      both  (x)
      base  -
    |}]
;;

let%expect_test "several regions, with marker-like text between them" =
  show_regions
    "<<<<<<< A\n1\n=======\n2\n>>>>>>> B\n=======\n>>>>>>> stray\n<<<<<<< C\n3\n=======\n>>>>>>> D\n";
  [%expect
    {|
    ((start 0) (base ()) (separator 2) (stop 4) (upper_label A) (base_label "")
     (lower_label B))
      upper (1)
      lower (2)
      both  (1 2)
      base  -
    ((start 7) (base ()) (separator 9) (stop 10) (upper_label C) (base_label "")
     (lower_label D))
      upper (3)
      lower ()
      both  (3)
      base  -
    |}]
;;

let%expect_test "a region ending the text, with or without a final LF" =
  show_regions "x\n<<<<<<< u\n1\n=======\n2\n>>>>>>> l";
  show_regions "x\n<<<<<<< u\n1\n=======\n2\n>>>>>>> l\n";
  [%expect
    {|
    ((start 1) (base ()) (separator 3) (stop 5) (upper_label u) (base_label "")
     (lower_label l))
      upper (1)
      lower (2)
      both  (1 2)
      base  -
    ((start 1) (base ()) (separator 3) (stop 5) (upper_label u) (base_label "")
     (lower_label l))
      upper (1)
      lower (2)
      both  (1 2)
      base  -
    |}]
;;

let%expect_test "malformed and unterminated regions are ignored" =
  List.iter
    [ (* Marker size other than 7, or text right after the marker. *)
      "<<<<<<<< u\n1\n=======\n2\n>>>>>>> l\n"
    ; "<<<<<<<u\n1\n=======\n2\n>>>>>>> l\n"
    ; "<<<<<<< u\n1\n======= x\n2\n>>>>>>> l\n"
    ; "<<<<<<< u\n1\n========\n2\n>>>>>>> l\n"
    ; "<<<<<<< u\n1\n=======\n2\n>>>>>>>> l\n"
    ; "<<<<<<< u\n1\n=======\n2\n>>>>>>>l\n"
    ; "<<<<<<< u\n||||||||\n=======\n>>>>>>>>\n"
    ; (* An indented marker is text. *)
      " <<<<<<< u\n1\n=======\n2\n>>>>>>> l\n"
    ; (* Out of order. *)
      "<<<<<<< u\n1\n>>>>>>> l\n=======\n"
    ; "<<<<<<< u\n||||||| b\n||||||| b\n=======\n>>>>>>> l\n"
    ; "<<<<<<< u\n=======\n=======\n>>>>>>> l\n"
    ; "<<<<<<< u\n=======\n||||||| b\n>>>>>>> l\n"
    ; (* Unterminated. *)
      "<<<<<<< u\n1\n=======\n2\n"
    ; "<<<<<<< u\n1\n"
    ; "=======\n>>>>>>> l\n"
    ]
    ~f:show_regions;
  [%expect
    {|
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    no regions
    |}]
;;

let%expect_test "a start line before the end restarts the region" =
  show_regions "<<<<<<< old\n1\n=======\n<<<<<<< new\n2\n=======\n3\n>>>>>>> l\n";
  [%expect
    {|
    ((start 3) (base ()) (separator 5) (stop 7) (upper_label new) (base_label "")
     (lower_label l))
      upper (2)
      lower (3)
      both  (2 3)
      base  -
    |}]
;;

let%expect_test "region_at covers the markers and nothing outside them" =
  let text = of_string_exn plain in
  List.init (Text_buffer.line_count text) ~f:(fun line ->
    Option.map (Conflict.region_at text ~line) ~f:(fun region -> region.start))
  |> [%sexp_of: int option list]
  |> print_s;
  [%expect {| (() (1) (1) (1) (1) (1) (1) () ()) |}]
;;

let%expect_test "CRLF text never reaches the parser: the buffer rejects CR" =
  print_s
    [%sexp
      (Text_buffer.of_string "<<<<<<< HEAD\r\n" |> Result.is_error : bool)];
  [%expect {| true |}]
;;

(* A headless controller over [s] with the default bindings, at line [line]. *)
let create ?(line = 0) s =
  let editor = Editor.create ~path:"f.txt" ~cell_width:Cell_width.f (of_string_exn s) in
  let editor = Editor.go_to_display_position editor ~line:(line + 1) ~column:1 |> Or_error.ok_exn in
  Controller.create editor
;;

let run t keys =
  List.fold (Key_notation.keys keys) ~init:t ~f:(fun t input ->
    let t, views, _ = Controller.handle_input t input in
    List.iter views ~f:(fun view -> print_s [%sexp View (view : Ches_input.View_command.t)]);
    t)
;;

(* Mode, zero-based line:column, dirty flag, pending keys, keymap notice and editor
   message. *)
let show_position t =
  let editor = Controller.editor t in
  let keymap = Controller.keymap t in
  printf
    "%s %d:%d%s%s%s%s\n"
    (Mode.to_string (Editor.mode editor))
    (Editor.cursor_line editor)
    (Editor.cursor_column editor)
    (if Editor.is_dirty editor then " dirty" else "")
    (match Ches_input.Keymap.pending keymap with
     | None -> ""
     | Some pending -> sprintf " pending=%S" pending)
    (match Ches_input.Keymap.notice keymap with
     | None -> ""
     | Some notice -> sprintf " notice=%S" notice)
    (match Editor.message editor with
     | None -> ""
     | Some message -> " " ^ Sexp.to_string [%sexp (message : Editor.Message.t)])
;;

(* [show_position], then the text with [|] at the cursor. *)
let show t =
  show_position t;
  let editor = Controller.editor t in
  let text = Text_buffer.to_string (Editor.text editor) in
  let cursor = Editor.cursor editor in
  String.prefix text cursor ^ "|" ^ String.drop_prefix text cursor
  |> String.split ~on:'\n'
  |> List.iter ~f:(fun line -> print_endline ("> " ^ line))
;;

let%expect_test "Space x u keeps the upper side as one undo step, unsaved" =
  let t = run (create ~line:2 plain) " xu" in
  show t;
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept upper (HEAD)")
    > a
    > |ours 1
    > ours 2
    > b
    >
    |}];
  print_s [%sexp (snd (Controller.take_saved t) : Controller.Saved.t option)];
  [%expect {| () |}];
  let t = run t "u" in
  show t;
  [%expect
    {|
    NORMAL 2:0
    > a
    > <<<<<<< HEAD
    > |ours 1
    > ours 2
    > =======
    > theirs
    > >>>>>>> feature
    > b
    >
    |}];
  show (run t "<C-r>");
  [%expect
    {|
    NORMAL 1:0 dirty
    > a
    > |ours 1
    > ours 2
    > b
    >
    |}]
;;

let%expect_test "Space x l and Space x a keep the lower side and both, from any line of the region" =
  (* From the end marker, and from the start marker. *)
  let t = run (create ~line:6 plain) " xl" in
  show t;
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept lower (feature)")
    > a
    > |theirs
    > b
    >
    |}];
  let t = run (create ~line:1 plain) " xa" in
  show t;
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept both (HEAD, feature)")
    > a
    > |ours 1
    > ours 2
    > theirs
    > b
    >
    |}];
  show (run t "u");
  [%expect
    {|
    NORMAL 1:0
    > a
    > |<<<<<<< HEAD
    > ours 1
    > ours 2
    > =======
    > theirs
    > >>>>>>> feature
    > b
    >
    |}]
;;

let%expect_test "Space x b keeps the base part of a diff3 region" =
  let t = run (create ~line:3 diff3) " xb" in
  show t;
  [%expect
    {|
    NORMAL 0:0 dirty (Info"Kept base (merged common ancestors)")
    > |base
    >
    |}];
  show (run t "u");
  [%expect
    {|
    NORMAL 3:0
    > <<<<<<< HEAD (my branch)
    > ours
    > ||||||| merged common ancestors
    > |base
    > =======
    > theirs
    > >>>>>>> 3f2a1b9 (Add the parser)
    >
    |}];
  (* Both keeps the upper and lower sides, never the base. *)
  show (run (create diff3) " xa");
  [%expect
    {|
    NORMAL 0:0 dirty (Info"Kept both (HEAD (my branch), 3f2a1b9 (Add the parser))")
    > |ours
    > theirs
    >
    |}]
;;

let%expect_test "refusals change nothing" =
  (* Base of a region without one. *)
  show (run (create ~line:2 plain) " xb");
  [%expect
    {|
    NORMAL 2:0 (Error"This conflict has no base part (merge.conflictStyle=diff3 shows one)")
    > a
    > <<<<<<< HEAD
    > |ours 1
    > ours 2
    > =======
    > theirs
    > >>>>>>> feature
    > b
    >
    |}];
  (* Outside any region, before and after it. *)
  let t = run (create plain) " xu" in
  show_position t;
  let t = run (create ~line:7 plain) " xl" in
  show_position t;
  [%expect
    {|
    NORMAL 0:0 (Error"No conflict at the cursor")
    NORMAL 7:0 (Error"No conflict at the cursor")
    |}];
  (* Nothing to undo afterwards. *)
  show_position (run t "u");
  [%expect {| NORMAL 7:0 (Info"Already at oldest change") |}];
  (* A malformed region is no region. *)
  show_position (run (create ~line:1 "<<<<<<< u\n1\n>>>>>>> l\n") " xu");
  [%expect {| NORMAL 1:0 (Error"No conflict at the cursor") |}]
;;

let%expect_test "Space x does nothing outside Normal mode" =
  (* Visual: the command does not apply; the selection stays. *)
  show (run (create ~line:2 plain) "v xu");
  [%expect
    {|
    VISUAL 2:0
    > a
    > <<<<<<< HEAD
    > |ours 1
    > ours 2
    > =======
    > theirs
    > >>>>>>> feature
    > b
    >
    |}];
  (* Insert: the keys are text. *)
  show_position (run (create ~line:2 plain) "i xu");
  [%expect {| INSERT 2:3 dirty |}]
;;

let%expect_test "empty sides and regions at the end of the text" =
  (* Nothing kept: the cursor goes to the line that took the region's place. *)
  show (run (create ~line:1 "a\n<<<<<<< u\n=======\nx\n>>>>>>> l\nb\n") " xu");
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept upper (u)")
    > a
    > |b
    >
    |}];
  (* At the end without a final LF, none is added... *)
  show (run (create ~line:1 "a\n<<<<<<< u\n1\n2\n=======\n>>>>>>> l") " xu");
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept upper (u)")
    > a
    > |1
    > 2
    |}];
  (* ...nor kept when there was one. *)
  show (run (create ~line:1 "a\n<<<<<<< u\n1\n=======\n>>>>>>> l\n") " xu");
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept upper (u)")
    > a
    > |1
    >
    |}];
  (* Nothing kept at the end: the cursor is on the empty last line. *)
  let t = run (create ~line:1 "a\n<<<<<<<\n=======\n>>>>>>>") " xa" in
  show t;
  [%expect
    {|
    NORMAL 1:0 dirty (Info"Kept both")
    > a
    > |
    |}];
  show (run t "u");
  [%expect
    {|
    NORMAL 1:0
    > a
    > |<<<<<<<
    > =======
    > >>>>>>>
    |}]
;;

let%expect_test "only the region at the cursor changes" =
  let text = "<<<<<<< A\n1\n=======\n2\n>>>>>>> B\nmid\n<<<<<<< C\n3\n=======\n4\n>>>>>>> D\n" in
  show (run (create ~line:7 text) " xl");
  [%expect
    {|
    NORMAL 6:0 dirty (Info"Kept lower (D)")
    > <<<<<<< A
    > 1
    > =======
    > 2
    > >>>>>>> B
    > mid
    > |4
    >
    |}]
;;

let several =
  "top\n\
   <<<<<<< A\n\
   1\n\
   =======\n\
   2\n\
   >>>>>>> B\n\
   <<<<<<< broken\n\
   >>>>>>> broken\n\
   <<<<<<< C\n\
   3\n\
   =======\n\
   >>>>>>> D\n\
   <<<<<<< E\n\
   =======\n\
   >>>>>>> F\n\
   bottom\n"
;;

let%expect_test "] n and [ n jump between region start lines, with counts" =
  let t = run (create several) "]n" in
  show_position t;
  let t = run t "]n" in
  show_position t;
  let t = run t "]n" in
  show_position t;
  [%expect
    {|
    NORMAL 1:0
    NORMAL 8:0
    NORMAL 12:0
    |}];
  (* None left: the cursor stays, as after a failed search. *)
  let t = run t "]n" in
  show_position t;
  [%expect {| NORMAL 12:0 (Error"No more conflicts") |}];
  let t = run t "2[n" in
  show_position t;
  [%expect {| NORMAL 1:0 |}];
  let t = run t "[n" in
  show_position t;
  [%expect {| NORMAL 1:0 (Error"No more conflicts") |}];
  (* A count past the last goes to the last; a huge one is bounded by the regions. *)
  show_position (run (create several) "9]n");
  show_position (run (create ~line:15 several) "999999[n");
  show_position (run (create several) "2]n");
  [%expect
    {|
    NORMAL 12:0
    NORMAL 1:0
    NORMAL 8:0
    |}];
  (* From inside a region, [ n goes to its own start; ] n to the next one. *)
  show_position (run (create ~line:10 several) "[n");
  show_position (run (create ~line:10 several) "]n");
  [%expect
    {|
    NORMAL 8:0
    NORMAL 12:0
    |}];
  (* No regions at all. *)
  show_position (run (create "a\nb\n") "]n");
  [%expect {| NORMAL 0:0 (Error"No more conflicts") |}];
  (* The pending prefix is shown, and the motion changes no text. *)
  let t = run (create several) "3]" in
  show_position t;
  [%expect {| NORMAL 0:0 pending="3 ]" |}];
  show_position (run t "n");
  [%expect {| NORMAL 12:0 |}]
;;

let%expect_test "the jumps extend a Visual selection and serve as linewise operator motions" =
  let text = "a\nb\n<<<<<<< u\n1\n=======\n2\n>>>>>>> l\nc\n" in
  let t = run (create text) "v]n" in
  show_position t;
  print_s [%sexp (Editor.selection (Controller.editor t) : Editor.Selection.t option)];
  [%expect
    {|
    VISUAL 2:0
    (((anchor 0) (active 4) (kind Characterwise)))
    |}];
  (* [d ] n] deletes whole lines, from the cursor's through the start line. *)
  show (run (create text) "d]n");
  [%expect
    {|
    NORMAL 0:0 dirty
    > |1
    > =======
    > 2
    > >>>>>>> l
    > c
    >
    |}];
  (* A failed one deletes nothing. *)
  show_position (run (create ~line:7 text) "d]n");
  [%expect {| NORMAL 7:0 (Error"No more conflicts") |}]
;;

(* Random edits of marker-rich text keep the cursor valid, and undoing them all
   restores the text. *)
let%test_unit "random conflict commands keep the cursor valid; undo round-trips" =
  let gen_text =
    Quickcheck.Generator.(
      list
        (of_list
           [ "a\n"; "b"; "\n"; "<<<<<<< u\n"; "|||||||\n"; "=======\n"; ">>>>>>> l\n"
           ; ">>>>>>>"; "<<<<<<<"; "日\n"
           ])
      |> map ~f:String.concat)
  in
  let gen_command =
    Quickcheck.Generator.of_list
      (List.map Conflict.Side.all ~f:(fun side -> Command.Keep_conflict side)
       @ List.concat_map [ Motion.Next_conflict; Previous_conflict; Down; Up ] ~f:(fun motion ->
         [ Command.Move { motion; count = None }; Move { motion; count = Some 2 } ])
       @ [ Command.Undo; Redo ])
  in
  Quickcheck.test
    (Quickcheck.Generator.both gen_text (Quickcheck.Generator.list gen_command))
    ~sexp_of:[%sexp_of: string * Command.t list]
    ~f:(fun (initial, commands) ->
      let check t =
        let text = Editor.text t and cursor = Editor.cursor t in
        let line = Text_buffer.line_of_offset text cursor in
        let start = Text_buffer.line_start text line
        and stop = Text_buffer.line_end text line in
        assert (Text_buffer.is_boundary text cursor);
        assert (cursor < stop || (start = stop && cursor = start))
      in
      let t =
        List.fold
          commands
          ~init:(Editor.create ~cell_width:Cell_width.f (of_string_exn initial))
          ~f:(fun t command ->
            let t, effects = Editor.dispatch t command in
            assert (List.is_empty effects);
            check t;
            t)
      in
      let rec undo_all t =
        match Editor.dispatch t Undo with
        | t, _ when Option.is_some (Editor.message t) -> t
        | t, _ -> undo_all t
      in
      let t = undo_all t in
      check t;
      [%test_result: string] (Text_buffer.to_string (Editor.text t)) ~expect:initial)
;;
