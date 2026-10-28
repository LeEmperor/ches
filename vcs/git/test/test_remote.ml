(* Remotes (phase 6): the push and pull popups and Remote.hint as pure functions; then the
   Fetch, Pull and Push plans against fixture repositories with a local bare remote
   ([origin], by path) and, where another pusher is needed, a second clone. The one
   non-local URL, ssh://git@example.invalid/x.git, is only ever reached through a fake
   GIT_SSH_COMMAND script: no test contacts a network. Helpers in plan_fixture.ml. *)

open! Core
open Ches_vcs
open Plan_fixture
module Remote = Ches_vcs_git.Remote

(* Pure *)

let oid = "0123456789abcdef0123456789abcdef01234567"

let branch_status ?(head = Some "main") ?upstream () : Git.Status.t =
  { branch = { oid = Some oid; head; upstream; ahead_behind = None }
  ; entries = []
  ; truncated = false
  }
;;

let print_popup (popup : _ Popup.t) =
  print_endline popup.title;
  List.iter (Popup.help popup) ~f:(fun (key, description) ->
    printf "  %-3s %s\n" key description)
;;

(* Enable [switches] by key, as the user would, then press [key]. *)
let press popup ~switches key =
  let state =
    List.fold switches ~init:(Popup.initial popup) ~f:(fun state switch ->
      let toggle state key =
        match Popup.press popup state key with
        | Updated state -> state
        | _ -> assert false
      in
      toggle (toggle state '-') switch)
  in
  match Popup.press popup state key with
  | Run choice -> choice
  | _ -> assert false
;;

let%expect_test "push popup: with an upstream, without one, detached" =
  let show status =
    let popup = Remote.Push.popup status in
    print_popup popup;
    List.iter [ 'p'; 'u' ] ~f:(fun key ->
      printf
        "  %c -n -f -> %s\n"
        key
        (Sexp.to_string
           [%sexp (press popup ~switches:[ 'n'; 'f' ] key : Remote.Push.Choice.t)]))
  in
  show (branch_status ~upstream:"origin/main" ());
  show (branch_status ~head:(Some "feature/x") ());
  show (branch_status ~head:None ~upstream:"origin/main" ());
  print_s [%sexp (Remote.Push.flags : string list)];
  [%expect
    {|
    Push main
      -f  Force with lease (confirmed) (--force-with-lease)
      -n  Disable hooks (--no-verify)
      p   Push to origin/main
      u   Push to origin/main, set upstream
      p -n -f -> ((target Upstream)(flags(--force-with-lease --no-verify)))
      u -n -f -> ((target Set_upstream)(flags(--force-with-lease --no-verify)))
    Push feature/x
      -f  Force with lease (confirmed) (--force-with-lease)
      -n  Disable hooks (--no-verify)
      p   Push to upstream (none set)
      u   Push to origin/feature/x, set upstream
      p -n -f -> ((target Upstream)(flags(--force-with-lease --no-verify)))
      u -n -f -> ((target Set_upstream)(flags(--force-with-lease --no-verify)))
    Push
      -f  Force with lease (confirmed) (--force-with-lease)
      -n  Disable hooks (--no-verify)
      p   Push to origin/main
      u   Push to origin, set upstream
      p -n -f -> ((target Upstream)(flags(--force-with-lease --no-verify)))
      u -n -f -> ((target Set_upstream)(flags(--force-with-lease --no-verify)))
    (--force-with-lease --no-verify)
    |}]
;;

let%expect_test "pull popup: with an upstream, without one" =
  let show status =
    let popup = Remote.Pull.popup status in
    print_popup popup;
    List.iter [ []; [ 'r' ] ] ~f:(fun switches ->
      printf
        "  %s p -> %s\n"
        (String.concat (List.map switches ~f:(sprintf "-%c")))
        (Sexp.to_string [%sexp (press popup ~switches 'p' : Remote.Pull.Choice.t)]))
  in
  show (branch_status ~upstream:"origin/main" ());
  show (branch_status ());
  print_s [%sexp (Remote.Pull.flags : string list)];
  [%expect
    {|
    Pull
      -r  Rebase local commits onto the upstream (--rebase)
      p   Pull from origin/main
       p -> ((flags()))
      -r p -> ((flags(--rebase)))
    Pull
      -r  Rebase local commits onto the upstream (--rebase)
      p   Pull from upstream (none set)
       p -> ((flags()))
      -r p -> ((flags(--rebase)))
    (--rebase)
    |}]
