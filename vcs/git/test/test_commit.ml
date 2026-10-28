(* Commits (phase 5): the popup, the refusals, the message template and summary as pure
   functions; then prepare/prepared and the Finish_commit and Extend plans against real
   fixture repositories, with the message file written the way the view writes it (the
   user's text, then Commit.template). Commands print without Cli.prefix; paths under the
   fixture's temp directory print as $DIR. *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend
module Commit = Ches_vcs_git.Commit
module Status = Ches_vcs_git.Status

let relative (t : Fixture.t) text =
  String.substr_replace_all text ~pattern:t.dir ~with_:"$DIR"
;;

let git t args = ignore (Fixture.git t args : string)
let commit t message = ignore (Fixture.commit_all t message : string)

(* Pure: statuses built by hand. *)

let oid = "0123456789abcdef0123456789abcdef01234567"

let status ?(oid = Some oid) ?(head = Some "main") entries : Status.t =
  { branch = { oid; head; upstream = None; ahead_behind = None }
  ; entries
  ; truncated = false
  }
;;

let changed
  ?(index : Status.Change.t = Unmodified)
  ?(worktree : Status.Change.t = Unmodified)
  path
  : Status.Entry.t
  =
  Changed
    { index
    ; worktree
    ; submodule = None
    ; head_mode = "100644"
    ; index_mode = "100644"
    ; worktree_mode = "100644"
    ; path
    }
;;

let renamed ?(index : Status.Change.t = Renamed) ~original path : Status.Entry.t =
  Renamed_or_copied
    { index
    ; worktree = Unmodified
    ; submodule = None
    ; head_mode = "100644"
    ; index_mode = "100644"
    ; worktree_mode = "100644"
    ; score = 100
    ; path
    ; original
    }
;;

let unmerged path : Status.Entry.t =
  Unmerged { conflict = Both_modified; submodule = None; path }
;;

let%expect_test "the popup: switches and actions, and what each action returns" =
  let popup = Commit.popup in
  print_endline popup.title;
  List.iter (Popup.help popup) ~f:(fun (key, description) ->
    printf "%-3s %s\n" key description);
  print_s [%sexp (Commit.flags : string list)];
  let state = Popup.initial popup in
  let press state key =
    match Popup.press popup state key with
    | Updated state -> state
    | _ -> assert false
  in
  let state = press (press state '-') 'e' in
  let state = press (press state '-') 'n' in
  List.iter [ 'c'; 'a'; 'e' ] ~f:(fun key ->
    match Popup.press popup state key with
    | Run choice -> print_s [%sexp (key : char), (choice : Commit.Choice.t)]
    | _ -> assert false);
  [%expect
    {|
    Commit
    -n  Disable hooks (--no-verify)
    -s  Add Signed-off-by line (--signoff)
    -e  Allow an empty commit (--allow-empty)
    c   Commit
    a   Amend
    e   Extend
    (--no-verify --signoff --allow-empty)
    (c (Message (kind Commit) (flags (--no-verify --allow-empty))))
    (a (Message (kind Amend) (flags (--no-verify --allow-empty))))
    (e (Extend (flags (--no-verify --allow-empty))))
    |}]
;;

let%expect_test "refusals: each row, in order" =
  let show status choice =
    printf
      "%s: %s\n"
      (Sexp.to_string [%sexp (choice : Commit.Choice.t)])
      (Option.value (Commit.refusal status choice) ~default:"(allowed)")
  in
  let message ?(flags = []) kind = Commit.Choice.Message { kind; flags } in
  let extend ?(flags = []) () = Commit.Choice.Extend { flags } in
  let staged = status [ changed ~index:Modified "a.txt" ] in
  let unstaged_only =
    status [ changed ~worktree:Modified "a.txt"; Untracked "new.txt"; Ignored "x.o" ]
  in
  let conflicted = status [ changed ~index:Modified "a.txt"; unmerged "c.txt" ] in
  let unborn = status ~oid:None [ changed ~index:Added "a.txt" ] in
  let unborn_empty = status ~oid:None [] in
  print_endline "-- staged changes: everything allowed";
  show staged (message Commit);
  show staged (message Amend ~flags:[ "--signoff"; "--no-verify" ]);
  show staged (extend ());
  print_endline "-- a rename or copy counts as staged";
  show (status [ renamed ~original:"old" "new" ]) (message Commit);
  show (status [ renamed ~index:Copied ~original:"old" "copy" ]) (extend ());
  print_endline "-- unknown switch first, even over a conflict";
  show conflicted (message Commit ~flags:[ "--no-verify"; "--amend" ]);
  print_endline "-- conflicted, whatever else";
  show conflicted (message Commit);
  show conflicted (message Amend);
  show conflicted (extend ~flags:[ "--allow-empty" ] ());
  show (status ~oid:None [ unmerged "c.txt" ]) (message Amend);
  print_endline "-- unborn: amend and extend refused, commit allowed";
  show unborn (message Amend);
  show unborn (extend ());
  show unborn_empty (extend ~flags:[ "--allow-empty" ] ());
  show unborn (message Commit);
  print_endline "-- nothing staged";
  show unstaged_only (message Commit);
  show unstaged_only (extend ());
  show unborn_empty (message Commit);
  print_endline "-- nothing staged: amend rewords; --allow-empty commits";
  show unstaged_only (message Amend);
  show unstaged_only (message Commit ~flags:[ "--allow-empty" ]);
  show unstaged_only (extend ~flags:[ "--allow-empty" ] ());
  show unborn_empty (message Commit ~flags:[ "--allow-empty" ]);
  [%expect
    {|
    -- staged changes: everything allowed
    (Message(kind Commit)(flags())): (allowed)
    (Message(kind Amend)(flags(--signoff --no-verify))): (allowed)
    (Extend(flags())): (allowed)
    -- a rename or copy counts as staged
    (Message(kind Commit)(flags())): (allowed)
    (Extend(flags())): (allowed)
    -- unknown switch first, even over a conflict
    (Message(kind Commit)(flags(--no-verify --amend))): Unknown commit switch --amend; nothing ran
    -- conflicted, whatever else
    (Message(kind Commit)(flags())): Resolve the conflicted files first (s marks one resolved); nothing ran
    (Message(kind Amend)(flags())): Resolve the conflicted files first (s marks one resolved); nothing ran
    (Extend(flags(--allow-empty))): Resolve the conflicted files first (s marks one resolved); nothing ran
    (Message(kind Amend)(flags())): Resolve the conflicted files first (s marks one resolved); nothing ran
    -- unborn: amend and extend refused, commit allowed
    (Message(kind Amend)(flags())): Nothing to amend: there is no commit yet; nothing ran
    (Extend(flags())): Nothing to amend: there is no commit yet; nothing ran
    (Extend(flags(--allow-empty))): Nothing to amend: there is no commit yet; nothing ran
    (Message(kind Commit)(flags())): (allowed)
    -- nothing staged
    (Message(kind Commit)(flags())): Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
    (Extend(flags())): Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
    (Message(kind Commit)(flags())): Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
    -- nothing staged: amend rewords; --allow-empty commits
    (Message(kind Amend)(flags())): (allowed)
    (Message(kind Commit)(flags(--allow-empty))): (allowed)
    (Extend(flags(--allow-empty))): (allowed)
    (Message(kind Commit)(flags(--allow-empty))): (allowed)
    |}]
;;

let print_template text =
  String.split_lines text |> List.iter ~f:(fun line -> printf "|%s\n" line);
  printf "(ends with a newline: %b)\n" (String.is_suffix text ~suffix:"\n")
;;

let%expect_test "template: commit, every label, renames and copies, quoted paths, flags" =
  let entries =
    [ changed ~index:Modified "a.txt"
    ; changed ~worktree:Modified "unstaged-only.txt"
    ; changed ~index:Added ~worktree:Modified "new.txt"
    ; changed ~index:Deleted "gone.txt"
    ; changed ~index:Type_changed "link"
    ; renamed ~original:"old name" "new name"
    ; renamed ~index:Copied ~original:"src.ml" "dst.ml"
    ; changed ~index:Modified "tab\there"
    ; changed ~index:Modified "caf\xc3\xa9 \"q\" back\\slash\x7f"
    ; renamed ~original:"line\nbreak" "plain"
    ; Untracked "untracked.txt"
    ]
  in
  print_template
    (Commit.template
       (status entries)
       Commit
       ~flags:[ "--no-verify"; "--signoff" ]
       ~head_message:None);
  [%expect
    {|
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# On branch main
    |# Switches: --no-verify --signoff
    |#
    |# Changes to be committed:
    |#	modified:   a.txt
    |#	new file:   new.txt
    |#	deleted:    gone.txt
    |#	typechange: link
    |#	renamed:    old name -> new name
    |#	copied:     src.ml -> dst.ml
    |#	modified:   "tab\there"
    |#	modified:   "caf\303\251 \"q\" back\\slash\177"
    |#	renamed:    "line\nbreak" -> plain
    (ends with a newline: true)
    |}];
  (* The exact text: an empty first line, no switches line without flags. *)
  print_s
    [%sexp
      (Commit.template
         (status [ changed ~index:Added "a" ])
         Commit
         ~flags:[]
         ~head_message:None
       : string)];
  [%expect
    {|
     "\
    \n# Write the commit message above. Lines starting with '#' are removed.\
    \n# Space g c commits; Space g a aborts.\
    \n#\
    \n# On branch main\
    \n#\
    \n# Changes to be committed:\
    \n#\tnew file:   a\
    \n"
    |}]
;;

let%expect_test "template: amend, unborn, detached, nothing staged, quoted branch" =
  print_endline "-- amend: HEAD's message, trailing blank lines and spaces removed";
  print_template
    (Commit.template
       (status [ changed ~index:Modified "a.txt" ])
       Amend
       ~flags:[]
       ~head_message:(Some "Subject  \n\nBody line\n  indented\n\n\n  \n"));
  print_endline "-- amend rewording (nothing staged), detached";
  print_template
    (Commit.template
       (status ~head:None [ changed ~worktree:Modified "a.txt" ])
       Amend
       ~flags:[ "--signoff" ]
       ~head_message:(Some "Old subject\n"));
  print_endline "-- amend of an empty message";
  print_template (Commit.template (status []) Amend ~flags:[] ~head_message:(Some "\n"));
  print_endline "-- unborn, nothing staged";
  print_template
    (Commit.template
       (status ~oid:None [ Untracked "a.txt" ])
       Commit
       ~flags:[ "--allow-empty" ]
       ~head_message:None);
  print_endline "-- a branch name outside printable ASCII";
  print_template
    (Commit.template
       (status ~head:(Some "caf\xc3\xa9") [ changed ~index:Modified "a" ])
       Commit
       ~flags:[]
       ~head_message:None);
  [%expect
    {|
    -- amend: HEAD's message, trailing blank lines and spaces removed
    |Subject
    |
    |Body line
    |  indented
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# On branch main
    |#
    |# Staged changes added to HEAD:
    |#	modified:   a.txt
    (ends with a newline: true)
    -- amend rewording (nothing staged), detached
    |Old subject
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# HEAD detached at 0123456
    |# Switches: --signoff
    |#
    |# Staged changes added to HEAD:
    |#	(nothing staged)
    (ends with a newline: true)
    -- amend of an empty message
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# On branch main
    |#
    |# Staged changes added to HEAD:
    |#	(nothing staged)
    (ends with a newline: true)
    -- unborn, nothing staged
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# Initial commit on main
    |# Switches: --allow-empty
    |#
    |# Changes to be committed:
    |#	(nothing staged)
    (ends with a newline: true)
    -- a branch name outside printable ASCII
    |
    |# Write the commit message above. Lines starting with '#' are removed.
    |# Space g c commits; Space g a aborts.
    |#
    |# On branch "caf\303\251"
    |#
    |# Changes to be committed:
    |#	modified:   a
    (ends with a newline: true)
    |}]
;;

let command spec =
  String.chop_prefix_if_exists
    (Exec.Spec.to_string_hum spec)
    ~prefix:(Exec.Spec.to_string_hum (Git.Cli.mutate ~cwd:"/" []) ^ " ")
;;

let%expect_test "summary: the first non-empty stdout line of a succeeded step" =
  let spec = Git.Cli.mutate ~cwd:"/r" [ "commit" ] in
  let show reports = print_s [%sexp (Commit.summary reports : string option)] in
  show
    [ Show.ran
        spec
        (Show.result "\n[main 1a2b3c4] Subject\n 1 file changed, 1 insertion(+)\n")
    ];
  show [ Show.ran spec (Show.result "") ];
  show [ Show.ran spec (Show.result ~status:(Exited 1) "[main 1a2b3c4] Subject\n") ];
  show [ { step = Run spec; outcome = Skipped } ];
  show [];
  [%expect {|
    ("[main 1a2b3c4] Subject")
    ()
    ()
    ()
    ()
    |}]
;;

let%expect_test "prepare and prepared, from canned reports" =
  let repository = { Git.Repository.root = "/r"; git_dir = "/r/.git" } in
  let steps kind =
    List.iter (Commit.prepare repository kind) ~f:(function
      | Run spec ->
        printf
          "  $ %s (%s in %s)\n"
          (command spec)
          (Sexp.to_string [%sexp (spec.kind : Exec.Kind.t)])
          spec.cwd
      | Read_file _ -> print_endline "  (file read)")
  in
  print_endline "Commit:";
  steps Commit;
  print_endline "Amend:";
  steps Amend;
  let path =
    Git.Cli.read ~cwd:"/r" [ "rev-parse"; "--git-path"; "CHES_COMMIT_EDITMSG" ]
  in
  let log = Git.Cli.read ~cwd:"/r" [ "log"; "-1" ] in
  let show kind reports =
    Show.or_error
      (fun prepared -> print_s [%sexp (prepared : Commit.Prepared.t)])
      (Commit.prepared repository kind reports)
  in
  show Commit [ Show.ran path (Show.result ".git/CHES_COMMIT_EDITMSG\n") ];
  show Commit [ Show.ran path (Show.result "/elsewhere/wt/CHES_COMMIT_EDITMSG\n") ];
  show
    Amend
    [ Show.ran path (Show.result ".git/CHES_COMMIT_EDITMSG\n")
    ; Show.ran log (Show.result "Subject\n\nBody\n\n")
    ];
  print_endline "-- failures";
  show
    Commit
    [ Show.ran
        path
        (Show.result ~status:(Exited 128) ~stderr:"fatal: not a git repository\n" "")
    ];
  show
    Amend
    [ Show.ran path (Show.result ".git/CHES_COMMIT_EDITMSG\n")
    ; Show.ran
        log
        (Show.result ~status:(Exited 128) ~stderr:"fatal: bad revision 'HEAD'\n" "")
    ];
  show Commit [ Show.ran path (Show.result "\n") ];
  show Commit [ Show.ran path (Show.result "a\nb\n") ];
  show Commit [];
  show Amend [ Show.ran path (Show.result ".git/CHES_COMMIT_EDITMSG\n") ];
  [%expect
    {|
    Commit:
      $ rev-parse --git-path CHES_COMMIT_EDITMSG (Read in /r)
    Amend:
      $ rev-parse --git-path CHES_COMMIT_EDITMSG (Read in /r)
      $ log -1 --no-show-signature --format=%B HEAD -- (Read in /r)
    ((message_file /r/.git/CHES_COMMIT_EDITMSG) (head_message ()))
    ((message_file /elsewhere/wt/CHES_COMMIT_EDITMSG) (head_message ()))
    ((message_file /r/.git/CHES_COMMIT_EDITMSG)
     (head_message ( "Subject\
                    \n\
                    \nBody\
                    \n\
                    \n")))
    -- failures
    (Error
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --git-path CHES_COMMIT_EDITMSG: exit 128: fatal: not a git repository")
    (Error
     "git --no-pager -c color.ui=false -c core.quotepath=false log -1: exit 128: fatal: bad revision 'HEAD'")
    (Error
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --git-path CHES_COMMIT_EDITMSG: expected one path, got \"\\n\"")
    (Error
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --git-path CHES_COMMIT_EDITMSG: expected one path, got \"a\\nb\\n\"")
    (Error "commit preparation: expected 1 step reports, got 0")
    (Error "commit preparation: expected 2 step reports, got 1")
    |}]
;;

(* Fixture tests. *)

let repository ?(cwd = fun (t : Fixture.t) -> t.work) t =
  let cwd = cwd t in
  match B.detected ~cwd (Fixture.run_steps t (B.detect ~cwd)) with
  | Found repository -> repository
  | _ -> failwith "not a repository"
;;

let snapshot ?cwd t =
  let refresh = Ches_vcs.Backend.Refresh.default in
  let repository = repository ?cwd t in
  ok_exn
    (B.snapshot repository refresh (Fixture.run_steps t (B.refresh repository refresh)))
;;

let prepare ?cwd t kind =
  let s = snapshot ?cwd t in
  ( s
  , ok_exn
      (Commit.prepared
         s.repository
         kind
         (Fixture.run_steps t (Commit.prepare s.repository kind))) )
;;

let print_plan t (plan : Ches_vcs.Backend.Plan.t) =
  printf
    "  plan %S%s\n"
    plan.title
    (if plan.rewrites_worktree then " (rewrites the work tree)" else "");
  List.iter plan.steps ~f:(function
    | Run spec -> printf "  $ %s\n" (relative t (command spec))
    | Read_file _ -> print_endline "  (file read)")
;;

let log_message t =
  Fixture.git t [ "log"; "-1"; "--format=%B" ]
  |> String.rstrip
  |> String.split_lines
  |> List.iter ~f:(fun line -> printf "  log |%s\n" line)
;;

(* Plan [action] against a fresh snapshot (or [snapshot]) and run it: the decision, the
   outcome (the summary, or git's stderr), then HEAD's message. *)
let act ?snapshot:s t action =
  let s =
    match s with
    | Some s -> s
    | None -> snapshot t
  in
  match B.plan s.repository s action with
  | Refused message -> printf "refused: %s\n" message
  | Confirm { title; _ } -> printf "unexpected confirm %S\n" title
  | Run plan ->
    print_endline "run";
    print_plan t plan;
    let reports = Fixture.run_steps t plan.steps in
    (match
       List.find reports ~f:(fun report -> not (Job.Step_report.succeeded report))
     with
     | None ->
       printf "  ok: %s\n" (Option.value (Commit.summary reports) ~default:"(no summary)")
     | Some { outcome = Ran result; _ } ->
       printf
         "  failed: %s: %s\n"
         (Exec.Result.status_hum result)
         (relative t (String.strip result.stderr)
          |> String.substr_replace_all ~pattern:"\n" ~with_:" / ")
     | Some _ -> print_endline "  failed")
;;

(* As the view does: prepare, write the template to the message file as the user leaves
   it, then plan Finish_commit (with the snapshot the template was built from). The user's
   [text]: for [Commit], typed on the template's empty first line; for [Amend], in place
   of HEAD's pre-filled message. *)
let finish ?(flags = []) t (kind : Commit.Kind.t) text =
  let s, prepared = prepare t kind in
  let data =
    match kind with
    | Commit -> text ^ Commit.template s.status kind ~flags ~head_message:None
    | Amend -> Commit.template s.status kind ~flags ~head_message:(Some text)
  in
  Out_channel.write_all prepared.message_file ~data;
  act ~snapshot:s t (Finish_commit { kind; flags; message_file = prepared.message_file })
;;

let%expect_test "prepare in a fixture: the message file in the git dir; HEAD's message" =
  Fixture.with_repo (fun t ->
    let show kind =
      let _, prepared = prepare t kind in
      print_s
        [%sexp
          ({ prepared with message_file = relative t prepared.message_file }
           : Commit.Prepared.t)]
    in
    show Commit;
    Fixture.write t "a.txt" "a\n";
    git t [ "add"; "a.txt" ];
    git t [ "commit"; "-q"; "-m"; "Subject\n\nBody\n\n# not a comment here" ];
    show Commit;
    show Amend;
    print_endline "-- from a linked worktree: git prints an absolute path";
    git t [ "worktree"; "add"; "-q"; Filename.concat t.dir "linked" ];
    let cwd (t : Fixture.t) = Filename.concat t.dir "linked" in
    let s, prepared = prepare ~cwd t Amend in
    print_s
      [%sexp
        (relative t s.repository.git_dir : string)
        , ({ prepared with message_file = relative t prepared.message_file }
           : Commit.Prepared.t)]);
  [%expect
    {|
    ((message_file $DIR/work/.git/CHES_COMMIT_EDITMSG) (head_message ()))
    ((message_file $DIR/work/.git/CHES_COMMIT_EDITMSG) (head_message ()))
    ((message_file $DIR/work/.git/CHES_COMMIT_EDITMSG)
     (head_message ( "Subject\
                    \n\
                    \nBody\
                    \n\
                    \n# not a comment here\
                    \n\
                    \n")))
    -- from a linked worktree: git prints an absolute path
    ($DIR/work/.git/worktrees/linked
     ((message_file $DIR/work/.git/worktrees/linked/CHES_COMMIT_EDITMSG)
      (head_message ( "Subject\
                     \n\
                     \nBody\
                     \n\
                     \n# not a comment here\
                     \n\
                     \n"))))
    |}]
;;

let%expect_test "commit: comments stripped, signoff, user commentChar, empty message" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    commit t "base";
    Fixture.write t "a.txt" "a\nb\n";
    git t [ "add"; "a.txt" ];
    finish t Commit "Add b\n\nWith a body.\n# a comment of the user's too";
    log_message t;
    print_endline "-- --signoff adds the trailer";
    Fixture.write t "a.txt" "a\nb\nc\n";
    git t [ "add"; "a.txt" ];
    finish t Commit "Add c" ~flags:[ "--signoff" ];
    log_message t;
    print_endline "-- core.commentChar=; in the repository: '#' lines still stripped";
    git t [ "config"; "core.commentChar"; ";" ];
    Fixture.write t "a.txt" "a\nb\nc\nd\n";
    git t [ "add"; "a.txt" ];
    finish t Commit "Add d\n\n; kept: not a comment for this commit";
    log_message t;
    print_endline "-- an empty message fails with git's stderr";
    Fixture.write t "a.txt" "e\n";
    git t [ "add"; "a.txt" ];
    finish t Commit "";
    log_message t;
    print_endline "-- --allow-empty with nothing staged";
    git t [ "commit"; "-q"; "-m"; "Add e" ];
    finish t Commit "Nothing changed" ~flags:[ "--allow-empty" ];
    log_message t;
    print_endline "-- nothing staged, through plan";
    finish t Commit "Nothing changed");
  [%expect
    {|
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main a3b3279] Add b
      log |Add b
      log |
      log |With a body.
    -- --signoff adds the trailer
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip --signoff -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main f1aaebc] Add c
      log |Add c
      log |
      log |Signed-off-by: Ches Test <ches-test@example.invalid>
    -- core.commentChar=; in the repository: '#' lines still stripped
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main 5e0f774] Add d
      log |Add d
      log |
      log |; kept: not a comment for this commit
    -- an empty message fails with git's stderr
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      failed: exit 1: Aborting commit due to empty commit message.
      log |Add d
      log |
      log |; kept: not a comment for this commit
    -- --allow-empty with nothing staged
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip --allow-empty -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main eda817f] Nothing changed
      log |Nothing changed
    -- nothing staged, through plan
    refused: Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
    |}]
