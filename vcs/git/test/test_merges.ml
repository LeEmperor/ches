(* Merges and rebases (phase 7): the operation and merge popups, Operation.in_progress and
   Operation.stopped_hint as pure functions; then the Merge, Continue, Skip_rebase_commit
   and Resolve plans against fixture repositories: a conflicting merge carried through
   resolution to a merge commit, the fast-forward switches, a rebase stopping twice
   (continue, then skip), and the refusals in order. Helpers in plan_fixture.ml. *)

open! Core
open Ches_vcs
open Plan_fixture
module Operation = Ches_vcs_git.Operation
module Resolution = Ches_vcs_git.Resolution

(* Pure *)

let print_popup (popup : _ Popup.t) =
  print_endline popup.title;
  List.iter (Popup.help popup) ~f:(fun (key, description) ->
    printf "  %-3s %s\n" key description)
;;

(* Enable [switches] by key, as the user would, then press [key]. *)
let press popup ~switches key =
  let toggle state key =
    match Popup.press popup state key with
    | Updated state -> state
    | _ -> assert false
  in
  let state =
    List.fold switches ~init:(Popup.initial popup) ~f:(fun state switch ->
      toggle (toggle state '-') switch)
  in
  match Popup.press popup state key with
  | Run choice -> choice
  | _ -> assert false
;;

let%expect_test "operation popups: rebasing and merging" =
  List.iter [ Operation.Kind.Rebase; Merge ] ~f:(fun kind ->
    let popup = Operation.popup kind in
    print_popup popup;
    List.iter popup.actions ~f:(fun action ->
      printf
        "  %c -> %s\n"
        action.key
        (Sexp.to_string
           [%sexp (press popup ~switches:[] action.key : Operation.Choice.t)])));
  [%expect
    {|
    Rebasing
      r   Continue
      s   Skip this commit
      a   Abort
      r -> (Continue Rebase)
      s -> Skip
      a -> (Abort Rebase)
    Merging
      m   Commit the merge
      a   Abort
      m -> (Continue Merge)
      a -> (Abort Merge)
    |}]
;;

let%expect_test "merge popup: with a branch, without one; the switches exclude each other"
  =
  let show branch =
    let popup = Operation.merge_popup ~branch in
    print_popup popup;
    List.iter
      [ []; [ 'n' ]; [ 'f' ]; [ 'n'; 'f' ]; [ 'f'; 'n' ] ]
      ~f:(fun switches ->
        printf
          "  %-6s m -> %s\n"
          (String.concat (List.map switches ~f:(sprintf "-%c")))
          (Sexp.to_string [%sexp (press popup ~switches 'm' : Operation.Merge_choice.t)]))
  in
  show (Some "feature/x");
  show None;
  print_s [%sexp (Operation.merge_flags : string list)];
  [%expect
    {|
    Merge
      -n  Always create a merge commit (--no-ff)
      -f  Fast-forward only (--ff-only)
      m   Merge feature/x
             m -> ((branch(feature/x))(flags()))
      -n     m -> ((branch(feature/x))(flags(--no-ff)))
      -f     m -> ((branch(feature/x))(flags(--ff-only)))
      -n-f   m -> ((branch(feature/x))(flags(--ff-only)))
      -f-n   m -> ((branch(feature/x))(flags(--no-ff)))
    Merge
      -n  Always create a merge commit (--no-ff)
      -f  Fast-forward only (--ff-only)
      m   Merge (select a branch in Branches first)
             m -> ((branch())(flags()))
      -n     m -> ((branch())(flags(--no-ff)))
      -f     m -> ((branch())(flags(--ff-only)))
      -n-f   m -> ((branch())(flags(--ff-only)))
      -f-n   m -> ((branch())(flags(--no-ff)))
    (--no-ff --ff-only)
    |}]
;;