;;

let%expect_test "hint: every rule, rule order over position, only failed commands" =
  let spec = Git.Cli.network ~cwd:"/r" [ "fetch"; "--progress"; "--prune" ] in
  let show ?(status = Exec.Status.Exited 128) stderr =
    printf
      "%-45S -> %s\n"
      (String.prefix stderr 43)
      (Option.value
         (Remote.hint (Show.ran spec (Show.result ~status ~stderr "")))
         ~default:"(none)")
  in
  List.iter
    ~f:(fun stderr -> show stderr)
    [ "git@github.com: Permission denied (publickey).\n"
    ; "Host key verification failed.\n"
    ; "fatal: could not read Username for 'https://x': terminal prompts disabled\n"
    ; "fatal: could not read Username for 'https://x'\n"
    ; "fatal: could not read Password for 'https://x'\n"
    ; "ssh: Could not resolve hostname example.invalid: Name or service not known\n"
    ; "fatal: unable to access 'https://x/': Could not resolve host: x\n"
    ; "fatal: Not possible to fast-forward, aborting.\n"
    ; " ! [rejected]        main -> main (stale info)\n"
    ; " ! [rejected]        main -> main (fetch first)\n"
    ; " ! [rejected]        main -> main (non-fast-forward)\n"
    ; "fatal: 'nowhere' does not appear to be a git repository\n"
    ; "fatal: No remote repository specified.  Please, specify either a URL or a\n"
    ; "fatal: something else entirely\n"
    ; ""
    ];
  print_endline "-- the first rule wins, wherever its text is";
  show " ! [rejected] main -> main (fetch first)\nPermission denied (publickey).\n";
  show "(stale info)\n(non-fast-forward)\nNot possible to fast-forward\n";
  print_endline "-- case-sensitive";
  show "permission denied (publickey)\n";
  print_endline "-- a timeout or signal still ran and failed";
  show ~status:(Signaled "sigterm") "Permission denied (publickey).\n";
  print_endline "-- success, a step that did not run, a file read: none";
  show ~status:(Exited 0) "Permission denied (publickey).\n";
  let none (report : Job.Step_report.t) =
    print_s [%sexp (Remote.hint report : string option)]
  in
  none { step = Run spec; outcome = Skipped };
  none
    { step = Read_file { path = "/r/.git/MERGE_HEAD"; limit = 10 }
    ; outcome = Read (Failed "Permission denied (publickey)")
    };
  [%expect
    {|
    "git@github.com: Permission denied (publicke" -> SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
    "Host key verification failed.\n"             -> SSH does not know the host's key: connect once with ssh in a terminal to accept it
    "fatal: could not read Username for 'https:/" -> Git needs credentials and Ches cannot prompt: use an SSH key in ssh-agent or a credential helper
    "fatal: could not read Username for 'https:/" -> Git needs credentials and Ches cannot prompt: use an SSH key in ssh-agent or a credential helper
    "fatal: could not read Password for 'https:/" -> Git needs credentials and Ches cannot prompt: use an SSH key in ssh-agent or a credential helper
    "ssh: Could not resolve hostname example.inv" -> Could not resolve the remote's host: check the network
    "fatal: unable to access 'https://x/': Could" -> Could not resolve the remote's host: check the network
    "fatal: Not possible to fast-forward, aborti" -> The branch and its upstream have diverged: pull with rebase (p -r p) or merge outside Ches
    " ! [rejected]        main -> main (stale in" -> The remote branch moved since the last fetch: fetch (f) and look before forcing
    " ! [rejected]        main -> main (fetch fi" -> The remote has commits this branch lacks: pull first (p p)
    " ! [rejected]        main -> main (non-fast" -> The remote has commits this branch lacks: pull first (p p)
    "fatal: 'nowhere' does not appear to be a gi" -> The remote is missing or unreachable: check git remote -v
    "fatal: No remote repository specified.  Ple" -> The remote is missing or unreachable: check git remote -v
    "fatal: something else entirely\n"            -> (none)
    ""                                            -> (none)
    -- the first rule wins, wherever its text is
    " ! [rejected] main -> main (fetch first)\nPe" -> SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
    "(stale info)\n(non-fast-forward)\nNot possibl" -> The branch and its upstream have diverged: pull with rebase (p -r p) or merge outside Ches
    -- case-sensitive
    "permission denied (publickey)\n"             -> (none)
    -- a timeout or signal still ran and failed
    "Permission denied (publickey).\n"            -> SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
    -- success, a step that did not run, a file read: none
    "Permission denied (publickey).\n"            -> (none)
    ()
    ()
    |}]
