(* Integration tests: the controller with real files in a temporary directory. Paths
   in output are shown relative to that directory, as [$TMP]. *)

open! Core
open Ches_core
open Ches_app

let with_temp_dir f =
  let dir =
    Core_unix.mkdtemp
      (Filename.concat (Option.value (Sys.getenv "TMPDIR") ~default:"/tmp") "ches-test")
  in
  Exn.protect
    ~f:(fun () -> f dir)
    ~finally:(fun () ->
      ignore (Core_unix.system (sprintf "rm -rf %s" (Filename.quote dir)) : _ Result.t))
;;

let hide_dir ~dir s = String.substr_replace_all s ~pattern:dir ~with_:"$TMP"

let print_file ~dir path =
  match In_channel.read_all path with
  | exception _ -> printf "%s: <missing>\n" (hide_dir ~dir path)
  | contents ->
    print_endline
      (Sexp.to_string [%sexp (hide_dir ~dir path : string), (contents : string)])
;;

let open_file ~dir path =
  match Controller.open_file ~cell_width:Cell_width.f path with
  | Ok t -> Some t
  | Error error ->
    print_endline (hide_dir ~dir (Error.to_string_hum error));
    None
;;

(* Feed keys, reporting an exit request. *)
let run t keys =
  List.fold (Key_notation.keys keys) ~init:t ~f:(fun t input ->
    let t, views, status = Controller.handle_input t input in
    List.iter views ~f:(fun view -> print_s [%sexp View (view : Ches_input.View_command.t)]);
    (match status with
     | Exit -> print_endline "EXIT"
     | Running -> ());
    t)
;;

(* Mode, dirty flag, and editor message; then the text. *)
let show ~dir t =
  let editor = Controller.editor t in
  printf
    "%s%s%s\n"
    (Mode.to_string (Editor.mode editor))
    (if Editor.is_dirty editor then " dirty" else "")
    (match Editor.message editor with
     | None -> ""
     | Some (Info s) -> " info: " ^ hide_dir ~dir s
     | Some (Error s) -> " error: " ^ hide_dir ~dir s);
  print_endline (Sexp.to_string [%sexp (Text_buffer.to_string (Editor.text editor) : string)])
;;

let%expect_test "load, edit, save, and reload" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "a.txt" in
    Out_channel.write_all path ~data:"hello\nworld\n";
    let t = Option.value_exn (open_file ~dir path) in
    show ~dir t;
    [%expect
      {|
      NORMAL
      "hello\nworld\n"
      |}];
    let t = run t "x" in
    show ~dir t;
    [%expect
      {|
      NORMAL dirty
      "ello\nworld\n"
      |}];
    let t = run t " w" in
    show ~dir t;
    print_file ~dir path;
    [%expect
      {|
      NORMAL info: Wrote $TMP/a.txt (11 bytes)
      "ello\nworld\n"
      ($TMP/a.txt"ello\nworld\n")
      |}];
    let (_ : Controller.t) = run t " q" in
    [%expect {| EXIT |}];
    let t = Option.value_exn (open_file ~dir path) in
    show ~dir t;
    [%expect
      {|
      NORMAL
      "ello\nworld\n"
      |}])
;;

let%expect_test "colon e! discards buffer changes and reloads the file" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "reload.txt" in
    Out_channel.write_all path ~data:"on disk\n";
    let t = Option.value_exn (open_file ~dir path) in
    let t = run t "iunsaved <Esc>:e!<CR>" in
    show ~dir t;
    [%expect {|
      NORMAL info: Reloaded $TMP/reload.txt
      "on disk\n"
      |}])
;;

let%expect_test "colon e! keeps the cursor's line and column, clamped to the new text" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "reload.txt" in
    let print_cursor t =
      let editor = Controller.editor t in
      let text = Editor.text editor in
      let line = Editor.cursor_line editor in
      printf "line %d, column %d\n" line (Editor.cursor editor - Text_buffer.line_start text line)
    in
    Out_channel.write_all path ~data:"one\ntwo\nthree\nfour\n";
    let t = Option.value_exn (open_file ~dir path) in
    let t = run t "jjll" in
    print_cursor t;
    [%expect {| line 2, column 2 |}];
    Out_channel.write_all path ~data:"ONE\nTWO\nTHREE!\nFOUR\n";
    let t = run t ":e!<CR>" in
    print_cursor t;
    [%expect {| line 2, column 2 |}];
    Out_channel.write_all path ~data:"a\nb";
    let t = run t ":e!<CR>" in
    print_cursor t;
    [%expect {| line 1, column 0 |}])