let%expect_test "in_progress: rebase (either backend), merge; nothing else counts" =
  let operations : Git.In_progress.t list list =
    [ [ Rebase { interactive_backend = true; branch = None; onto = None } ]
    ; [ Rebase { interactive_backend = false; branch = Some "main"; onto = None } ]
    ; [ Apply_mailbox ]
    ; [ Merge { head = None } ]
    ; [ Cherry_pick { commit = None } ]
    ; [ Revert { commit = None } ]
    ; [ Bisect ]
    ; [ Merge { head = None }; Bisect ]
    ; []
    ]
  in
  List.iter operations ~f:(fun operations ->
    printf
      "%-48s rebase %-5b merge %b\n"
      (Sexp.to_string [%sexp (operations : Git.In_progress.t list)])
      (Operation.in_progress operations Rebase)
      (Operation.in_progress operations Merge));
  [%expect
    {|
    ((Rebase(interactive_backend true)(branch())(onto()))) rebase true  merge false
    ((Rebase(interactive_backend false)(branch(main))(onto()))) rebase true  merge false
    (Apply_mailbox)                                  rebase false merge false
    ((Merge(head())))                                rebase false merge true
    ((Cherry_pick(commit())))                        rebase false merge false
    ((Revert(commit())))                             rebase false merge false
    (Bisect)                                         rebase false merge false
    ((Merge(head()))Bisect)                          rebase false merge true
    ()                                               rebase false merge false
    |}]
;;