;;

(* Fixtures *)

let remote_dir (t : Fixture.t) = Option.value_exn t.remote

let%expect_test "push: P u sets the upstream; P p names the destination exactly" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    (* push.default never matters: the destination is explicit. *)
    git t [ "config"; "push.default"; "nothing" ];
    print_endline "-- P p without an upstream";
    act t (Push { target = Upstream; flags = [] });
    print_endline "-- P u";
    act t (Push { target = Set_upstream; flags = [] });
    printf
      "  branch.main.remote=%s branch.main.merge=%s\n"
      (output t [ "config"; "branch.main.remote" ])
      (output t [ "config"; "branch.main.merge" ]);
    printf "  remote main: %s\n" (subjects ~cwd:(remote_dir t) t "main");
    print_s
      [%sexp
        ((Git.Backend.summary (snapshot t)).upstream
         : Ches_vcs.Backend.Summary.Upstream.t option)];
    print_endline "-- P p";
    Fixture.write t "f.txt" "2\n";
    commit t "Two";
    act t (Push { target = Upstream; flags = [ "--no-verify" ] });
    printf "  remote main: %s\n" (subjects ~cwd:(remote_dir t) t "main");
    print_endline "-- a branch whose upstream has another name: pushed to that ref";
    git t [ "push"; "-q"; "origin"; "main:other" ];
    git t [ "switch"; "-q"; "--track"; "-c"; "topic"; "origin/other" ];
    Fixture.write t "t.txt" "t\n";
    commit t "Topic";
    act t (Push { target = Upstream; flags = [] });
    printf "  remote other: %s\n" (subjects ~cwd:(remote_dir t) t "other");
    printf
      "  remote branches: %s\n"
      (output
         ~cwd:(remote_dir t)
         t
         [ "for-each-ref"; "--format=%(refname)"; "refs/heads" ]
       |> String.split_lines
       |> String.concat ~sep:" "));
  [%expect
    {|
    -- P p without an upstream
    refused: main has no upstream: P u pushes it to origin/main and sets it; nothing ran
    -- P u
    run
      plan "Push main to origin/main"
      $ push --progress --set-upstream --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      ok
      branch.main.remote=origin branch.main.merge=refs/heads/main
      remote main: One
    (((name origin/main) (ahead 0) (behind 0) (gone false)))
    -- P p
    run
      plan "Push main to origin/main"
      $ push --progress --no-verify --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      ok
      remote main: Two < One
    -- a branch whose upstream has another name: pushed to that ref
    run
      plan "Push topic to origin/other"
      $ push --progress --end-of-options origin refs/heads/topic:refs/heads/other (Network, streamed)
      ok
      remote other: Topic < Two < One
      remote branches: refs/heads/main refs/heads/other
    |}]
;;

