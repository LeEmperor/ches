(* Branches and aborts (phase 6): Branch_name.refusal and the Abort popup as pure
   functions, the name rules cross-checked against git check-ref-format --branch; then the
   Checkout, Checkout_previous, Create_branch and Abort plans against fixture
   repositories. Helpers in plan_fixture.ml. *)

open! Core
open Ches_vcs
open Plan_fixture
module Branch_name = Ches_vcs_git.Branch_name
module Abort = Ches_vcs_git.Abort

let%expect_test "Branch_name.refusal: every rule, in order" =
  let show ?(existing = [ "main"; "feature/x" ]) name =
    printf
      "%-14S %s\n"
      name
      (Option.value (Branch_name.refusal ~existing name) ~default:"(allowed)")
  in
  List.iter
    ~f:(fun name -> show name)
    [ ""
    ; "-x"
    ; "-"
    ; "HEAD"
    ; "@"
    ; "a b"
    ; "a\tb"
    ; "a\x7fb"
    ; "a~b"
    ; "a^b"
    ; "a:b"
    ; "a?b"
    ; "a*b"
    ; "a[b"
    ; "a\\b"
    ; "a..b"
    ; "a@{b"
    ; "/a"
    ; "a/"
    ; "a//b"
    ; "a."
    ; ".a"
    ; "a/.b"
    ; "a.lock"
    ; "a/b.lock/c"
    ; "main"
    ; "feature/x"
    ];
  print_endline "-- the first reason in the contract's order, not the name's";
  List.iter
    ~f:(fun name -> show name)
    [ "-a b"; "a b~"; "a\tb~"; "a^b~c"; "a\\b?"; "a..b/"; "/a@{b"; "a//b."; ".a.lock" ];
  print_endline "-- allowed";
  List.iter
    ~f:(fun name -> show name)
    [ "feature/y"
    ; "a.b"
    ; "caf\xc3\xa9"
    ; "a@b"
    ; "x/HEAD"
    ; "HEAD/x"
    ; "a/-b"
    ; "a{b}"
    ; "a]b"
    ; "a./b"
    ; "foo.lock.x"
    ; "refs/heads/x"
    ];
  print_endline "-- existing is exact";
  show ~existing:[ "Main" ] "main";
  show ~existing:[] "main";
  [%expect
    {|
    ""             Enter a branch name
    "-x"           Not a valid branch name: it starts with '-'
    "-"            Not a valid branch name: it starts with '-'
    "HEAD"         Not a valid branch name: it is HEAD
    "@"            Not a valid branch name: it is '@'
    "a b"          Not a valid branch name: it contains a space
    "a\tb"         Not a valid branch name: it contains a control character
    "a\127b"       Not a valid branch name: it contains a control character
    "a~b"          Not a valid branch name: it contains '~'
    "a^b"          Not a valid branch name: it contains '^'
    "a:b"          Not a valid branch name: it contains ':'
    "a?b"          Not a valid branch name: it contains '?'
    "a*b"          Not a valid branch name: it contains '*'
    "a[b"          Not a valid branch name: it contains '['
    "a\\b"         Not a valid branch name: it contains '\'
    "a..b"         Not a valid branch name: it contains '..'
    "a@{b"         Not a valid branch name: it contains '@{'
    "/a"           Not a valid branch name: it starts or ends with '/'
    "a/"           Not a valid branch name: it starts or ends with '/'
    "a//b"         Not a valid branch name: it contains '//'
    "a."           Not a valid branch name: it ends with '.'
    ".a"           Not a valid branch name: a part starts with '.'
    "a/.b"         Not a valid branch name: a part starts with '.'
    "a.lock"       Not a valid branch name: a part ends with '.lock'
    "a/b.lock/c"   Not a valid branch name: a part ends with '.lock'
    "main"         A branch named main already exists
    "feature/x"    A branch named feature/x already exists
    -- the first reason in the contract's order, not the name's
    "-a b"         Not a valid branch name: it starts with '-'
    "a b~"         Not a valid branch name: it contains a space
    "a\tb~"        Not a valid branch name: it contains a control character
    "a^b~c"        Not a valid branch name: it contains '~'
    "a\\b?"        Not a valid branch name: it contains '?'
    "a..b/"        Not a valid branch name: it contains '..'
    "/a@{b"        Not a valid branch name: it contains '@{'
    "a//b."        Not a valid branch name: it contains '//'
    ".a.lock"      Not a valid branch name: a part starts with '.'
    -- allowed
    "feature/y"    (allowed)
    "a.b"          (allowed)
    "caf\195\169"  (allowed)
    "a@b"          (allowed)
    "x/HEAD"       (allowed)
    "HEAD/x"       (allowed)
    "a/-b"         (allowed)
    "a{b}"         (allowed)
    "a]b"          (allowed)
    "a./b"         (allowed)
    "foo.lock.x"   (allowed)
    "refs/heads/x" (allowed)
    -- existing is exact
    "main"         (allowed)
    "main"         (allowed)
    |}]
