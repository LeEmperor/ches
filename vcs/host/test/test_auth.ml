open! Core
open! Async
open Ches_vcs
open Helpers
module Auth = Ches_vcs_host.Auth

let show ~kind ~base ~ssh_command_configured =
  print_s
    [%sexp
      (Auth.environment ~kind ~base ~ssh_command_configured : (string * string) list)]
;;

let%expect_test "environment: prompt always off, batch ssh only for network commands" =
  let base = [ "HOME", "/h"; "GIT_TERMINAL_PROMPT", "1"; "HOME", "/later" ] in
  show ~kind:Read ~base ~ssh_command_configured:false;
  show ~kind:Mutate ~base ~ssh_command_configured:false;
  [%expect
    {|
    ((HOME /later) (GIT_TERMINAL_PROMPT 0))
    ((HOME /later) (GIT_TERMINAL_PROMPT 0))
    |}];
  (* Neither the environment nor git's configuration names an ssh command. *)
  show ~kind:Network ~base:[ "HOME", "/h" ] ~ssh_command_configured:false;
  [%expect
    {| ((HOME /h) (GIT_TERMINAL_PROMPT 0) (GIT_SSH_COMMAND "ssh -o BatchMode=yes")) |}];
  (* The user's environment names one: kept as is. *)
  show
    ~kind:Network
    ~base:[ "GIT_SSH_COMMAND", "ssh -i ~/.ssh/work"; "HOME", "/h" ]
    ~ssh_command_configured:false;
  [%expect
    {| ((GIT_SSH_COMMAND "ssh -i ~/.ssh/work") (HOME /h) (GIT_TERMINAL_PROMPT 0)) |}];
  (* An empty GIT_SSH_COMMAND does not count (git ignores it too). *)
  show ~kind:Network ~base:[ "GIT_SSH_COMMAND", "" ] ~ssh_command_configured:false;
  [%expect {| ((GIT_SSH_COMMAND "ssh -o BatchMode=yes") (GIT_TERMINAL_PROMPT 0)) |}];
  (* A GIT_SSH wrapper is the user's choice too; forcing GIT_SSH_COMMAND would
     override it. *)
  show ~kind:Network ~base:[ "GIT_SSH", "/usr/local/bin/my-ssh"; "HOME", "/h" ]
    ~ssh_command_configured:false;
  [%expect {| ((GIT_SSH /usr/local/bin/my-ssh) (HOME /h) (GIT_TERMINAL_PROMPT 0)) |}];
  (* core.sshCommand is configured: git uses it, so nothing is added. *)
  show ~kind:Network ~base:[ "HOME", "/h" ] ~ssh_command_configured:true;
  [%expect {| ((HOME /h) (GIT_TERMINAL_PROMPT 0)) |}];
  return ()
;;

let%expect_test "the core.sshCommand probe and how its result is read" =
  print_s [%sexp (Auth.ssh_command_probe ~cwd:"/repo" : Exec.Spec.t)];
  [%expect
    {|
    ((prog git) (args (--no-pager config --get core.sshCommand)) (cwd /repo)
     (env ()) (kind Read) (stdin Null) (timeout (10s)) (stdout_limit 65536)
     (stderr_limit 65536) (stream false))
    |}];
  let result ?(status = Exec.Status.Exited 0) stdout =
    { Exec.Result.status
    ; stdout
    ; stdout_truncated = false
    ; stderr = ""
    ; stderr_truncated = false
    ; timed_out = false
    ; cancelled = false
    ; elapsed = Time_ns.Span.zero
    }
  in
  List.iter
    [ result "ssh -i key\n"
    ; result " \n"
    ; result ~status:(Exited 1) ""
    ; result ~status:(Not_started "git: No such file or directory") ""
    ]
    ~f:(fun r -> print_s [%sexp (Auth.ssh_command_configured r : bool)]);
  [%expect {|
    true
    false
    false
    false
    |}];
  return ()
;;

(* What a network child really sees, in a fixture repository, for each decision. *)
let%expect_test "runner: network children get batch-mode ssh unless the user chose one" =
  let fixture = Fixture.create ~remote:true () in
  Monitor.protect
    ~finally:(fun () ->
      Fixture.remove fixture;
      return ())
    (fun () ->
      let probe ?(kind = Exec.Kind.Network) runner sequence =
        let log = new_log () in
        Runner.submit
          runner
          (job
             sequence
             [ run
                 (sh
                    ~kind
                    ~cwd:fixture.work
                    {|echo "ssh=${GIT_SSH_COMMAND-unset} prompt=$GIT_TERMINAL_PROMPT"|})
             ]);
        let%map () = collect runner log ~until:(fun events -> finished events sequence) in
        print_string (result log.events sequence ~step:0).stdout
      in
      let inherited = Fixture.environment fixture in
      let%bind () =
        with_runner ~inherited (fun runner ->
          let%bind () = probe runner 1 in
          let%bind () = probe ~kind:Mutate runner 2 in
          let%map () = probe ~kind:Read runner 3 in
          ())
      in
      [%expect
        {|
        ssh=ssh -o BatchMode=yes prompt=0
        ssh=unset prompt=0
        ssh=unset prompt=0
        |}];
      let%bind () =
        with_runner
          ~inherited:(inherited @ [ "GIT_SSH_COMMAND", "ssh -F /dev/null" ])
          (fun runner -> probe runner 1)
      in
      [%expect {| ssh=ssh -F /dev/null prompt=0 |}];
      ignore
        (Fixture.git fixture [ "config"; "core.sshCommand"; "ssh -o IdentitiesOnly=yes" ]
         : string);
      let%map () = with_runner ~inherited (fun runner -> probe runner 1) in
      [%expect {| ssh=unset prompt=0 |}])
;;