let%expect_test "stopped_hint: a failed step with CONFLICT lines on either stream" =
  let spec = Git.Cli.mutate ~cwd:"/r" [ "merge"; "--no-edit"; "x" ] in
  let show ?(status = Exec.Status.Exited 1) ?(stderr = "") stdout =
    printf
      "%-40S %-30S -> %s\n"
      stdout
      stderr
      (Option.value
         (Operation.stopped_hint (Show.ran spec (Show.result ~status ~stderr stdout)))
         ~default:"(none)")
  in
  show "Auto-merging f\nCONFLICT (content): Merge conflict in f\n";
  show ~stderr:"CONFLICT (modify/delete): f deleted in x\n" "";
  show "CONFLICT (rename/rename): a renamed to b\n" ~status:(Signaled "sigterm");
  print_endline "-- no CONFLICT ( line, or success";
  show "Automatic merge failed\n" ~stderr:"error: could not apply 1234567... One\n";
  show "CONFLICT: no parenthesis\n";
  show "conflict (content): lower case\n";
  show ~status:(Exited 0) "CONFLICT (content): Merge conflict in f\n";
  print_endline "-- a step that did not run, a file read";
  let none (report : Job.Step_report.t) =
    print_s [%sexp (Operation.stopped_hint report : string option)]
  in
  none { step = Run spec; outcome = Skipped };
  none
    { step = Read_file { path = "/r/.git/MERGE_MSG"; limit = 100 }
    ; outcome = Read (Contents { text = "CONFLICT (content)"; truncated = false })
    };
  [%expect
    {|
    "Auto-merging f\nCONFLICT (content): Merge conflict in f\n" ""                             -> Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
    ""                                       "CONFLICT (modify/delete): f deleted in x\n" -> Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
    "CONFLICT (rename/rename): a renamed to b\n" ""                             -> Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
    -- no CONFLICT ( line, or success
    "Automatic merge failed\n"               "error: could not apply 1234567... One\n" -> (none)
    "CONFLICT: no parenthesis\n"             ""                             -> (none)
    "conflict (content): lower case\n"       ""                             -> (none)
    "CONFLICT (content): Merge conflict in f\n" ""                             -> (none)
    -- a step that did not run, a file read
    ()
    ()
    |}]
;;

(* Fixtures *)

(* Exit status and git's CONFLICT and error lines of a raw command expected to fail. *)
let attempt t args =
  let result =
    Fixture.run
      t
      (Exec.Spec.create ~kind:Mutate ~env:[ "GIT_EDITOR", "true" ] ~cwd:t.work "git" args)
  in
  printf "  $ git %s: %s\n" (String.concat ~sep:" " args) (Exec.Result.status_hum result);
  List.iter
    (error_lines result.stdout @ error_lines result.stderr)
    ~f:(fun line -> printf "  | %s\n" line)
;;

let hint = Operation.stopped_hint

let show_file t path =
  printf "  %s: %S\n" path (In_channel.read_all (Fixture.path t path))
;;

(* Three files conflict between main and other: f (ours taken), g (theirs taken) and h
   (markers restored after a bad edit, then resolved by hand and marked with s). *)
let%expect_test "a conflicting merge: m m stops, x takes sides, s marks, m m commits" =
  Fixture.with_repo (fun t ->
    List.iter [ "f"; "g"; "h" ] ~f:(fun path -> Fixture.write t path "base\n");
    commit t "Base";
    git t [ "switch"; "-q"; "-c"; "other" ];
    List.iter [ "f"; "g"; "h" ] ~f:(fun path -> Fixture.write t path "theirs\n");
    let other = Fixture.commit_all t "Theirs" in
    git t [ "switch"; "-q"; "main" ];
    List.iter [ "f"; "g"; "h" ] ~f:(fun path -> Fixture.write t path "ours\n");
    let before = Fixture.commit_all t "Ours" in
    print_endline "-- m m";
    act ~stdout:true ~hint t (Merge { branch = "other"; flags = [] });
    head t;
    print_endline "-- m m again: conflicted, so refused";
    act t (Continue Merge);
    print_endline "-- x o on f, x t on g";
    act t (Resolve { path = "f"; side = Ours });
    act t (Resolve { path = "g"; side = Theirs });
    show_file t "f";
    show_file t "g";
    print_endline "-- a bad edit of h, then x m restores the markers";
    Fixture.write t "h" "oops\n";
    act t (Resolve { path = "h"; side = Markers });
    show_file t "h";
    print_endline "-- resolved by hand, s marks it";
    Fixture.write t "h" "ours and theirs\n";
    act t (Stage (File { section = Conflicted; path = "h" }));
    status t;
    print_endline "-- m m commits the merge";
    act t (Continue Merge);
    head t;
    status t;
    printf
      "  parents: first is the old main %b, second is other %b\n"
      (String.equal before (output t [ "rev-parse"; "HEAD^1" ]))
      (String.equal other (output t [ "rev-parse"; "HEAD^2" ]));
    print_endline "  message:";
    List.iter
      (String.split_lines (output t [ "log"; "-1"; "--format=%B" ]))
      ~f:(printf "  | %s\n");
    act t (Continue Merge));
  [%expect
    {|
    -- m m
    run
      plan "Merge other" (rewrites the work tree)
      $ merge --no-edit --end-of-options other (Mutate)
      failed: exit 1
      > CONFLICT (content): Merge conflict in f
      > CONFLICT (content): Merge conflict in g
      > CONFLICT (content): Merge conflict in h
      hint: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      head: main; Merging 6e2ae65; conflicted f; conflicted g; conflicted h
    -- m m again: conflicted, so refused
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    -- x o on f, x t on g
    confirm "Resolve f": Take ours (HEAD) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
      ok
    confirm "Resolve g": Take theirs (6e2ae65) for g? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for g" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- g (Mutate)
      $ --literal-pathspecs add --all -- g (Mutate)
      ok
      f: "ours\n"
      g: "theirs\n"
    -- a bad edit of h, then x m restores the markers
    confirm "Resolve h": Restore the conflict markers in h? Edits to the file are lost.
      plan "Restore conflict markers in h" (rewrites the work tree)
      $ --literal-pathspecs checkout --merge -- h (Mutate)
      ok
      h: "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
    -- resolved by hand, s marks it
    run
      plan "Mark h resolved"
      $ --literal-pathspecs add --all -- h (Mutate)
      ok
      status |M  g
      status |M  h
    -- m m commits the merge
    run
      plan "Commit merge" (rewrites the work tree)
      $ commit --no-edit --cleanup=strip (Mutate, GIT_EDITOR=true)
      ok
      head: main
      status: clean
      parents: first is the old main true, second is other true
      message:
      | Merge branch 'other'
    refused: No merge in progress; nothing ran
    |}]
;;

let%expect_test "merge switches: a fast-forward, --ff-only refused when diverged, --no-ff"
  =
  Fixture.with_repo (fun t ->
    Fixture.write t "f" "base\n";
    commit t "Base";
    git t [ "branch"; "base" ];
    git t [ "switch"; "-q"; "-c"; "side" ];
    Fixture.write t "s" "side\n";
    commit t "Side";
    git t [ "switch"; "-q"; "main" ];
    print_endline "-- plain: fast-forwards";
    act t (Merge { branch = "side"; flags = [] });
    printf "  main: %s\n" (subjects t "main");
    print_endline "-- --ff-only, diverged: git refuses, nothing changes";
    git t [ "switch"; "-q"; "base" ];
    Fixture.write t "b" "b\n";
    commit t "Base two";
    let before = output t [ "rev-parse"; "HEAD" ] in
    act ~hint t (Merge { branch = "side"; flags = [ "--ff-only" ] });
    printf
      "  HEAD unchanged: %b\n"
      (String.equal before (output t [ "rev-parse"; "HEAD" ]));
    head t;
    status t;
    print_endline "-- --no-ff on a branch that could fast-forward: a merge commit";
    git t [ "switch"; "-q"; "-c"; "behind"; "main~1" ];
    act t (Merge { branch = "side"; flags = [ "--no-ff" ] });
    printf "  behind: %s\n" (subjects t "behind");
    printf
      "  parents: %d\n"
      (List.length (String.split ~on:' ' (output t [ "log"; "-1"; "--format=%P" ])));
    print_endline "-- --ff-only that can fast-forward; flags in the popup's order";
    git t [ "switch"; "-q"; "-c"; "behind2"; "main~1" ];
    act t (Merge { branch = "side"; flags = [ "--ff-only" ] });
    printf "  behind2: %s\n" (subjects t "behind2");
    ignore
      (decide t (Merge { branch = "base"; flags = [ "--ff-only"; "--no-ff" ] })
       : Ches_vcs.Backend.Plan.t option));
  [%expect
    {|
    -- plain: fast-forwards
    run
      plan "Merge side" (rewrites the work tree)
      $ merge --no-edit --end-of-options side (Mutate)
      ok
      main: Side < Base
    -- --ff-only, diverged: git refuses, nothing changes
    run
      plan "Merge side (fast-forward only)" (rewrites the work tree)
      $ merge --no-edit --ff-only --end-of-options side (Mutate)
      failed: exit 128
      | fatal: Not possible to fast-forward, aborting.
      hint: (none)
      HEAD unchanged: true
      head: base
      status: clean
    -- --no-ff on a branch that could fast-forward: a merge commit
    run
      plan "Merge side (no fast-forward)" (rewrites the work tree)
      $ merge --no-edit --no-ff --end-of-options side (Mutate)
      ok
      behind: Merge branch 'side' into behind < Base < Side
      parents: 2
    -- --ff-only that can fast-forward; flags in the popup's order
    run
      plan "Merge side (fast-forward only)" (rewrites the work tree)
      $ merge --no-edit --ff-only --end-of-options side (Mutate)
      ok
      behind2: Side < Base
    run
      plan "Merge base (no fast-forward) (fast-forward only)" (rewrites the work tree)
      $ merge --no-edit --no-ff --ff-only --end-of-options base (Mutate)
    |}]
;;

(* main's three commits onto up: One conflicts in f, Two in g, Three applies cleanly. *)
let%expect_test "a rebase stopping twice: x t, r r stops again, r s, the rebase ends" =
  Fixture.with_repo (fun t ->
    Fixture.write t "f" "base\n";
    Fixture.write t "g" "base\n";
    commit t "Base";
    git t [ "switch"; "-q"; "-c"; "up" ];
    Fixture.write t "f" "up\n";
    Fixture.write t "g" "up\n";
    commit t "Upstream";
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t "f" "one\n";
    git t [ "commit"; "-q"; "-a"; "-m"; "One: change f"; "-m"; "Body of one." ];
    Fixture.write t "g" "two\n";
    commit t "Two: change g";
    Fixture.write t "h" "three\n";
    commit t "Three: add h";
    attempt t [ "rebase"; "up" ];
    head t;
    let s = snapshot t in
    print_endline "-- x on f: the sides named for a rebase";
    List.iter s.status.entries ~f:(function
      | Unmerged { path; conflict; _ } ->
        print_endline
          (Popup.help (Resolution.popup ~path conflict s.operations)
           |> List.map ~f:(fun (key, description) -> sprintf "%s %s" key description)
           |> String.concat ~sep:"; ")
      | _ -> ());
    print_endline "-- r r while conflicted: refused";
    act t (Continue Rebase);
    print_endline "-- x t (your commit), r r: the next commit stops";
    act t (Resolve { path = "f"; side = Theirs });
    act ~stdout:true ~hint t (Continue Rebase);
    head t;
    print_endline "-- r s";
    act t Skip_rebase_commit;
    head t;
    status t;
    printf "  main: %s\n" (subjects t "main");
    printf "  One's message: %S\n" (output t [ "log"; "-1"; "--format=%B"; "main~1" ]);
    show_file t "f";
    show_file t "g";
    act t Skip_rebase_commit;
    act t (Continue Rebase));
  [%expect
    {|
      $ git rebase up: exit 1
      | CONFLICT (content): Merge conflict in f
      | error: could not apply c062db9... One: change f
      head: (detached); Rebasing main onto b6507b0; conflicted f
    -- x on f: the sides named for a rebase
    o Take ours (the upstream); t Take theirs (your commit); m Restore the conflict markers
    -- r r while conflicted: refused
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    -- x t (your commit), r r: the next commit stops
    confirm "Resolve f": Take theirs (your commit) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
      ok
    run
      plan "Continue rebase" (rewrites the work tree)
      $ rebase --continue (Mutate, GIT_EDITOR=true)
      failed: exit 1
      > CONFLICT (content): Merge conflict in g
      | error: could not apply 5af985d... Two: change g
      hint: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      head: (detached); Rebasing main onto b6507b0; conflicted g
    -- r s
    confirm "Skip commit": Skip the commit being applied? Its changes are left out of the rebased branch.
      plan "Skip commit" (rewrites the work tree)
      $ rebase --skip (Mutate, GIT_EDITOR=true)
      ok
      head: main
      status: clean
      main: Three: add h < One: change f < Upstream < Base
      One's message: "One: change f\n\nBody of one."
      f: "one\n"
      g: "up\n"
    refused: No rebase in progress; nothing ran
    refused: No rebase in progress; nothing ran
    |}]
;;

let%expect_test "a rebase pull stops on a conflict (CONFLICT on stdout); x o, r r ends it"
  =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f" "base\n";
    commit t "Base";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = clone t "other" in
    push_from t other ~path:"f" ~contents:"theirs\n" "Theirs";
    Fixture.write t "f" "ours\n";
    commit t "Ours";
    act ~stdout:true ~hint t (Pull { flags = [ "--rebase" ] });
    head t;
    act t (Resolve { path = "f"; side = Ours });
    act ~stdout:true ~hint t (Continue Rebase);
    head t;
    status t;
    printf "  main: %s\n" (subjects t "main");
    show_file t "f");
  [%expect
    {|
    run
      plan "Pull from origin/main (rebase)" (rewrites the work tree)
      $ pull --progress --rebase (Network, streamed)
      failed: exit 1
      > CONFLICT (content): Merge conflict in f
      | error: could not apply 920928a... Ours
      hint: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      head: (detached); Rebasing main onto 57d34b8; conflicted f
    confirm "Resolve f": Take ours (the upstream) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
      ok
    run
      plan "Continue rebase" (rewrites the work tree)
      $ rebase --continue (Mutate, GIT_EDITOR=true)
      ok
      head: main
      status: clean
      main: Theirs < Base
      f: "theirs\n"
    |}]
;;

let%expect_test "refusals, in order, with real snapshots" =
  Fixture.with_repo (fun t ->
    let show action = ignore (decide t action : Ches_vcs.Backend.Plan.t option) in
    let all ~branch =
      List.iter
        [ Git.Backend.Merge { branch; flags = [ "--squash" ] }
        ; Merge { branch; flags = [] }
        ; Continue Merge
        ; Continue Rebase
        ; Skip_rebase_commit
        ; Resolve { path = "f"; side = Ours }
        ; Resolve { path = "f"; side = Markers }
        ]
        ~f:show
    in
    print_endline "-- unborn (an unknown switch first)";
    all ~branch:"main";
    Fixture.write t "f" "base\n";
    Fixture.write t "d" "base\n";
    commit t "Base";
    git t [ "switch"; "-q"; "-c"; "other" ];
    Fixture.write t "f" "theirs\n";
    git t [ "rm"; "-q"; "d" ];
    commit t "Theirs";
    git t [ "switch"; "-q"; "main" ];
    print_endline "-- nothing in progress";
    all ~branch:"main";
    show (Merge { branch = "nope"; flags = [ "--no-ff" ] });
    show (Merge { branch = "--help"; flags = [] });
    print_endline "-- merging, conflicted: in progress before conflicted";
    Fixture.write t "f" "ours\n";
    Fixture.write t "d" "ours\n";
    commit t "Ours";
    attempt t [ "merge"; "--no-edit"; "other" ];
    head t;
    all ~branch:"other";
    show (Resolve { path = "d"; side = Markers });
    show (Resolve { path = "d"; side = Theirs });
    print_endline "-- merging, resolved: m m planned";
    git t [ "add"; "f" ];
    git t [ "rm"; "-q"; "d" ];
    show (Continue Merge);
    show (Merge { branch = "other"; flags = [] });
    git t [ "merge"; "--abort" ];
    print_endline "-- conflicted, nothing in progress (a stash that did not apply)";
    Fixture.write t "f" "stashed\n";
    git t [ "stash"; "-q" ];
    Fixture.write t "f" "committed\n";
    commit t "Committed";
    attempt t [ "stash"; "apply" ];
    head t;
    all ~branch:"other";
    show (Resolve { path = "f"; side = Theirs }));
  [%expect
    {|
    -- unborn (an unknown switch first)
    refused: Unknown merge switch --squash; nothing ran
    refused: There is no commit yet; nothing ran
    refused: No merge in progress; nothing ran
    refused: No rebase in progress; nothing ran
    refused: No rebase in progress; nothing ran
    refused: f is not conflicted; nothing ran
    refused: f is not conflicted; nothing ran
    -- nothing in progress
    refused: Unknown merge switch --squash; nothing ran
    refused: Cannot merge main into itself; nothing ran
    refused: No merge in progress; nothing ran
    refused: No rebase in progress; nothing ran
    refused: No rebase in progress; nothing ran
    refused: f is not conflicted; nothing ran
    refused: f is not conflicted; nothing ran
    refused: nope is no longer listed; refresh (g r); nothing ran
    refused: --help is no longer listed; refresh (g r); nothing ran
    -- merging, conflicted: in progress before conflicted
      $ git merge --no-edit other: exit 1
      | CONFLICT (modify/delete): d deleted in other and modified in HEAD.  Version HEAD of d left in tree.
      | CONFLICT (content): Merge conflict in f
      head: main; Merging c003125; conflicted d; conflicted f
    refused: Unknown merge switch --squash; nothing ran
    refused: Merging c003125 in progress: finish or abort it first; nothing ran
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    refused: No rebase in progress; nothing ran
    refused: No rebase in progress; nothing ran
    confirm "Resolve f": Take ours (HEAD) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
    confirm "Resolve f": Restore the conflict markers in f? Edits to the file are lost.
      plan "Restore conflict markers in f" (rewrites the work tree)
      $ --literal-pathspecs checkout --merge -- f (Mutate)
    refused: d has no conflict markers to restore (deleted by them); nothing ran
    confirm "Resolve d": Resolve d by deleting it, as theirs (c003125) did? Any edits to the file are lost.
      plan "Delete d (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- d (Mutate)
    -- merging, resolved: m m planned
    run
      plan "Commit merge" (rewrites the work tree)
      $ commit --no-edit --cleanup=strip (Mutate, GIT_EDITOR=true)
    refused: Merging c003125 in progress: finish or abort it first; nothing ran
    -- conflicted, nothing in progress (a stash that did not apply)
      $ git stash apply: exit 1
      | CONFLICT (content): Merge conflict in f
      head: main; conflicted f
    refused: Unknown merge switch --squash; nothing ran
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    refused: No merge in progress; nothing ran
    refused: No rebase in progress; nothing ran
    refused: No rebase in progress; nothing ran
    confirm "Resolve f": Take ours (HEAD) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
    confirm "Resolve f": Restore the conflict markers in f? Edits to the file are lost.
      plan "Restore conflict markers in f" (rewrites the work tree)
      $ --literal-pathspecs checkout --merge -- f (Mutate)
    confirm "Resolve f": Take theirs (the other side) for f? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for f" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- f (Mutate)
      $ --literal-pathspecs add --all -- f (Mutate)
    |}]
;;