;;

(* Names whose verdict matters, including every rule's edge. git's verdict is from the
   fixture (on a branch with a commit and no previous branch). *)
let cross_check_names =
  [ "-x"
  ; "-"
  ; "HEAD"
  ; "@"
  ; "@{-1}"
  ; "a..b"
  ; "a@{b"
  ; "a/"
  ; "/a"
  ; "a//b"
  ; "a."
  ; ".a"
  ; "a/.b"
  ; "a.lock"
  ; "a/b.lock/c"
  ; ".lock"
  ; "a b"
  ; "a~b"
  ; "a^b"
  ; "a:b"
  ; "a?b"
  ; "a*b"
  ; "a[b"
  ; "a\\b"
  ; "a\tb"
  ; "a\x01b"
  ; "a\x7fb"
  ; "caf\xc3\xa9"
  ; "feature/x"
  ; "a.b"
  ; "a@b"
  ; "x/HEAD"
  ; "HEAD/x"
  ; "a/-b"
  ; "a{b}"
  ; "a]b"
  ; "a./b"
  ; "a/./b"
  ; "foo.lock.x"
  ; "refs/heads/x"
  ; "#a"
  ]
;;

let%expect_test "Branch_name.refusal agrees with git check-ref-format --branch" =
  Fixture.with_repo (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    List.iter cross_check_names ~f:(fun name ->
      let result =
        Fixture.run
          t
          (Exec.Spec.create
             ~kind:Read
             ~cwd:t.work
             "git"
             [ "check-ref-format"; "--branch"; name ])
      in
      let git = Exec.Result.succeeded result in
      let ours = Option.is_none (Branch_name.refusal ~existing:[] name) in
      printf
        "%-14S git %-7s ours %-7s%s\n"
        name
        (if git then "valid" else "invalid")
        (if ours then "valid" else "invalid")
        (match git, ours with
         | true, false -> "  stricter (documented in branch_name.mli)"
         | false, true -> "  DIFFERENT: Ches accepts what git refuses"
         | _ -> "")));
  [%expect
    {|
    "-x"           git invalid ours invalid
    "-"            git invalid ours invalid
    "HEAD"         git invalid ours invalid
    "@"            git valid   ours invalid  stricter (documented in branch_name.mli)
    "@{-1}"        git invalid ours invalid
    "a..b"         git invalid ours invalid
    "a@{b"         git invalid ours invalid
    "a/"           git invalid ours invalid
    "/a"           git invalid ours invalid
    "a//b"         git invalid ours invalid
    "a."           git invalid ours invalid
    ".a"           git invalid ours invalid
    "a/.b"         git invalid ours invalid
    "a.lock"       git invalid ours invalid
    "a/b.lock/c"   git invalid ours invalid
    ".lock"        git invalid ours invalid
    "a b"          git invalid ours invalid
    "a~b"          git invalid ours invalid
    "a^b"          git invalid ours invalid
    "a:b"          git invalid ours invalid
    "a?b"          git invalid ours invalid
    "a*b"          git invalid ours invalid
    "a[b"          git invalid ours invalid
    "a\\b"         git invalid ours invalid
    "a\tb"         git invalid ours invalid
    "a\001b"       git invalid ours invalid
    "a\127b"       git invalid ours invalid
    "caf\195\169"  git valid   ours valid
    "feature/x"    git valid   ours valid
    "a.b"          git valid   ours valid
    "a@b"          git valid   ours valid
    "x/HEAD"       git valid   ours valid
    "HEAD/x"       git valid   ours valid
    "a/-b"         git valid   ours valid
    "a{b}"         git valid   ours valid
    "a]b"          git valid   ours valid
    "a./b"         git valid   ours valid
    "a/./b"        git invalid ours invalid
    "foo.lock.x"   git valid   ours valid
    "refs/heads/x" git valid   ours valid
    "#a"           git valid   ours valid
    |}]
;;