;;

let%expect_test "hooks: a failing pre-commit fails the commit; --no-verify bypasses it" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    commit t "base";
    let hook = Filename.concat t.work ".git/hooks/pre-commit" in
    Out_channel.write_all
      hook
      ~data:"#!/bin/sh\necho 'pre-commit: rejected' >&2\nexit 1\n";
    Core_unix.chmod hook ~perm:0o755;
    Fixture.write t "a.txt" "a\nb\n";
    git t [ "add"; "a.txt" ];
    finish t Commit "Add b";
    log_message t;
    finish t Commit "Add b" ~flags:[ "--no-verify" ];
    log_message t);
  [%expect
    {|
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      failed: exit 1: pre-commit: rejected
      log |base
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip --no-verify -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main 83a7657] Add b
      log |Add b
    |}]
;;

let%expect_test "amend and extend" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    commit t "base";
    Fixture.write t "a.txt" "a\nb\n";
    git t [ "add"; "a.txt" ];
    git t [ "commit"; "-q"; "-m"; "Add b\n\nOld body." ];
    print_endline "-- amend with nothing staged rewords HEAD (its message pre-filled)";
    let s, prepared = prepare t Amend in
    let template =
      Commit.template s.status Amend ~flags:[] ~head_message:prepared.head_message
    in
    Out_channel.write_all
      prepared.message_file
      ~data:(String.substr_replace_first template ~pattern:"Old body." ~with_:"New body.");
    act
      ~snapshot:s
      t
      (Finish_commit { kind = Amend; flags = []; message_file = prepared.message_file });
    log_message t;
    print_s [%sexp (Fixture.git t [ "rev-list"; "--count"; "HEAD" ] : string)];
    print_endline "-- amend with a staged change and --signoff";
    Fixture.write t "a.txt" "a\nb\nc\n";
    git t [ "add"; "a.txt" ];
    finish t Amend "Add b and c\n\n" ~flags:[ "--signoff" ];
    log_message t;
    print_s
      [%sexp (Fixture.git t [ "show"; "--format="; "--name-only"; "HEAD" ] : string)];
    print_endline "-- extend: the staged change joins HEAD, the message stays";
    Fixture.write t "z.txt" "z\n";
    git t [ "add"; "z.txt" ];
    act t (Extend { flags = [ "--allow-empty"; "--no-verify" ] });
    log_message t;
    print_s
      [%sexp (Fixture.git t [ "show"; "--format="; "--name-only"; "HEAD" ] : string)];
    print_endline "-- extend with nothing staged";
    act t (Extend { flags = [] });
    print_endline "-- unknown switch";
    act t (Extend { flags = [ "--amend" ] }));
  [%expect
    {|
    -- amend with nothing staged rewords HEAD (its message pre-filled)
    run
      plan "Amend HEAD"
      $ -c 'core.commentChar=#' commit --cleanup=strip --amend -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main acbe5a4] Add b
      log |Add b
      log |
      log |New body.
    "2\n"
    -- amend with a staged change and --signoff
    run
      plan "Amend HEAD"
      $ -c 'core.commentChar=#' commit --cleanup=strip --amend --signoff -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main d03ff49] Add b and c
      log |Add b and c
      log |
      log |Signed-off-by: Ches Test <ches-test@example.invalid>
    "a.txt\n"
    -- extend: the staged change joins HEAD, the message stays
    run
      plan "Extend HEAD"
      $ commit --amend --no-edit --no-verify --allow-empty
      ok: [main e85e878] Add b and c
      log |Add b and c
      log |
      log |Signed-off-by: Ches Test <ches-test@example.invalid>
     "a.txt\
    \nz.txt\
    \n"
    -- extend with nothing staged
    refused: Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
    -- unknown switch
    refused: Unknown commit switch --amend; nothing ran
    |}]