let%expect_test "--progress: progress arrives on stderr without a terminal" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    let other = clone t "other" in
    let run action ?(cwd = t.work) () =
      let s = snapshot t in
      match B.plan s.repository s action with
      | Run { steps = [ Run spec ]; _ } ->
        (match Fixture.run_steps t [ Run { spec with cwd } ] with
         | [ { outcome = Ran result; _ } ] ->
           printf
             "%s: ok %b, stdout %S, progress on stderr %b\n"
             (command spec)
             (Exec.Result.succeeded result)
             result.stdout
             (String.is_substring result.stderr ~substring:"objects: 100%")
         | _ -> assert false)
      | _ -> assert false
    in
    run (Push { target = Set_upstream; flags = [] }) ();
    (* The fetch runs in the clone (made empty), which now has objects to receive. *)
    run Fetch ~cwd:other ());
  [%expect
    {|
    push --progress --set-upstream --end-of-options origin refs/heads/main:refs/heads/main: ok true, stdout "branch 'main' set up to track 'origin/main'.\n", progress on stderr true
    fetch --progress --prune: ok true, stdout "", progress on stderr true
    |}]
;;

let%expect_test "force with lease: confirmed; accepted, then refused as stale" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = clone t "other" in
    git t [ "commit"; "-q"; "--amend"; "-m"; "One, amended" ];
    print_endline "-- a rewritten branch: a plain push is rejected";
    act t (Push { target = Upstream; flags = [] });
    print_endline "-- -f, flags given out of order: confirmed, then accepted";
    act t (Push { target = Upstream; flags = [ "--no-verify"; "--force-with-lease" ] });
    printf "  remote main: %s\n" (subjects ~cwd:(remote_dir t) t "main");
    print_endline "-- another pusher moves the remote; nothing fetched here";
    git ~cwd:other t [ "fetch"; "-q" ];
    git ~cwd:other t [ "reset"; "-q"; "--hard"; "origin/main" ];
    push_from t other ~path:"o.txt" ~contents:"o\n" "Other";
    git t [ "commit"; "-q"; "--amend"; "-m"; "One, amended twice" ];
    act t (Push { target = Upstream; flags = [ "--force-with-lease" ] });
    printf "  remote main: %s\n" (subjects ~cwd:(remote_dir t) t "main");
    print_endline "-- P u -f";
    ignore
      (decide t (Push { target = Set_upstream; flags = [ "--force-with-lease" ] })
       : Ches_vcs.Backend.Plan.t option));
  [%expect
    {|
    -- a rewritten branch: a plain push is rejected
    run
      plan "Push main to origin/main"
      $ push --progress --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      failed: exit 1
      |  ! [rejected]        main -> main (non-fast-forward)
      | error: failed to push some refs to '$DIR/remote.git'
      hint: The remote has commits this branch lacks: pull first (p p)
    -- -f, flags given out of order: confirmed, then accepted
    confirm "Force push": Force-push main to origin/main? Commits on origin/main that main does not contain are lost. git refuses if origin/main moved since the last fetch.
      plan "Force-push main to origin/main"
      $ push --progress --force-with-lease --no-verify --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      ok
      remote main: One, amended
    -- another pusher moves the remote; nothing fetched here
    confirm "Force push": Force-push main to origin/main? Commits on origin/main that main does not contain are lost. git refuses if origin/main moved since the last fetch.
      plan "Force-push main to origin/main"
      $ push --progress --force-with-lease --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      failed: exit 1
      |  ! [rejected]        main -> main (stale info)
      | error: failed to push some refs to '$DIR/remote.git'
      hint: The remote branch moved since the last fetch: fetch (f) and look before forcing
      remote main: Other < One, amended
    -- P u -f
    confirm "Force push": Force-push main to origin/main? Commits on origin/main that main does not contain are lost. git refuses if origin/main moved since the last fetch.
      plan "Force-push main to origin/main"
      $ push --progress --set-upstream --force-with-lease --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
    |}]
;;

