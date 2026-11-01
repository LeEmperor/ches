(* The VCS view's footer key hints with hints on ([Ui_state.create ~hotkey_hints:true],
   [Space v ?] in the editor), which every other VCS test leaves off: each list panel
   (each kind of Files selection), the diff (a file's, a commit's, a conflicted
   file's, each in Visual), each popup, the name prompt, the merge and rebase states
   and a directory outside any repository. Hints name only the keys that act where
   the cursor is, with [? help] (which lists them all) first. The frames are 100
   columns wide, and every panel footer must fit whole and name [?]: [footer] flags
   one that does not with [cut] or [no ?]. The last test shows the cut at 80 columns.
   Git runs synchronously through [Vcs_driver] in fixture repositories; paths under
   the fixture print as $DIR. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Fixture = Ches_vcs_fixture.Fixture_repo

let wide = 100
let height = 30
let git ?cwd repo args = ignore (Fixture.git ?cwd repo args : string)
let commit repo message = ignore (Fixture.commit_all repo message : string)

let create ?(file = "a.txt") ?cwd (repo : Fixture.t) =
  let controller =
    Controller.open_file ~cell_width:Cell_map.width (Fixture.path repo file)
    |> Or_error.ok_exn
  in
  Ui_state.create
    ~tiles_visible:false
    ~hotkey_hints:true
    ~views:[ Vcs_view.entry ~cwd:(Option.value cwd ~default:repo.work) () ]
    controller
;;

(* Keys, then every job the view submits, run to completion. *)
let run ?(width = wide) repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  fst (Vcs_driver.settle repo t ~width ~height)
;;

let frame_lines t ~width =
  String.split_lines (Frame.to_string (Frame.render t ~width ~height))
;;

(* The text of [line] from display column [x], [width] columns. *)
let cut line ~x ~width =
  let column = ref 0 in
  Array.fold (Cell_map.glyphs line) ~init:"" ~f:(fun text (glyph : Cell_map.Glyph.t) ->
    let at = !column in
    column := at + glyph.width;
    if at >= x && at < x + width then text ^ glyph.text else text)
;;

(* A bottom border's label: the text between "╰─ " and the padding "───╯". *)
let label border =
  String.chop_prefix_if_exists border ~prefix:"╰─"
  |> String.rstrip ~drop:(fun c -> Char.equal c '|' || Char.is_whitespace c)
  |> String.chop_suffix_if_exists ~suffix:"╯"
  |> fun text ->
  (* Strip the run of '─' (three bytes each) at the end, then the blank before it. *)
  let rec strip text =
    match String.chop_suffix text ~suffix:"─" with
    | Some rest -> strip rest
    | None -> text
  in
  String.strip (strip text)
;;

let bottom_row t ~width (layout : Tile_shell.Layout.t) =
  let outer = layout.outer in
  let line = List.nth_exn (frame_lines t ~width) (outer.y + outer.height - 1) in
  label (cut line ~x:outer.x ~width:outer.width)
;;

(* The view's footer, after the name of what [t] focuses; flagged when it is cut (ends
   in [>]) or does not name [?]. *)
let footer ?(width = wide) name t =
  let layout = Option.value_exn (Ui_state.view_layout t ~width ~height Vcs_view.id) in
  let text = bottom_row t ~width layout in
  let flags =
    List.filter_opt
      [ Option.some_if (String.is_suffix text ~suffix:">") " [cut]"
      ; Option.some_if (not (String.is_substring text ~substring:"? help")) " [no ?]"
      ]
  in
  printf "%s: %s%s\n" name text (String.concat flags)
;;

(* The floating popup's, prompt's or confirmation's title and footer. *)
let float_footer ?(width = wide) t =
  match
    List.find_map
      [ Ui_state.popup_layout; Ui_state.prompt_layout; Ui_state.confirm_layout ]
      ~f:(fun layout -> layout t ~width ~height)
  with
  | None -> print_endline "no float"
  | Some layout ->
    let top =
      cut
        (List.nth_exn (frame_lines t ~width) layout.outer.y)
        ~x:layout.outer.x
        ~width:layout.outer.width
    in
    let title =
      String.chop_prefix_if_exists top ~prefix:"╭─ "
      |> String.split ~on:' '
      |> List.take_while ~f:(fun word -> not (String.is_prefix word ~prefix:"─"))
      |> String.concat ~sep:" "
    in
    printf "%s float: %s\n" title (bottom_row t ~width layout)
;;

(* The popup's row that contains [substring]. *)
let float_row t ~substring =
  let layout = Option.value_exn (Ui_state.popup_layout t ~width:wide ~height) in
  List.find_map_exn (frame_lines t ~width:wide) ~f:(fun line ->
    let text = cut line ~x:layout.outer.x ~width:layout.outer.width in
    Option.some_if (String.is_substring text ~substring) text)
  |> print_endline
;;

(* One commit pushed to [origin/main]; a.txt then changed, b.txt untracked; a branch
   [topic] at HEAD. *)
let with_remote f =
  Fixture.with_repo ~remote:true (fun repo ->
    Fixture.write repo "a.txt" "one\n";
    commit repo "One";
    git repo [ "push"; "-q"; "-u"; "origin"; "main" ];
    git repo [ "branch"; "topic" ];
    Fixture.write repo "a.txt" "one\ntwo\n";
    Fixture.write repo "b.txt" "bee\n";
    f repo)
;;

let%expect_test "the list panels and the diff, normal and Visual" =
  with_remote (fun repo ->
    let t = run repo (create repo) " gg" in
    footer "Files, a header" t;
    let t = run repo t "jjj" in
    footer "Files, a file" t;
    let t = run repo t "2" in
    footer "Branches" t;
    let t = run repo t "3" in
    footer "Commits" t;
    let t = run repo t "1<Tab>" in
    footer "Diff" t;
    let t = run repo t "V" in
    footer "Diff, Visual" t;
    let t = run repo t "<Esc>v" in
    footer "Diff, Visual characterwise" t;
    (* A commit's diff: nothing to stage there. *)
    let t = run repo t "<Esc><Tab>3j<Tab>" in
    footer "Diff, a commit" t;
    let t = run repo t "V" in
    footer "Diff, a commit, Visual" t;
    (* Stage a.txt: the Staged section unstages and discards; S U both act. *)
    let t = run repo t "<Esc><Tab>2j" in
    footer "Branches, a branch" t;
    let t = run repo t "3j" in
    footer "Commits, a commit" t;
    let t = run repo t "1ggjjjs" in
    let t = run repo t "ggjj" in
    footer "Files, the Staged header" t;
    let t = run repo t "j" in
    footer "Files, a staged file" t;
    let t = run repo t "<Tab>" in
    footer "Diff, a staged file" t;
    let t = run repo t "V" in
    footer "Diff, a staged file, Visual" t;
    (* An untracked file's diff is the whole file. *)
    let t = run repo t "<Esc><Tab>ggj<Tab>" in
    footer "Diff, an untracked file" t;
    let t = run repo t "V" in
    footer "Diff, an untracked file, Visual" t);
  [%expect {|
    Files, a header: Files 1/4 | ? help, s x S, Enter fold, Tab diff, c commit, p P pull/push, 2 3 panels, q
    Files, a file: Files 4/4 | ? help, s x S, Tab diff, c commit, p P pull/push, 2 3 panels, q
    Branches: Branches 1/3 | ? help, Enter fold, n new, - previous, 1 3 panels, q
    Commits: Commits 1/2 | ? help, l log, + more, Enter fold, Tab diff, 1 2 panels, q
    Diff: Diff 1-7/7 | ? help, s x hunk, ] [ hunks, e open, v V select, Tab list, q
    Diff, Visual: Diff 1-7/7 | VISUAL LINE | ? help, s x lines, S, y copy, Esc ends, q
    Diff, Visual characterwise: Diff 1-7/7 | VISUAL | ? help, s x lines, S, y copy, Esc ends, q
    Diff, a commit: Diff 1-17/17 | ? help, ] [ hunks, e open, v V select, Tab list, q
    Diff, a commit, Visual: Diff 1-17/17 | VISUAL LINE | ? help, y copy, Esc ends, q
    Branches, a branch: Branches 2/3 | ? help, Enter checkout, n new, - previous, m merge this, 1 3 panels, q
    Commits, a commit: Commits 2/2 | ? help, l log, + more, Tab diff, 1 2 panels, q
    Files, the Staged header: Files 3/4 | ? help, u x S U, Enter fold, Tab diff, c commit, p P pull/push, 2 3 panels, q
    Files, a staged file: Files 4/4 | ? help, u x S U, Tab diff, c commit, p P pull/push, 2 3 panels, q
    Diff, a staged file: Diff 1-7/7 | ? help, u x hunk, ] [ hunks, e open, v V select, Tab list, q
    Diff, a staged file, Visual: Diff 1-7/7 | VISUAL LINE | ? help, u x lines, S U, y copy, Esc ends, q
    Diff, an untracked file: Diff 1-7/7 | ? help, s x file, e open, v V select, Tab list, q
    Diff, an untracked file, Visual: Diff 1-7/7 | VISUAL LINE | ? help, S U, y copy, Esc ends, q
    |}]
;;

let%expect_test "the commit, pull, push, merge and log popups; a pending dash" =
  with_remote (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "c" in
    float_footer t;
    let t = run repo t "-" in
    float_footer t;
    let t = run repo t "<Esc>q" in
    let t = run repo t "p" in
    float_footer t;
    let t = run repo t "q" in
    let t = run repo t "P" in
    float_footer t;
    let t = run repo t "q" in
    (* The merge popup needs a branch selected in Branches: topic. *)
    let t = run repo t "2ggjj" in
    footer "Branches" t;
    let t = run repo t "m" in
    float_footer t;
    (* A popup with switches: [-] waits for one, which then toggles. *)
    let t = run repo t "-" in
    float_footer t;
    let t = run repo t "n" in
    float_footer t;
    float_row t ~substring:"-n";
    let t = run repo t "q" in
    let t = run repo t "l" in
    float_footer t;
    let t = run repo t "q" in
    footer "after q" t);
  [%expect {|
    Commit float: - switch  ? help  q close
    Commit float: Pending: -
    Pull float: - switch  ? help  q close
    Push main float: - switch  ? help  q close
    Branches: Branches 3/3 | ? help, Enter checkout, n new, - previous, m merge this, 1 3 panels, q
    Merge float: - switch  ? help  q close
    Merge float: Pending: -
    Merge float: - switch  ? help  q close
    │ * -n  Always create a merge commit (--no-ff) │
    Log float: - switch  ? help  q close
    after q: Branches 3/3 | ? help, Enter checkout, n new, - previous, m merge this, 1 3 panels, q
    |}]
;;

let%expect_test "the name prompt" =
  with_remote (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "2n" in
    float_footer t;
    let t = run repo t "a..b" in
    float_footer t;
    let t = run repo t "<Esc>" in
    float_footer t;
    footer "after Escape" t);
  [%expect {|
    New branch float: Enter accept | Esc cancel
    New branch float: Enter accept | Esc cancel
    no float
    after Escape: Branches 1/3 | ? help, Enter fold, n new, - previous, 1 3 panels, q
    |}]
;;

(* a.txt conflicts between main ("ours") and other ("theirs"); the editor opens
   notes.txt. *)
let with_merge f =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "notes.txt" "notes\n";
    Fixture.write repo "a.txt" "base\n";
    commit repo "Base";
    git repo [ "switch"; "-q"; "-c"; "other" ];
    Fixture.write repo "a.txt" "theirs\n";
    commit repo "Theirs";
    git repo [ "switch"; "-q"; "main" ];
    Fixture.write repo "a.txt" "ours\n";
    commit repo "Ours";
    f repo)
;;

let%expect_test "a merge stopped on a conflict: the panels, the conflicted diff, the \
                 Resolve and Merging popups"
  =
  with_merge (fun repo ->
    let t = run repo (create ~file:"notes.txt" repo) " gg" in
    let t = run repo t "2ggjj" in
    let t = run repo t "mm" in
    let t = run repo t "1ggj" in
    footer "Files, a conflicted file" t;
    let t = run repo t "k" in
    footer "Files, the Conflicted header" t;
    let t = run repo t "j<Tab>" in
    footer "Diff, a conflicted file" t;
    let t = run repo t "V" in
    footer "Diff, a conflicted file, Visual" t;
    let t = run repo t "<Esc><Tab>2" in
    footer "Branches" t;
    let t = run repo t "3" in
    footer "Commits" t;
    (* Resolve and Merging have no switches: [-] is unbound there and leaves nothing
       pending, so the action key after it runs (Merging's [a] asks first). *)
    let t = run repo t "1ggjx" in
    float_footer t;
    let t = run repo t "-" in
    float_footer t;
    let t = run repo t "<Esc>" in
    float_footer t;
    let t = run repo t "m" in
    float_footer t;
    let t = run repo t "-" in
    float_footer t;
    let t = run repo t "a" in
    float_footer t);
  [%expect {|
    Files, a conflicted file: Files 2/2 | ? help, s resolved, x take a side, Tab diff, m m commit, 2 3 panels, q
    Files, the Conflicted header: Files 1/2 | ? help, s resolved, Enter fold, Tab diff, m m commit, 2 3 panels, q
    Diff, a conflicted file: Diff 1-10/10 | ? help, s resolved, x take a side, e edit, ] [ hunks, Tab list, q
    Diff, a conflicted file, Visual: Diff 1-10/10 | VISUAL LINE | ? help, y copy, Esc ends, q
    Branches: Branches 3/3 | ? help, Enter checkout, n new, - previous, m m commit, 1 3 panels, q
    Commits: Commits 1/3 | ? help, l log, + more, Enter fold, Tab diff, m m commit, 1 2 panels, q
    Resolve a.txt float: ? help  q close
    Resolve a.txt float: - is unbound; ? lists keys
    no float
    Merging float: ? help  q close
    Merging float: - is unbound; ? lists keys
    Abort merge float:
    |}]
;;

(* main and origin/main both change a.txt: a rebase pull stops on it. *)
let with_diverged_rebase f =
  Fixture.with_repo ~remote:true (fun repo ->
    Fixture.write repo "a.txt" "one\n";
    commit repo "One";
    git repo [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = Fixture.plain_dir repo "other" in
    git ~cwd:repo.dir repo [ "clone"; "-q"; Option.value_exn repo.remote; other ];
    Out_channel.write_all (Filename.concat other "a.txt") ~data:"theirs\n";
    git ~cwd:other repo [ "commit"; "-q"; "-am"; "Theirs" ];
    git ~cwd:other repo [ "push"; "-q" ];
    Fixture.write repo "a.txt" "ours\n";
    commit repo "Ours";
    f repo)
;;

let%expect_test "a rebase stopped on a conflict: the panels and the Rebasing popup" =
  with_diverged_rebase (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "p-rp" in
    let t = run repo t "1ggj" in
    footer "Files, a conflicted file" t;
    let t = run repo t "<Tab>" in
    footer "Diff, a conflicted file" t;
    let t = run repo t "<Tab>2" in
    footer "Branches" t;
    let t = run repo t "3" in
    footer "Commits" t;
    let t = run repo t "r" in
    float_footer t;
    let t = run repo t "-" in
    float_footer t;
    let t = run repo t "a" in
    float_footer t);
  [%expect {|
    Files, a conflicted file: Files 2/2 | ? help, s resolved, x take a side, Tab diff, r r continue, 2 3 panels, q
    Diff, a conflicted file: Diff 1-10/10 | ? help, s resolved, x take a side, e edit, ] [ hunks, Tab list, q
    Branches: Branches 1/2 | ? help, Enter fold, n new, - previous, r r continue, 1 3 panels, q
    Commits: Commits 1/3 | ? help, l log, + more, Enter fold, Tab diff, r r continue, 1 2 panels, q
    Rebasing float: ? help  q close
    Rebasing float: - is unbound; ? lists keys
    Abort rebase float:
    |}]
;;

let%expect_test "outside a repository" =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "a\n";
    let t = run repo (create ~cwd:(Fixture.plain_dir repo "elsewhere") repo) " gg" in
    footer "not a repository" t);
  [%expect {| not a repository: ? help, g r retry, @ log, q leave |}]
;;

let%expect_test "at 80 columns the longer footers are cut, after ? help" =
  with_remote (fun repo ->
    let width = 80 in
    let t = run ~width repo (create repo) " gg" in
    footer ~width "Files" t;
    let t = run ~width repo t "2" in
    footer ~width "Branches" t;
    let t = run ~width repo t "3" in
    footer ~width "Commits" t;
    let t = run ~width repo t "1jjj<Tab>" in
    footer ~width "Diff" t;
    let t = run ~width repo t "V" in
    footer ~width "Diff, Visual" t);
  [%expect {|
    Files: Files 1/4 | ? help, s x S, Enter fold, Tab diff, c commit, p P pull/push, > [cut]
    Branches: Branches 1/3 | ? help, Enter fold, n new, - previous, 1 3 panels, q
    Commits: Commits 1/2 | ? help, l log, + more, Enter fold, Tab diff, 1 2 panels, q
    Diff: Diff 1-7/7 | ? help, s x hunk, ] [ hunks, e open, v V select, Tab list, q
    Diff, Visual: Diff 1-7/7 | VISUAL LINE | ? help, s x lines, S, y copy, Esc ends, q
    |}]
;;
