open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo

(* Paths vary per run; show them relative to the fixture. *)
let relative (t : Fixture.t) text =
  String.substr_replace_all text ~pattern:t.dir ~with_:"$DIR"
;;

let%expect_test "an isolated repository with a local bare remote" =
  let dir =
    Fixture.with_repo ~remote:true (fun t ->
      let env = Fixture.environment t in
      let get name = List.Assoc.find env name ~equal:String.equal in
      print_s
        [%sexp
          { global = (get "GIT_CONFIG_GLOBAL" : string option)
          ; nosystem = (get "GIT_CONFIG_NOSYSTEM" : string option)
          ; home_is_fixture = (Option.equal String.equal (get "HOME") (Some t.dir) : bool)
          ; inherited_git_variables =
              (List.count env ~f:(fun (name, _) ->
                 String.is_prefix name ~prefix:"GIT_"
                 && not (List.mem [ "GIT_CONFIG_GLOBAL"; "GIT_CONFIG_NOSYSTEM";
                                    "GIT_AUTHOR_NAME"; "GIT_AUTHOR_EMAIL";
                                    "GIT_COMMITTER_NAME"; "GIT_COMMITTER_EMAIL";
                                    "GIT_AUTHOR_DATE"; "GIT_COMMITTER_DATE";
                                    "GIT_TERMINAL_PROMPT"; "GIT_CEILING_DIRECTORIES" ]
                       name ~equal:String.equal))
               : int)
          }];
      print_string (Fixture.git t [ "config"; "--global"; "--list" ]);
      print_string (relative t (Fixture.git t [ "remote"; "-v" ]));
      Fixture.write t "dir/a.txt" "a\n";
      let hash = Fixture.commit_all t "First" in
      print_endline hash;
      print_string (Fixture.git t [ "log"; "--format=%an <%ae> %ad %s"; "--date=iso" ]);
      print_string (Fixture.git t [ "push"; "-q"; "-u"; "origin"; "main" ]);
      print_string
        (Fixture.git ~cwd:(Option.value_exn t.remote) t [ "rev-parse"; "main" ]);
      print_string (Fixture.git t [ "status"; "--porcelain=v2"; "--branch" ]);
      t.dir)
  in
  print_s [%sexp (Sys_unix.file_exists_exn dir : bool)];
  [%expect
    {|
    ((global (/dev/null)) (nosystem (1)) (home_is_fixture true)
     (inherited_git_variables 0))
    origin	$DIR/remote.git (fetch)
    origin	$DIR/remote.git (push)
    9fd9bcbbb55e33ee1a14ef1420cf8df1457b6d5c
    Ches Test <ches-test@example.invalid> 2026-01-01 00:00:00 +0000 First
    9fd9bcbbb55e33ee1a14ef1420cf8df1457b6d5c
    # branch.oid 9fd9bcbbb55e33ee1a14ef1420cf8df1457b6d5c
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +0 -0
    false
    |}]
;;

let%expect_test "a plain directory beside the repository is not inside one" =
  Fixture.with_repo (fun t ->
    let plain = Fixture.plain_dir t "plain/nested" in
    let result =
      Fixture.run
        t
        (Exec.Spec.create ~kind:Read ~cwd:plain "git" [ "rev-parse"; "--show-toplevel" ])
    in
    print_s
      [%sexp (result.status : Exec.Status.t), (String.strip result.stderr : string)]);
  [%expect
    {|
    ((Exited 128)
     "fatal: not a git repository (or any of the parent directories): .git")
    |}]
;;

let%expect_test "run_steps: commands, stdin, limits, missing programs, file reads" =
  Fixture.with_repo (fun t ->
    Fixture.write t "big.txt" (String.make 100 'x');
    let read ?stdin ?(stdout_limit = 1000) ?(stderr_limit = 1000) prog args =
      Job.Step.Run
        (Exec.Spec.create
           ?stdin
           ~stdout_limit
           ~stderr_limit
           ~env:[ "GIT_OPTIONAL_LOCKS", "0" ]
           ~kind:Read
           ~cwd:t.work
           prog
           args)
    in
    let git_dir = Fixture.path t ".git" in
    let reports =
      Fixture.run_steps
        t
        [ read "git" [ "hash-object"; "--stdin" ] ~stdin:(Data "hello\n")
        ; read "git" [ "cat-file"; "-p"; "HEAD:nothing" ] ~stderr_limit:20
        ; read "cat" [ "big.txt" ] ~stdout_limit:10
        ; read "/no/such/program" []
        ; Read_file { path = Filename.concat git_dir "HEAD"; limit = 100 }
        ; Read_file { path = Filename.concat git_dir "HEAD"; limit = 5 }
        ; Read_file { path = Filename.concat git_dir "MERGE_HEAD"; limit = 100 }
        ; Read_file { path = Filename.concat git_dir "HEAD/x"; limit = 100 }
        ; Read_file { path = git_dir; limit = 100 }
        ]
    in
    List.iter reports ~f:(fun (report : Job.Step_report.t) ->
      match report.outcome with
      | Ran result ->
        print_s
          [%sexp
            { status = (result.status : Exec.Status.t)
            ; stdout = (result.stdout : string)
            ; stdout_truncated = (result.stdout_truncated : bool)
            ; stderr = (result.stderr : string)
            ; stderr_truncated = (result.stderr_truncated : bool)
            ; succeeded = (Job.Step_report.succeeded report : bool)
            }]
      | Read read -> print_s [%sexp (read : Job.File_read.Result.t)]
      | Skipped -> print_endline "skipped"));
  [%expect
    {|
    ((status (Exited 0)) (stdout "ce013625030ba8dba906f756967f9e9ca394464a\n")
     (stdout_truncated false) (stderr "") (stderr_truncated false)
     (succeeded true))
    ((status (Exited 128)) (stdout "") (stdout_truncated false)
     (stderr "object name 'HEAD'.\n") (stderr_truncated true) (succeeded false))
    ((status (Exited 0)) (stdout xxxxxxxxxx) (stdout_truncated true) (stderr "")
     (stderr_truncated false) (succeeded true))
    ((status (Not_started "No such file or directory")) (stdout "")
     (stdout_truncated false) (stderr "") (stderr_truncated false)
     (succeeded false))
    (Contents (text "ref: refs/heads/main\n") (truncated false))
    (Contents (text "ref: ") (truncated true))
    Missing
    Missing
    (Failed "Is a directory")
    |}]
;;