let%expect_test "pull: fast-forward only (whatever pull.rebase), diverged, rebase" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = clone t "other" in
    git t [ "config"; "pull.rebase"; "true" ];
    push_from t other ~path:"o.txt" ~contents:"1\n" "Other one";
    print_endline "-- p p fast-forwards";
    act t (Pull { flags = [] });
    printf "  HEAD: %s\n" (subjects t "HEAD");
    print_endline "-- diverged, with pull.rebase=true: refused, nothing changes";
    push_from t other ~path:"o.txt" ~contents:"2\n" "Other two";
    Fixture.write t "l.txt" "l\n";
    commit t "Local";
    let before = output t [ "rev-parse"; "HEAD" ] in
    act t (Pull { flags = [] });
    printf
      "  HEAD unchanged: %b\n"
      (String.equal before (output t [ "rev-parse"; "HEAD" ]));
    printf "  HEAD: %s\n" (subjects t "HEAD");
    head t;
    status t;
    print_endline "-- p -r p, with pull.ff=only: rebased";
    git t [ "config"; "--unset"; "pull.rebase" ];
    git t [ "config"; "pull.ff"; "only" ];
    act t (Pull { flags = [ "--rebase" ] });
    printf "  HEAD: %s\n" (subjects t "HEAD");
    head t;
    status t);
  [%expect
    {|
    -- p p fast-forwards
    run
      plan "Pull from origin/main" (rewrites the work tree)
      $ pull --progress --ff-only --no-rebase (Network, streamed)
      ok
      HEAD: Other one < One
    -- diverged, with pull.rebase=true: refused, nothing changes
    run
      plan "Pull from origin/main" (rewrites the work tree)
      $ pull --progress --ff-only --no-rebase (Network, streamed)
      failed: exit 128
      | fatal: Not possible to fast-forward, aborting.
      hint: The branch and its upstream have diverged: pull with rebase (p -r p) or merge outside Ches
      HEAD unchanged: true
      HEAD: Local < Other one < One
      head: main
      status: clean
    -- p -r p, with pull.ff=only: rebased
    run
      plan "Pull from origin/main (rebase)" (rewrites the work tree)
      $ pull --progress --rebase (Network, streamed)
      ok
      HEAD: Local < Other two < Other one < One
      head: main
      status: clean
    |}]
;;

let%expect_test "a rebase pull stops on a conflict; r a restores the branch" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "base\n";
    commit t "Base";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = clone t "other" in
    push_from t other ~path:"f.txt" ~contents:"theirs\n" "Theirs";
    Fixture.write t "f.txt" "ours\n";
    commit t "Ours";
    let before = output t [ "rev-parse"; "HEAD" ] in
    act t (Pull { flags = [ "--rebase" ] });
    head t;
    print_endline
      "-- while it is stopped (HEAD detached): in progress first, after an unknown flag";
    List.iter
      [ Git.Backend.Pull { flags = [] }
      ; Pull { flags = [ "--squash" ] }
      ; Push { target = Upstream; flags = [] }
      ; Push { target = Set_upstream; flags = [ "--force" ] }
      ; Checkout "main"
      ; Checkout_previous
      ; Create_branch "rescue"
      ; Abort Merge
      ]
      ~f:(fun action -> ignore (decide t action : Ches_vcs.Backend.Plan.t option));
    print_endline "-- r a";
    act t (Abort Rebase);
    printf
      "  HEAD restored: %b\n"
      (String.equal before (output t [ "rev-parse"; "HEAD" ]));
    printf "  f.txt: %S\n" (In_channel.read_all (Fixture.path t "f.txt"));
    head t;
    status t;
    act t (Abort Rebase));
  [%expect
    {|
    run
      plan "Pull from origin/main (rebase)" (rewrites the work tree)
      $ pull --progress --rebase (Network, streamed)
      failed: exit 1
      | error: could not apply 0b441d8... Ours
      hint: (none)
      head: (detached); Rebasing main onto 1942d9f; conflicted f.txt
    -- while it is stopped (HEAD detached): in progress first, after an unknown flag
    refused: Rebasing main onto 1942d9f in progress: finish or abort it first; nothing ran
    refused: Unknown pull switch --squash; nothing ran
    refused: Rebasing main onto 1942d9f in progress: finish or abort it first; nothing ran
    refused: Unknown push switch --force; nothing ran
    refused: Rebasing main onto 1942d9f in progress: finish or abort it first; nothing ran
    refused: Rebasing main onto 1942d9f in progress: finish or abort it first; nothing ran
    refused: Rebasing main onto 1942d9f in progress: finish or abort it first; nothing ran
    refused: No merge in progress; nothing ran
    -- r a
    confirm "Abort rebase": Abort the rebase? The branch returns to where it was before the rebase; commits and conflict resolutions made during it are lost.
      plan "Abort rebase" (rewrites the work tree)
      $ rebase --abort (Mutate)
      ok
      HEAD restored: true
      f.txt: "ours\n"
      head: main
      status: clean
    refused: No rebase in progress; nothing ran
    |}]