;;

let%expect_test "a missing file starts clean and empty, and saving creates it" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "new.txt" in
    let t = Option.value_exn (open_file ~dir path) in
    show ~dir t;
    print_file ~dir path;
    [%expect
      {|
      NORMAL
      ""
      $TMP/new.txt: <missing>
      |}];
    let (_ : Controller.t) = run t " w" in
    print_file ~dir path;
    [%expect {| ($TMP/new.txt"") |}])
;;

let%expect_test "text is saved byte for byte, with or without a final newline" =
  with_temp_dir (fun dir ->
    List.iter
      [ "no-newline.txt", "tab\there\nnaïve"
      ; "newline.txt", "tab\there\nnaïve\n"
      ; "blank-lines.txt", "\n\n"
      ]
      ~f:(fun (name, data) ->
        let path = dir ^/ name in
        Out_channel.write_all path ~data;
        let t = Option.value_exn (open_file ~dir path) in
        (* Save unchanged, then after an edit. *)
        let t = run t " w" in
        print_s [%sexp (String.equal (In_channel.read_all path) data : bool)];
        let (_ : Controller.t) = run t "ia<Esc> w" in
        print_file ~dir path));
  [%expect
    {|
    true
    ($TMP/no-newline.txt"atab\there\nna\195\175ve")
    true
    ($TMP/newline.txt"atab\there\nna\195\175ve\n")
    true
    ($TMP/blank-lines.txt"a\n\n")
    |}]
;;

let%expect_test "saving keeps an existing file's permissions" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "private.txt" in
    Out_channel.write_all path ~data:"secret";
    Core_unix.chmod path ~perm:0o600;
    let (_ : Controller.t) = run (Option.value_exn (open_file ~dir path)) "x w" in
    printf "%o\n" (Core_unix.stat path).st_perm;
    print_file ~dir path);
  [%expect
    {|
    600
    ($TMP/private.txt ecret)
    |}]
;;

let%expect_test "files that are not valid text are rejected" =
  with_temp_dir (fun dir ->
    List.iter
      [ "utf8.txt", "ok\xff"; "nul.txt", "a\000b"; "crlf.txt", "a\r\nb"; "cr.txt", "a\rb" ]
      ~f:(fun (name, data) ->
        let path = dir ^/ name in
        Out_channel.write_all path ~data;
        ignore (open_file ~dir path : Controller.t option)));
  [%expect
    {|
    Cannot open $TMP/utf8.txt: invalid UTF-8 at byte offset 2
    Cannot open $TMP/nul.txt: NUL byte at byte offset 1
    Cannot open $TMP/crlf.txt: CRLF line ending (only LF line endings are supported) at byte offset 1
    Cannot open $TMP/cr.txt: carriage return (only LF line endings are supported) at byte offset 1
    |}]
;;

let%expect_test "read failures other than a missing file are errors" =
  with_temp_dir (fun dir ->
    let file = dir ^/ "file" in
    Out_channel.write_all file ~data:"";
    let fifo = dir ^/ "fifo" in
    Core_unix.mkfifo fifo ~perm:0o600;
    List.iter [ dir; file ^/ "child"; fifo ] ~f:(fun path ->
      ignore (open_file ~dir path : Controller.t option)));
  [%expect
    {|
    Cannot open $TMP: is a directory
    Cannot open $TMP/file/child: Not a directory
    Cannot open $TMP/fifo: is not a regular file
    |}]
;;

let%expect_test "a failed write keeps the document dirty and reports why" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "missing-dir" ^/ "f.txt" in
    let t = Option.value_exn (open_file ~dir path) in
    let t = run t "ihi<Esc> w" in
    show ~dir t;
    [%expect
      {|
      NORMAL dirty error: Failed to write $TMP/missing-dir/f.txt: No such file or directory
      hi
      |}];
    (* Quitting is still refused; forcing it writes nothing. *)
    let t = run t " q" in
    show ~dir t;
    [%expect
      {|
      NORMAL dirty error: Unsaved changes: save them or force quit
      hi
      |}];
    let (_ : Controller.t) = run t " Q" in
    print_file ~dir path;
    [%expect
      {|
      EXIT
      $TMP/missing-dir/f.txt: <missing>
      |}];
    (* A path that became a directory after opening. *)
    let path = dir ^/ "later-a-dir" in
    let t = Option.value_exn (open_file ~dir path) in
    Core_unix.mkdir path;
    let t = run t " w" in
    show ~dir t;
    [%expect
      {|
      NORMAL error: Failed to write $TMP/later-a-dir: Is a directory
      ""
      |}])