let%expect_test "Abort: popups, in_progress" =
  List.iter [ Abort.Operation.Rebase; Merge ] ~f:(fun operation ->
    let popup = Abort.popup operation in
    printf "%s:" popup.title;
    List.iter (Popup.help popup) ~f:(fun (key, description) ->
      printf " %s %s" key description);
    match Popup.press popup (Popup.initial popup) 'a' with
    | Run operation ->
      printf " -> %s\n" (Sexp.to_string [%sexp (operation : Abort.Operation.t)])
    | _ -> assert false);
  let rebase interactive_backend : Git.In_progress.t =
    Rebase { interactive_backend; branch = Some "main"; onto = None }
  in
  List.iter
    [ []
    ; [ rebase true ]
    ; [ rebase false ]
    ; [ Apply_mailbox ]
    ; [ Merge { head = None } ]
    ; [ Cherry_pick { commit = None }; Revert { commit = None }; Bisect ]
    ; [ Merge { head = None }; Bisect ]
    ; [ rebase false; Merge { head = None } ]
    ]
    ~f:(fun operations ->
      printf
        "%s: rebase %b, merge %b\n"
        (Sexp.to_string [%sexp (operations : Git.In_progress.t list)])
        (Abort.in_progress operations Rebase)
        (Abort.in_progress operations Merge));
  [%expect
    {|
    Rebasing: a Abort -> Rebase
    Merging: a Abort -> Merge
    (): rebase false, merge false
    ((Rebase(interactive_backend true)(branch(main))(onto()))): rebase true, merge false
    ((Rebase(interactive_backend false)(branch(main))(onto()))): rebase true, merge false
    (Apply_mailbox): rebase false, merge false
    ((Merge(head()))): rebase false, merge true
    ((Cherry_pick(commit()))(Revert(commit()))Bisect): rebase false, merge false
    ((Merge(head()))Bisect): rebase false, merge true
    ((Rebase(interactive_backend false)(branch(main))(onto()))(Merge(head()))): rebase true, merge true
    |}]
;;

(* Fixtures *)

let%expect_test "checkout, the previous branch, a branch named -x" =
  Fixture.with_repo (fun t ->
    let show action = ignore (decide t action : Ches_vcs.Backend.Plan.t option) in
    Fixture.write t "f.txt" "main\n";
    commit t "One";
    print_endline "-- no previous branch yet: git fails the step";
    act t Checkout_previous;
    git t [ "branch"; "topic" ];
    print_endline "-- Enter on topic";
    act t (Checkout "topic");
    head t;
    print_endline "-- refused: the current branch, a branch no longer listed";
    show (Checkout "topic");
    show (Checkout "gone");
    print_endline "-- - goes back";
    Fixture.write t "f.txt" "topic\n";
    commit t "Topic";
    act t Checkout_previous;
    head t;
    printf "  f.txt: %S\n" (In_channel.read_all (Fixture.path t "f.txt"));
    print_endline
      "-- uncommitted changes git would overwrite: it refuses, nothing changes";
    Fixture.write t "f.txt" "edited\n";
    act t (Checkout "topic");
    head t;
    status t;
    git t [ "checkout"; "-q"; "--"; "f.txt" ];
    print_endline
      "-- a branch named -x (made with update-ref; git branch refuses the name)";
    git t [ "update-ref"; "refs/heads/-x"; "HEAD" ];
    act t (Checkout "-x");
    head t);
  [%expect
    {|
    -- no previous branch yet: git fails the step
    run
      plan "Check out the previous branch" (rewrites the work tree)
      $ switch - (Mutate)
      failed: exit 128
      | fatal: invalid reference: @{-1}
      hint: (none)
    -- Enter on topic
    run
      plan "Check out topic" (rewrites the work tree)
      $ switch --end-of-options topic (Mutate)
      ok
      head: topic
    -- refused: the current branch, a branch no longer listed
    refused: Already on topic; nothing ran
    refused: gone is no longer listed; refresh (g r); nothing ran
    -- - goes back
    run
      plan "Check out the previous branch" (rewrites the work tree)
      $ switch - (Mutate)
      ok
      head: main
      f.txt: "main\n"
    -- uncommitted changes git would overwrite: it refuses, nothing changes
    run
      plan "Check out topic" (rewrites the work tree)
      $ switch --end-of-options topic (Mutate)
      failed: exit 1
      | error: Your local changes to the following files would be overwritten by checkout:
      hint: (none)
      head: main
      status | M f.txt
    -- a branch named -x (made with update-ref; git branch refuses the name)
    run
      plan "Check out -x" (rewrites the work tree)
      $ switch --end-of-options -x (Mutate)
      ok
      head: -x
    |}]
;;

