open! Core
open! Async
open Ches_vcs
open Helpers

let only_finished events =
  List.filter events ~f:(function
    | Event.Finished _ -> true
    | Started _ | Output _ -> false)
;;

(* Submit [steps] as job 1 and print its events. *)
let run_job ?(finished_only = false) ~dir runner steps =
  let log = new_log () in
  Runner.submit runner (job 1 steps);
  let%map () = collect runner log ~until:(fun events -> finished events 1) in
  print_events ~dir (if finished_only then only_finished log.events else log.events);
  log.events
;;

let%expect_test "file reads: contents, limit, missing, failure" =
  with_dir (fun dir ->
    Out_channel.write_all (dir ^/ "MERGE_HEAD") ~data:"0123456789abcdef\n";
    Out_channel.write_all (dir ^/ "empty") ~data:"";
    Core_unix.mkdir (dir ^/ "rebase-merge");
    let read ?(limit = 64) name = Job.Step.Read_file { path = dir ^/ name; limit } in
    with_runner (fun runner ->
      let%bind (_ : Event.t list) =
        run_job
          ~dir
          runner
          [ read "MERGE_HEAD"
          ; read ~limit:4 "MERGE_HEAD"
          ; read ~limit:17 "MERGE_HEAD"
          ; read "empty"
          ; read "absent"
          ; read "MERGE_HEAD/below-a-file"
          ; read "rebase-merge"
          ]
      in
      (* No [Started] for file reads; a directory is a failure, absence is not. *)
      [%expect
        {|
        (finished g1.1 complete
         (read (Contents (text "0123456789abcdef\n") (truncated false)))
         (read (Contents (text 0123) (truncated true)))
         (read (Contents (text "0123456789abcdef\n") (truncated false)))
         (read (Contents (text "") (truncated false))) (read Missing) (read Missing)
         (read (Failed "Is a directory")))
        |}];
      (* In a mutation, a failed read stops the job like a failed command. *)
      let log = new_log () in
      Runner.submit
        runner
        (job 2 [ read "rebase-merge"; run (sh ~cwd:dir "echo not reached") ]);
      let%map () = collect runner log ~until:(fun events -> finished events 2) in
      print_events log.events;
      [%expect {| (finished g1.2 complete (read (Failed "Is a directory")) skipped) |}]))
;;

let%expect_test "stdin: never the terminal; data is written then closed" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let big =
        String.init (300 * 1024) ~f:(fun i ->
          Char.of_int_exn (Char.to_int 'a' + (i % 26)))
      in
      let%bind events =
        run_job
          ~dir
          runner
          [ (* [Null]: end of file at once, so [cat] exits instead of reading a tty. *)
            run (sh ~cwd:dir "cat; echo eof")
          ; run (sh ~cwd:dir ~stdin:(Data "patch line 1\npatch line 2") "cat")
          ; (* More than a pipe holds, read while it is written. *)
            run (sh ~cwd:dir ~stdin:(Data big) "wc -c")
          ; (* A child that never reads its stdin is not stuck and nothing raises. *)
            run (sh ~cwd:dir ~stdin:(Data big) "echo ignored")
          ]
      in
      [%expect
        {|
        (started g1.1 0 "/bin/sh -c 'cat; echo eof'")
        (started g1.1 1 "/bin/sh -c cat")
        (started g1.1 2 "/bin/sh -c 'wc -c'")
        (started g1.1 3 "/bin/sh -c 'echo ignored'")
        (finished g1.1 complete (ran ("exit 0" (stdout "eof\n")))
         (ran ("exit 0" (stdout  "patch line 1\
                                \npatch line 2")))
         (ran ("exit 0" (stdout "307200\n"))) (ran ("exit 0" (stdout "ignored\n"))))
        |}];
      ignore events;
      return ()))
;;