;;

let%expect_test "dirty quit is refused and forced quit leaves the file untouched" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "a.txt" in
    Out_channel.write_all path ~data:"abc\n";
    let t = run (Option.value_exn (open_file ~dir path)) "x q" in
    show ~dir t;
    print_file ~dir path;
    [%expect
      {|
      NORMAL dirty error: Unsaved changes: save them or force quit
      "bc\n"
      ($TMP/a.txt"abc\n")
      |}];
    (* Inputs after an exit request are not the controller's concern; the frontend
       stops feeding them. *)
    let (_ : Controller.t) = run t " Q" in
    print_file ~dir path;
    [%expect
      {|
      EXIT
      ($TMP/a.txt"abc\n")
      |}];
    (* Undoing back to the saved text makes quitting allowed again. *)
    let (_ : Controller.t) = run t "u q" in
    [%expect {| EXIT |}])
;;

let%expect_test "last_input_dispatched reports whether an input ran any command" =
  let t = Controller.create (Editor.create ~path:"f.txt" ~cell_width:Cell_width.f Text_buffer.empty) in
  print_s [%sexp (Controller.last_input_dispatched t : bool)];
  ignore
    (List.fold [ "q"; " "; "x"; "u"; "<C-c>"; "i" ] ~init:t ~f:(fun t keys ->
       match Key_notation.keys keys with
       | [ input ] ->
         let t, (_ : Ches_input.View_command.t list), (_ : Controller.Status.t) =
           Controller.handle_input t input
         in
         printf "%S %b\n" keys (Controller.last_input_dispatched t);
         t
       | _ -> assert false)
     : Controller.t);
  [%expect
    {|
    false
    "q" false
    " " false
    "x" false
    "u" true
    "<C-c>" false
    "i" true
    |}]
;;

let%expect_test "view commands are returned for the frontend and touch no editor state" =
  let t = Controller.create (Editor.create ~path:"f.txt" ~cell_width:Cell_width.f Text_buffer.empty) in
  let before = Controller.editor t in
  let t = run t " vL vc vr" in
  [%expect {|
    (View (Shift 10))
    (View Toggle_centered)
    (View Reset)
    |}];
  print_s
    [%message
      (phys_equal before (Controller.editor t) : bool)
        (Controller.last_input_dispatched t : bool)
        (Ches_input.Keymap.pending (Controller.keymap t) : string option)];
  [%expect {|
    (("phys_equal before (Controller.editor t)" true)
     ("Controller.last_input_dispatched t" false)
     ("Ches_input.Keymap.pending (Controller.keymap t)" ()))
    |}]
;;

let%expect_test "the newest clipboard request is kept until taken" =
  let t = Controller.create (Editor.create ~cell_width:Cell_width.f Text_buffer.empty) in
  let t = run t "ione<CR>two<Esc>kyyj" in
  let t, text = Controller.take_clipboard t in
  print_s [%sexp (text : string option)];
  let t = run t "k" in
  let _, text = Controller.take_clipboard t in
  print_s [%sexp (text : string option)];
  [%expect {|
    ("one\n")
    ()
    |}]
;;

(* Everything a frontend can observe after a step, including the file on disk. *)
let observe ~path (t, views, (status : Controller.Status.t)) =
  let t, clipboard = Controller.take_clipboard t in
  let t, saved = Controller.take_saved t in
  let editor = Controller.editor t in
  [%sexp
    { text : string = Text_buffer.to_string (Editor.text editor)
    ; mode : string = Mode.to_string (Editor.mode editor)
    ; dirty : bool = Editor.is_dirty editor
    ; message : Editor.Message.t option = Editor.message editor
    ; feedback : Ches_error.Error.t = Controller.feedback t
    ; dispatched : bool = Controller.last_input_dispatched t
    ; pending : string option = Ches_input.Keymap.pending (Controller.keymap t)
    ; views : Ches_input.View_command.t list = views
    ; status : Controller.Status.t
    ; clipboard : string option
    ; saved : Controller.Saved.t option
    ; file : string = In_channel.read_all path
    }]
;;

(* Feeds [keys] one input at a time, collecting their view commands. *)
let keyed t keys =
  List.fold
    (Key_notation.keys keys)
    ~init:(t, [], Controller.Status.Running)
    ~f:(fun (t, views, _) input ->
      let t, more, status = Controller.handle_input t input in
      t, views @ more, status)