let%expect_test "create branch: at HEAD, checked out, changes kept; refusals" =
  Fixture.with_repo (fun t ->
    let show action = ignore (decide t action : Ches_vcs.Backend.Plan.t option) in
    print_endline "-- unborn";
    show (Create_branch "feature/x");
    show (Create_branch "");
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    Fixture.write t "f.txt" "uncommitted\n";
    act t (Create_branch "feature/x");
    head t;
    status t;
    printf
      "  feature/x at main: %b\n"
      (String.equal
         (output t [ "rev-parse"; "feature/x" ])
         (output t [ "rev-parse"; "main" ]));
    print_endline "-- refusals";
    List.iter [ ""; "main"; "feature/x"; "-x"; "a..b"; "HEAD" ] ~f:(fun name ->
      show (Create_branch name));
    print_endline "-- from a detached HEAD";
    git t [ "switch"; "-q"; "--detach"; "main" ];
    act t (Create_branch "from-detached");
    head t);
  [%expect
    {|
    -- unborn
    refused: There is no commit yet: commit before branching; nothing ran
    refused: There is no commit yet: commit before branching; nothing ran
    run
      plan "Create branch feature/x"
      $ switch --create feature/x (Mutate)
      ok
      head: feature/x
      status | M f.txt
      feature/x at main: true
    -- refusals
    refused: Enter a branch name; nothing ran
    refused: A branch named main already exists; nothing ran
    refused: A branch named feature/x already exists; nothing ran
    refused: Not a valid branch name: it starts with '-'; nothing ran
    refused: Not a valid branch name: it contains '..'; nothing ran
    refused: Not a valid branch name: it is HEAD; nothing ran
    -- from a detached HEAD
    run
      plan "Create branch from-detached"
      $ switch --create from-detached (Mutate)
      ok
      head: from-detached
    |}]
;;

let%expect_test "merge abort, and the refusals while a merge is in progress" =
  Fixture.with_repo (fun t ->
    let show action = ignore (decide t action : Ches_vcs.Backend.Plan.t option) in
    Fixture.write t "f.txt" "base\n";
    commit t "Base";
    git t [ "switch"; "-q"; "-c"; "other" ];
    Fixture.write t "f.txt" "theirs\n";
    commit t "Theirs";
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t "f.txt" "ours\n";
    commit t "Ours";
    show (Abort Merge);
    ignore
      (Fixture.run
         t
         (Exec.Spec.create ~kind:Mutate ~cwd:t.work "git" [ "merge"; "other" ])
       : Exec.Result.t);
    head t;
    show (Checkout "other");
    show (Checkout "main");
    show (Checkout "nosuch");
    show Checkout_previous;
    show (Pull { flags = [] });
    show (Abort Rebase);
    show (Push { target = Upstream; flags = [] });
    print_endline "-- n: in progress before the name's own refusals";
    show (Create_branch "while-merging");
    show (Create_branch "main");
    show (Create_branch "a..b");
    print_endline "-- m a";
    act t (Abort Merge);
    head t;
    status t;
    printf "  f.txt: %S\n" (In_channel.read_all (Fixture.path t "f.txt")));
  [%expect
    {|
    refused: No merge in progress; nothing ran
      head: main; Merging 1942d9f; conflicted f.txt
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    refused: Already on main; nothing ran
    refused: nosuch is no longer listed; refresh (g r); nothing ran
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    refused: No rebase in progress; nothing ran
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    -- n: in progress before the name's own refusals
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    refused: Merging 1942d9f in progress: finish or abort it first; nothing ran
    -- m a
    confirm "Abort merge": Abort the merge? Its changes and your conflict resolutions are lost; HEAD stays where it is.
      plan "Abort merge" (rewrites the work tree)
      $ merge --abort (Mutate)
      ok
      head: main
      status: clean
      f.txt: "ours\n"
    |}]
;;

let%expect_test "in progress: bisect does not refuse; the first other operation does" =
  Fixture.with_repo (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    git t [ "branch"; "topic" ];
    let s = snapshot t in
    let with_operations operations action =
      ignore (decide ~snapshot:{ s with operations } t action : _ option)
    in
    with_operations [ Bisect ] (Checkout "topic");
    with_operations
      [ Bisect; Cherry_pick { commit = None }; Merge { head = None } ]
      Checkout_previous;
    with_operations [ Revert { commit = Some "0123456789abcdef" } ] (Checkout "topic");
    with_operations [ Apply_mailbox ] (Abort Rebase));
  [%expect
    {|
    run
      plan "Check out topic" (rewrites the work tree)
      $ switch --end-of-options topic (Mutate)
    refused: Cherry-picking in progress: finish or abort it first; nothing ran
    refused: Reverting 0123456 in progress: finish or abort it first; nothing ran
    refused: No rebase in progress; nothing ran
    |}]
;;
