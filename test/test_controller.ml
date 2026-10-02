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
  match Controller.open_file path with
  | Ok t -> Some t
  | Error error ->
    print_endline (hide_dir ~dir (Error.to_string_hum error));
    None
;;

(* Feed keys, reporting an exit request. *)
let run t keys =
  List.fold (Key_notation.keys keys) ~init:t ~f:(fun t input ->
    let t, status = Controller.handle_input t input in
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
  let t = Controller.create (Editor.create ~path:"f.txt" Text_buffer.empty) in
  print_s [%sexp (Controller.last_input_dispatched t : bool)];
  ignore
    (List.fold [ "z"; " "; "x"; "u"; "<C-c>"; "i" ] ~init:t ~f:(fun t keys ->
       match Key_notation.keys keys with
       | [ input ] ->
         let t, (_ : Controller.Status.t) = Controller.handle_input t input in
         printf "%S %b\n" keys (Controller.last_input_dispatched t);
         t
       | _ -> assert false)
     : Controller.t);
  [%expect
    {|
    false
    "z" false
    " " false
    "x" false
    "u" true
    "<C-c>" false
    "i" true
    |}]
;;