;;

let%expect_test "dispatching an action matches typing its binding" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "a.txt" in
    let start () =
      Out_channel.write_all path ~data:"abc\n";
      run (Option.value_exn (open_file ~dir path)) "x"
    in
    List.iter
      Ches_input.Keymap.Action.
        [ " w", [ Editor Save ]
        ; "u", [ Editor Undo ]
        ; "u<C-r>", [ Editor Undo; Editor Redo ]
        ; "yy", [ Editor (Yank_lines 1) ]
        ; " q", [ Editor Quit ]
        ; " Q", [ Editor Force_quit ]
        ; " vN", [ View Toggle_relative_numbers ]
        ]
      ~f:(fun (keys, actions) ->
        let by_key = observe ~path (keyed (start ()) keys) in
        let by_dispatch = observe ~path (Controller.dispatch (start ()) actions) in
        if Sexp.equal by_key by_dispatch
        then printf "%-7S same\n" keys
        else
          print_s
            [%message
              "differs" (keys : string) (by_key : Sexp.t) (by_dispatch : Sexp.t)]));
  [%expect
    {|
    " w"    same
    "u"     same
    "u<C-r>" same
    "yy"    same
    " q"    same
    " Q"    same
    " vN"   same
    |}]
;;

let%expect_test "a dispatched save keeps its failure until a matching save recovers" =
  with_temp_dir (fun dir ->
    let path = dir ^/ "later" ^/ "f.txt" in
    let t = Option.value_exn (open_file ~dir path) in
    let t = run t "ihi<Esc>" in
    let problems t =
      List.iter (Ches_error.Error.problems (Controller.feedback t)) ~f:(fun problem ->
        print_endline (hide_dir ~dir (Sexp.to_string [%sexp (problem : Ches_error.Error.Problem.t)])))
    in
    let save t =
      let t, (_ : Ches_input.View_command.t list), (_ : Controller.Status.t) =
        Controller.dispatch t [ Editor Save ]
      in
      t
    in
    let t = save t in
    show ~dir t;
    problems t;
    [%expect
      {|
      NORMAL dirty error: Failed to write $TMP/later/f.txt: No such file or directory
      hi
      ((identity((source file)(kind Save)(resource $TMP/later/f.txt)))(severity Error)(text"Failed to write $TMP/later/f.txt: No such file or directory")(attention true)(location()))
      |}];
    (* Another command keeps the problem. Dispatching what idle Escape dispatches does not
       acknowledge it either: only the key does. *)
    let t, (_ : Ches_input.View_command.t list), (_ : Controller.Status.t) =
      Controller.dispatch t [ Editor Clear_search_highlight ]
    in
    problems t;
    [%expect
      {| ((identity((source file)(kind Save)(resource $TMP/later/f.txt)))(severity Error)(text"Failed to write $TMP/later/f.txt: No such file or directory")(attention true)(location())) |}];
    Core_unix.mkdir (dir ^/ "later");
    let t = save t in
    show ~dir t;
    problems t;
    print_file ~dir path;
    [%expect
      {|
      NORMAL info: Wrote $TMP/later/f.txt (2 bytes)
      hi
      ($TMP/later/f.txt hi)
      |}])
;;

let%expect_test "dispatch stops at Exit and leaves the keymap alone" =
  let t =
    Controller.create (Editor.create ~path:"f.txt" ~cell_width:Cell_width.f Text_buffer.empty)
  in
  let t = run t " " in
  let print (t, views, status) =
    print_s
      [%message
        ""
          (views : Ches_input.View_command.t list)
          (status : Controller.Status.t)
          (Controller.last_input_dispatched t : bool)
          (Ches_input.Keymap.pending (Controller.keymap t) : string option)];
    t
  in
  let t = print (Controller.dispatch t [ View Toggle_centered ]) in
  [%expect
    {|
    ((views (Toggle_centered)) (status Running)
     ("Controller.last_input_dispatched t" false)
     ("Ches_input.Keymap.pending (Controller.keymap t)" (Space)))
    |}];
  let (_ : Controller.t) =
    print (Controller.dispatch t [ View Reset; Editor Force_quit; View Toggle_centered ])
  in
  [%expect
    {|
    ((views (Reset)) (status Exit) ("Controller.last_input_dispatched t" true)
     ("Ches_input.Keymap.pending (Controller.keymap t)" (Space)))
    |}]
;;