let%expect_test "output limits: stdout keeps its head, stderr its tail" =
  with_dir (fun dir ->
    with_runner (fun runner ->
      let script = "printf 0123456789; printf abcdefghij >&2" in
      let%bind (_ : Event.t list) =
        run_job
          ~finished_only:true
          ~dir
          runner
          [ run (sh ~cwd:dir ~stdout_limit:4 ~stderr_limit:4 script)
          ; run (sh ~cwd:dir ~stdout_limit:10 ~stderr_limit:10 script)
          ; (* A mutation is drained to the end, keeping only the head. *)
            run (sh ~cwd:dir ~stdout_limit:3 "head -c 1000000 /dev/zero | tr '\\0' x")
          ]
      in
      [%expect
        {|
        (finished g1.1 complete
         (ran
          ("exit 0" (stdout 0123) (stderr ghij) stdout_truncated stderr_truncated))
         (ran ("exit 0" (stdout 0123456789) (stderr abcdefghij)))
         (ran ("exit 0" (stdout xxx) stdout_truncated)))
        |}];
      (* A read whose stdout passes its limit is stopped: its prefix is the answer. *)
      let log = new_log () in
      Runner.submit
        runner
        (job 2 [ run (sh ~kind:Read ~cwd:dir ~stdout_limit:1000 "exec yes") ]);
      let%map () = collect runner log ~until:(fun events -> finished events 2) in
      let result = result log.events 2 ~step:0 in
      print_s
        [%sexp
          { status = (result.status : Exec.Status.t)
          ; kept = (String.length result.stdout : int)
          ; all_y =
              (String.for_all result.stdout ~f:(fun c ->
                 Char.equal c 'y' || Char.equal c '\n')
               : bool)
          ; cut_at_limit = (Exec.Result.cut_at_limit result : bool)
          }];
      [%expect
        {| ((status (Signaled sigterm)) (kept 1000) (all_y true) (cut_at_limit true)) |}]))
;;

let%expect_test "a missing program or working directory is not started, not raised" =
  with_dir (fun dir ->
    Out_channel.write_all (dir ^/ "file") ~data:"";
    with_runner (fun runner ->
      let spec ?(cwd = dir) prog =
        Exec.Spec.create ~kind:Read ~cwd prog [ "--version" ]
      in
      let%bind (_ : Event.t list) =
        run_job
          ~dir
          runner
          [ run (spec "ches-no-such-program")
          ; run (spec (dir ^/ "no-such-program"))
          ; run (spec (dir ^/ "file"))
          ; run (spec ~cwd:(dir ^/ "missing") "/bin/sh")
          ; run (spec ~cwd:(dir ^/ "file") "/bin/sh")
          ]
      in
      [%expect
        {|
        (started g1.1 0 "ches-no-such-program --version")
        (started g1.1 1 "$DIR/no-such-program --version")
        (started g1.1 2 "$DIR/file --version")
        (started g1.1 3 "/bin/sh --version")
        (started g1.1 4 "/bin/sh --version")
        (finished g1.1 complete
         (ran ("could not start: ches-no-such-program: No such file or directory"))
         (ran ("could not start: $DIR/no-such-program: No such file or directory"))
         (ran ("could not start: $DIR/file: Permission denied"))
         (ran
          ("could not start: working directory $DIR/missing: No such file or directory"))
         (ran ("could not start: working directory $DIR/file: Not a directory")))
        |}];
      (* In a mutation it stops the job. *)
      let log = new_log () in
      Runner.submit
        runner
        (job
           2
           [ run (Exec.Spec.create ~kind:Mutate ~cwd:dir "ches-no-such-program" [])
           ; run (sh ~cwd:dir "echo no")
           ]);
      let%map () = collect runner log ~until:(fun events -> finished events 2) in
      print_events ~dir log.events;
      [%expect
        {|
        (started g1.2 0 ches-no-such-program)
        (finished g1.2 complete
         (ran ("could not start: ches-no-such-program: No such file or directory"))
         skipped)
        |}]))
;;
