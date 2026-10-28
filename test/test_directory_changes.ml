(* [Session.directory_changes]: the paths directory-buffer saves changed on disk, kept
   out of [Session.saved]. Paths print relative to the fixture as $ROOT; staging names
   as $STAGE. *)

open! Core
open Ches_core
open Ches_app

let width _ = 1
let child = Filename.concat
let exists path = Option.is_some (Option.try_with (fun () -> Core_unix.lstat path))
let rec remove_fixture path =
  if Poly.equal (Core_unix.lstat path).st_kind Core_unix.S_DIR then (
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove_fixture (child path name));
    Core_unix.rmdir path)
  else Core_unix.unlink path
;;
let fixture f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-directory-changes-" in
  Exn.protect ~f:(fun () -> f root) ~finally:(fun () -> remove_fixture root)
;;
let write root name = Out_channel.write_all (child root name) ~data:name
let start root = Session.create ~cell_width:width (Startup.open_path ~cell_width:width root |> Or_error.ok_exn)
let directory t = Session.directory_buffer t |> Option.value_exn
let row (d : Directory_buffer.t) name destination =
  let entry = List.find_exn d.entries ~f:(fun e -> String.equal e.name name) in
  sprintf "@ches[%d]\t%s%s" entry.id destination (if Directory_identity.Kind.equal entry.kind Directory then "/" else "")
let copy_row (d : Directory_buffer.t) name destination =
  let entry = List.find_exn d.entries ~f:(fun e -> String.equal e.name name) in
  sprintf "@copy[%d]\t%s%s" entry.id destination (if Directory_identity.Kind.equal entry.kind Directory then "/" else "")
(* Replace the presented directory's text with [rows]. *)
let edit t rows =
  let d = directory t in
  Session.replace_active t (Controller.rebase_text d.controller ~saved:(Directory_identity.text d.baseline)
    ~text:(Text_buffer.of_string (String.concat ~sep:"\n" (rows d)) |> Result.ok |> Option.value_exn))
;;
let show root t =
  let scrub path =
    let path = String.substr_replace_all path ~pattern:root ~with_:"$ROOT" in
    if String.is_prefix (Filename.basename path) ~prefix:".ches-stage-"
    then Filename.dirname path ^ "/$STAGE" else path in
  print_s [%sexp (List.map (Session.directory_changes t) ~f:scrub : string list)];
  assert (List.is_empty (Session.saved t))
;;

let%expect_test "create, rename, delete: oldest first, both sides of a rename" =
  fixture (fun root ->
    write root "a"; write root "b"; write root "c"; Core_unix.mkdir (child root "dir");
    let t = start root in
    show root t;
    [%expect {| () |}];
    let t = edit t (fun d -> [ row d "a" "renamed"; row d "c" "c"; row d "dir" "dir"; "fresh"; "sub/" ]) |> Session.save_current in
    assert (exists (child root "renamed") && not (exists (child root "b")) && exists (child root "sub"));
    show root t;
    [%expect {| ($ROOT/a $ROOT/renamed $ROOT/b $ROOT/fresh $ROOT/sub) |}];
    (* A directory operation names the directory; a copy only its destination; a
       later save appends. A rename is not relocated afterwards. *)
    let t = edit t (fun d -> [ row d "renamed" "renamed"; copy_row d "renamed" "copy"; row d "c" "c"; row d "dir" "moved"
      ; row d "fresh" "fresh"; row d "sub" "sub" ]) |> Session.save_current in
    assert (exists (child root "copy") && exists (child root "moved"));
    show root t;
    [%expect {|
      ($ROOT/a $ROOT/renamed $ROOT/b $ROOT/fresh $ROOT/sub $ROOT/copy $ROOT/dir
       $ROOT/moved)
      |}];
    let t, taken = Session.take_directory_changes t in
    assert (List.length taken = 8);
    show root t;
    [%expect {| () |}];
    (* Nothing applied (a refused plan), nothing recorded. *)
    let t = edit t (fun d -> [ row d "renamed" "c"; row d "c" "c" ]) |> Session.save_current in
    assert (Directory_buffer.is_dirty (directory t));
    show root t;
    [%expect {| () |}];
    Session.dispose t)
;;

let%expect_test "a partly failed apply lists what happened; the retry and save all record too" =
  fixture (fun root ->
    write root "a"; write root "b";
    let t = start root in
    let id = (directory t).id in
    (* A swap stages both sources, then places them; the second placement fails. *)
    let t = edit t (fun d -> [ row d "a" "b"; row d "b" "a"; "fresh" ]) in
    let t = Session.For_testing.save_directory t id ~before_mutation:(fun step ->
      if step = 4 then failwith "injected final-placement failure") in
    assert (Directory_buffer.is_dirty (directory t) && not (exists (child root "fresh")));
    show root t;
    [%expect {| ($ROOT/a $ROOT/b $ROOT/$STAGE) |}];
    let t, _ = Session.take_directory_changes t in
    let t, results = Session.save_all t in
    assert (List.for_all results ~f:snd);
    assert (String.equal (In_channel.read_all (child root "a")) "b" && exists (child root "fresh"));
    show root t;
    [%expect {| ($ROOT/$STAGE $ROOT/a $ROOT/fresh) |}];
    Session.dispose t)
;;
