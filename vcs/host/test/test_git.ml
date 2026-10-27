open! Core
open! Async
open Ches_vcs
open Helpers

(* Real git in a fixture repository, through the runner: a read, a mutation, and network
   commands against the fixture's local bare remote (a path, never a URL). *)
let%expect_test "git: status, commit, push and fetch against the local bare remote" =
  let fixture = Fixture.create ~remote:true () in
  let remote = Option.value_exn fixture.remote in
  Monitor.protect
    ~finally:(fun () ->
      Fixture.remove fixture;
      return ())
    (fun () ->
      with_runner ~inherited:(Fixture.environment fixture) (fun runner ->
        let dir = fixture.dir in
        let git ?(kind = Exec.Kind.Read) ?(stream = false) args =
          let env =
            if Exec.Kind.equal kind Read then [ "GIT_OPTIONAL_LOCKS", "0" ] else []
          in
          Job.Step.Run
            (Exec.Spec.create
               ~env
               ~stream
               ~kind
               ~cwd:fixture.work
               "git"
               ([ "--no-pager"; "-c"; "color.ui=false" ] @ args))
        in
        let sequence = ref 0 in
        let run_job steps =
          incr sequence;
          let sequence = !sequence in
          let log = new_log () in
          Runner.submit runner (job sequence steps);
          let%map () =
            collect runner log ~until:(fun events -> finished events sequence)
          in
          let events = of_job log.events sequence in
          print_events ~dir events
        in
        Fixture.write fixture "a.txt" "alpha\n";
        let%bind () = run_job [ git [ "status"; "--porcelain=v2"; "-z"; "--branch" ] ] in
        [%expect
          {|
          (started g1.1 0
           "git --no-pager -c color.ui=false status --porcelain=v2 -z --branch")
          (finished g1.1 complete
           (ran
            ("exit 0"
             (stdout "# branch.oid (initial)\000# branch.head main\000? a.txt\000"))))
          |}];
        let%bind () =
          run_job
            [ git ~kind:Mutate [ "add"; "-A" ]
            ; git ~kind:Mutate [ "commit"; "-q"; "-m"; "first" ]
            ; git [ "log"; "--format=%H %s" ]
            ]
        in
        [%expect
          {|
          (started g1.2 0 "git --no-pager -c color.ui=false add -A")
          (started g1.2 1 "git --no-pager -c color.ui=false commit -q -m first")
          (started g1.2 2 "git --no-pager -c color.ui=false log '--format=%H %s'")
          (finished g1.2 complete (ran ("exit 0")) (ran ("exit 0"))
           (ran ("exit 0" (stdout "ddfa11f7f8327da047d34b03016114690aae1fb1 first\n"))))
          |}];
        let%bind () =
          run_job [ git ~kind:Network ~stream:true [ "push"; "-u"; "origin"; "main" ] ]
        in
        [%expect
          {|
          (started g1.3 0 "git --no-pager -c color.ui=false push -u origin main")
          (output g1.3 0 Stdout "branch 'main' set up to track 'origin/main'." line)
          (output g1.3 0 Stderr "To $DIR/remote.git" line)
          (output g1.3 0 Stderr " * [new branch]      main -> main" line)
          (finished g1.3 complete
           (ran
            ("exit 0" (stdout "branch 'main' set up to track 'origin/main'.\n")
             (stderr  "To $DIR/remote.git\
                     \n * [new branch]      main -> main\
                     \n"))))
          |}];
        (* Another clone moves the remote ahead; fetching brings it here. *)
        let other = Filename.concat dir "other" in
        ignore (Fixture.git ~cwd:dir fixture [ "clone"; "-q"; remote; other ] : string);
        Out_channel.write_all (Filename.concat other "b.txt") ~data:"beta\n";
        ignore (Fixture.git ~cwd:other fixture [ "add"; "-A" ] : string);
        ignore
          (Fixture.git ~cwd:other fixture [ "commit"; "-q"; "-m"; "second" ] : string);
        ignore
          (Fixture.git ~cwd:other fixture [ "push"; "-q"; "origin"; "main" ] : string);
        let%bind () =
          run_job
            [ git ~kind:Network ~stream:true [ "fetch"; "origin" ]
            ; git [ "rev-list"; "--count"; "--left-right"; "main...origin/main" ]
            ]
        in
        [%expect
          {|
          (started g1.4 0 "git --no-pager -c color.ui=false fetch origin")
          (output g1.4 0 Stderr "From $DIR/remote" line)
          (output g1.4 0 Stderr "   ddfa11f..e053900  main       -> origin/main" line)
          (started g1.4 1
           "git --no-pager -c color.ui=false rev-list --count --left-right main...origin/main")
          (finished g1.4 complete
           (ran
            ("exit 0"
             (stderr
               "From $DIR/remote\
              \n   ddfa11f..e053900  main       -> origin/main\
              \n")))
           (ran ("exit 0" (stdout "0\t1\n"))))
          |}];
        return ()))
;;