;;

let%expect_test "fetch --prune: an upstream deleted on the remote becomes Gone" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    git t [ "switch"; "-q"; "-c"; "doomed" ];
    git t [ "push"; "-q"; "-u"; "origin"; "doomed" ];
    let other = clone t "other" in
    git ~cwd:other t [ "push"; "-q"; "origin"; ":doomed" ];
    let show () =
      let s = snapshot t in
      List.iter s.branches ~f:(fun branch ->
        printf
          "  %s -> %s\n"
          branch.name
          (Sexp.to_string [%sexp (branch.upstream : Git.Branch_list.Upstream.t option)]));
      printf
        "  summary: %s\n"
        (Sexp.to_string
           [%sexp
             ((Git.Backend.summary s).upstream
              : Ches_vcs.Backend.Summary.Upstream.t option)])
    in
    show ();
    act t Fetch;
    show ();
    act t (Pull { flags = [ "--rebase" ] });
    ignore
      (decide t (Push { target = Upstream; flags = [] }) : Ches_vcs.Backend.Plan.t option));
  [%expect
    {|
      doomed -> (((name origin/doomed)(refname refs/remotes/origin/doomed)(tracking In_sync)(remote origin)(merge refs/heads/doomed)))
      main -> (((name origin/main)(refname refs/remotes/origin/main)(tracking In_sync)(remote origin)(merge refs/heads/main)))
      summary: (((name origin/doomed)(ahead 0)(behind 0)(gone false)))
    run
      plan "Fetch"
      $ fetch --progress --prune (Network, streamed)
      ok
      doomed -> (((name origin/doomed)(refname refs/remotes/origin/doomed)(tracking Gone)(remote origin)(merge refs/heads/doomed)))
      main -> (((name origin/main)(refname refs/remotes/origin/main)(tracking In_sync)(remote origin)(merge refs/heads/main)))
      summary: (((name origin/doomed)(ahead 0)(behind 0)(gone true)))
    refused: The upstream origin/doomed is gone; nothing ran
    run
      plan "Push doomed to origin/doomed"
      $ push --progress --end-of-options origin refs/heads/doomed:refs/heads/doomed (Network, streamed)
    |}]
;;

let%expect_test "authentication failure (fake ssh), and a missing remote" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    (* ssh's message for a refused key; it records that it ran instead of any ssh. *)
    let script = Filename.concat t.dir "fake-ssh" in
    let marker = Filename.concat t.dir "fake-ssh-ran" in
    Out_channel.write_all
      script
      ~data:
        (sprintf
           "#!/bin/sh\n\
            echo \"$@\" >> '%s'\n\
            echo 'Permission denied (publickey).' >&2\n\
            exit 255\n"
           marker);
    Core_unix.chmod script ~perm:0o755;
    git t [ "remote"; "set-url"; "origin"; "ssh://git@example.invalid/x.git" ];
    let env = [ "GIT_SSH_COMMAND", script ] in
    act ~env t Fetch;
    act ~env t (Pull { flags = [] });
    act ~env t (Push { target = Upstream; flags = [] });
    In_channel.read_lines marker
    |> List.iter ~f:(fun line -> printf "  fake ssh ran: %s\n" line);
    print_endline "-- a missing remote";
    git t [ "remote"; "set-url"; "origin"; Filename.concat t.dir "nowhere.git" ];
    act t Fetch);
  [%expect
    {|
    run
      plan "Fetch"
      $ fetch --progress --prune (Network, streamed)
      failed: exit 128
      | Permission denied (publickey).
      | fatal: Could not read from remote repository.
      hint: SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
    run
      plan "Pull from origin/main" (rewrites the work tree)
      $ pull --progress --ff-only --no-rebase (Network, streamed)
      failed: exit 1
      | Permission denied (publickey).
      | fatal: Could not read from remote repository.
      hint: SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
    run
      plan "Push main to origin/main"
      $ push --progress --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
      failed: exit 128
      | Permission denied (publickey).
      | fatal: Could not read from remote repository.
      hint: SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
      fake ssh ran: -G -o SendEnv=GIT_PROTOCOL git@example.invalid
      fake ssh ran: git@example.invalid git-upload-pack '/x.git'
      fake ssh ran: -G -o SendEnv=GIT_PROTOCOL git@example.invalid
      fake ssh ran: git@example.invalid git-upload-pack '/x.git'
      fake ssh ran: -G git@example.invalid
      fake ssh ran: git@example.invalid git-receive-pack '/x.git'
    -- a missing remote
    run
      plan "Fetch"
      $ fetch --progress --prune (Network, streamed)
      failed: exit 128
      | fatal: '$DIR/nowhere.git' does not appear to be a git repository
      | fatal: Could not read from remote repository.
      hint: The remote is missing or unreachable: check git remote -v
    |}]
