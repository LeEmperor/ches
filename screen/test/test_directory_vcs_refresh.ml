(* A directory-buffer save that changes files reaches the VCS view as a [Saved] signal
   ([Session.directory_changes]), so its status follows without [g r]; the paths never
   become [Document_saved] source requests. The editor starts on a directory, the VCS
   view in the split beside it, git run synchronously by [Vcs_driver] in a fixture
   repository. *)

open! Core
open Ches_screen
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 100
let height = 24

(* Where the split view starts at this size: the directory pane, then a gap. *)
let split_column = 51

(* A repository with two committed files, clean. *)
let with_repo f =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "a\n";
    Fixture.write repo "b.txt" "b\n";
    ignore (Fixture.commit_all repo "first" : string);
    f repo)
;;

let create ~cwd directory =
  Ui_state.create
    ~tiles_visible:false
    ~source_attached:true
    ~views:[ Vcs_view.entry ~cwd () ]
    (Ches_app.Startup.open_path ~cell_width:Cell_map.width directory |> Or_error.ok_exn)
;;

(* Keys, then every job the view submits, run to completion. *)
let run repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  let t, jobs = Vcs_driver.settle repo t ~width ~height in
  if not (List.is_empty jobs)
  then printf "jobs: %s\n" (String.concat ~sep:", " (List.map jobs ~f:Vcs_driver.describe));
  t
;;

(* The split view's head and Files panel (its first rows). *)
let show t =
  Frame.to_string (Frame.render t ~width ~height)
  |> String.split_lines
  |> Fn.flip List.take 8
  |> List.iter ~f:(fun line ->
    let rec offset byte column =
      if byte >= String.length line || column = split_column
      then byte
      else (
        let next = ref (byte + 1) in
        while !next < String.length line && Char.to_int line.[!next] land 0xC0 = 0x80 do
          incr next
        done;
        offset !next (column + 1))
    in
    print_endline (String.drop_prefix line (offset 0 0)))
;;

(* The source requests a save would send, by kind: directory changes add none. *)
let requests t =
  let t, requests = Ui_state.take_source_requests t in
  print_s
    [%sexp
      (List.map requests ~f:(fun request ->
         match (request : Ches_error.Source_request.t) with
         | Document_saved { resource; _ } -> "saved " ^ Filename.basename resource
         | _ -> "other")
       : string list)];
  t
;;

let%expect_test "deleting and renaming tracked files in a directory buffer refreshes the view" =
  with_repo (fun repo ->
    let t = create ~cwd:repo.work repo.work in
    let t = run repo t " gs gf" in
    show t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2
      ╭─ VCS: work (main) ────────────────────────────╮|
      │ Head: main 43c6f14                            │|
      │ 1 Files (0)                                   │|
      │   (none)                                      │|
      │                                               │|
      │                                               │|
      │                                               │|
      │                                               │|
      |}];
    let t = requests t in
    [%expect {| () |}];
    (* The rows are .git/, a.txt, b.txt: delete b.txt and save. *)
    let t = run repo t "jjdd w" in
    assert (not (Stdlib.Sys.file_exists (Fixture.path repo "b.txt")));
    show t;
    [%expect {|
      jobs: refresh g1.3, diff g1.4
      ╭─ VCS: work (main) ────────────────────────────╮|
      │ Head: main 43c6f14                            │|
      │ 1 Files (1)                                   │|
      │ > - Unstaged changes (1)                      │|
      │   deleted    b.txt                            │|
      │                                               │|
      │                                               │|
      │                                               │|
      |}];
    let t = requests t in
    [%expect {| () |}];
    let t = run repo t "ggjA.renamed<Esc> w" in
    assert (Stdlib.Sys.file_exists (Fixture.path repo "a.txt.renamed"));
    show t;
    [%expect {|
      jobs: refresh g1.5, diff g1.6
      ╭─ VCS: work (main) ────────────────────────────╮|
      │ Head: main 43c6f14                            │|
      │ 1 Files (3)                                   │|
      │   - Untracked files (1)                       │|
      │   a.txt.renamed                               │|
      │ > - Unstaged changes (2)                      │|
      │   deleted    a.txt                            │|
      │   deleted    b.txt                            │|
      |}];
    let t = requests t in
    [%expect {| () |}];
    ignore (t : Ui_state.t))
;;

let%expect_test "a directory save outside the repository does not refresh it" =
  with_repo (fun repo ->
    let outside = Fixture.plain_dir repo "outside" in
    Out_channel.write_all (outside ^/ "c.txt") ~data:"c\n";
    let t = create ~cwd:repo.work outside in
    let t = run repo t " gs gf" in
    [%expect {| jobs: detect g1.1, refresh g1.2 |}];
    let t = run repo t "dd w" in
    assert (not (Stdlib.Sys.file_exists (outside ^/ "c.txt")));
    [%expect {| |}];
    ignore (t : Ui_state.t))
;;