;;

let%expect_test "refusals through plan: unborn amend and extend, conflicted files" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    git t [ "add"; "a.txt" ];
    act t (Finish_commit { kind = Amend; flags = []; message_file = "/unused" });
    act t (Extend { flags = [] });
    print_endline "-- the first commit on an unborn branch";
    finish t Commit "First";
    log_message t;
    print_endline "-- conflicted";
    git t [ "checkout"; "-q"; "-b"; "other" ];
    Fixture.write t "a.txt" "theirs\n";
    commit t "other";
    git t [ "checkout"; "-q"; "main" ];
    Fixture.write t "a.txt" "ours\n";
    commit t "main";
    ignore
      (Fixture.run
         t
         (Exec.Spec.create ~kind:Mutate ~cwd:t.work "git" [ "merge"; "-q"; "other" ])
       : Exec.Result.t);
    act t (Finish_commit { kind = Commit; flags = []; message_file = "/unused" });
    act t (Finish_commit { kind = Amend; flags = []; message_file = "/unused" });
    act t (Extend { flags = [ "--allow-empty" ] }));
  [%expect
    {|
    refused: Nothing to amend: there is no commit yet; nothing ran
    refused: Nothing to amend: there is no commit yet; nothing ran
    -- the first commit on an unborn branch
    run
      plan "Commit"
      $ -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      ok: [main (root-commit) 0e161fa] First
      log |First
    -- conflicted
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    |}]
;;