;;

let%expect_test "push and pull refusals, in order, with real snapshots" =
  Fixture.with_repo ~remote:true (fun t ->
    let show action = ignore (decide t action : Ches_vcs.Backend.Plan.t option) in
    print_endline "-- unborn";
    show (Push { target = Upstream; flags = [ "--force" ] });
    show (Push { target = Set_upstream; flags = [] });
    show (Push { target = Upstream; flags = [] });
    Fixture.write t "f.txt" "1\n";
    commit t "One";
    print_endline "-- detached (an unknown switch first)";
    git t [ "switch"; "-q"; "--detach" ];
    show (Push { target = Set_upstream; flags = [ "--tags" ] });
    show (Pull { flags = [ "--ff-only" ] });
    show (Push { target = Set_upstream; flags = [] });
    show (Pull { flags = [ "--rebase" ] });
    git t [ "switch"; "-q"; "main" ];
    print_endline "-- no upstream";
    show (Push { target = Upstream; flags = [] });
    show (Pull { flags = [] });
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    print_endline "-- the branch list failed: P p refused, P u still planned";
    let s = { (snapshot t) with branches = [] } in
    ignore (decide ~snapshot:s t (Push { target = Upstream; flags = [] }) : _ option);
    ignore (decide ~snapshot:s t (Push { target = Set_upstream; flags = [] }) : _ option);
    print_endline "-- conflicted, no operation in progress (a stash that did not apply)";
    Fixture.write t "f.txt" "stashed\n";
    git t [ "stash"; "-q" ];
    Fixture.write t "f.txt" "committed\n";
    commit t "Two";
    ignore
      (Fixture.run
         t
         (Exec.Spec.create ~kind:Mutate ~cwd:t.work "git" [ "stash"; "apply" ])
       : Exec.Result.t);
    head t;
    show (Pull { flags = [] });
    show (Push { target = Upstream; flags = [] });
    show Fetch);
  [%expect
    {|
    -- unborn
    refused: Unknown push switch --force; nothing ran
    refused: There is no commit yet; nothing ran
    refused: There is no commit yet; nothing ran
    -- detached (an unknown switch first)
    refused: Unknown push switch --tags; nothing ran
    refused: Unknown pull switch --ff-only; nothing ran
    refused: HEAD is detached: check out a branch first; nothing ran
    refused: HEAD is detached: check out a branch first; nothing ran
    -- no upstream
    refused: main has no upstream: P u pushes it to origin/main and sets it; nothing ran
    refused: main has no upstream: push it with P u first; nothing ran
    -- the branch list failed: P p refused, P u still planned
    refused: The branch list could not be read; refresh (g r); nothing ran
    run
      plan "Push main to origin/main"
      $ push --progress --set-upstream --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
    -- conflicted, no operation in progress (a stash that did not apply)
      head: main; conflicted f.txt
    refused: Resolve the conflicted files first (s marks one resolved); nothing ran
    run
      plan "Push main to origin/main"
      $ push --progress --end-of-options origin refs/heads/main:refs/heads/main (Network, streamed)
    run
      plan "Fetch"
      $ fetch --progress --prune (Network, streamed)
    |}]
;;
