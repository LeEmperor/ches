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
    ((HOME /later) (GIT_TERMINAL_PROMPT 0) (GIT_EDITOR true))
    ((HOME /later) (GIT_TERMINAL_PROMPT 0) (GIT_EDITOR true))
    |}];
  (* Neither the environment nor git's configuration names an ssh command. *)
  show ~kind:Network ~base:[ "HOME", "/h" ] ~ssh_command_configured:false;
  [%expect
    {|
    ((HOME /h) (GIT_TERMINAL_PROMPT 0) (GIT_EDITOR true)
     (GIT_SSH_COMMAND "ssh -o BatchMode=yes"))
    |}];
  (* The user's environment names one: kept as is. *)
  show
    ~kind:Network
    ~base:[ "GIT_SSH_COMMAND", "ssh -i ~/.ssh/work"; "HOME", "/h" ]
    ~ssh_command_configured:false;
  [%expect
    {|
    ((GIT_SSH_COMMAND "ssh -i ~/.ssh/work") (HOME /h) (GIT_TERMINAL_PROMPT 0)
     (GIT_EDITOR true))
    |}];
  (* An empty GIT_SSH_COMMAND does not count (git ignores it too). *)
  show ~kind:Network ~base:[ "GIT_SSH_COMMAND", "" ] ~ssh_command_configured:false;
  [%expect
    {|
    ((GIT_SSH_COMMAND "ssh -o BatchMode=yes") (GIT_TERMINAL_PROMPT 0)
     (GIT_EDITOR true))
    |}];
  (* A GIT_SSH wrapper is the user's choice too; forcing GIT_SSH_COMMAND would override
     it. *)
  show
    ~kind:Network
    ~base:[ "GIT_SSH", "/usr/local/bin/my-ssh"; "HOME", "/h" ]
    ~ssh_command_configured:false;
  [%expect
    {|
    ((GIT_SSH /usr/local/bin/my-ssh) (HOME /h) (GIT_TERMINAL_PROMPT 0)
     (GIT_EDITOR true))
    |}];
  (* core.sshCommand is configured: git uses it, so nothing is added. *)
  show ~kind:Network ~base:[ "HOME", "/h" ] ~ssh_command_configured:true;
  [%expect {| ((HOME /h) (GIT_TERMINAL_PROMPT 0) (GIT_EDITOR true)) |}];
  return ()
;;

let%expect_test "environment: no child may start an editor, whatever the user set" =
  (* GIT_EDITOR wins over core.editor, VISUAL and EDITOR in git, so they are kept. *)
  let base =
    [ "GIT_EDITOR", "vim"; "VISUAL", "emacs"; "EDITOR", "nano"; "GIT_EDITOR", "code -w" ]
  in
  List.iter Exec.Kind.all ~f:(fun kind -> show ~kind ~base ~ssh_command_configured:true);
  [%expect
    {|
    ((GIT_EDITOR true) (VISUAL emacs) (EDITOR nano) (GIT_TERMINAL_PROMPT 0))
    ((GIT_EDITOR true) (VISUAL emacs) (EDITOR nano) (GIT_TERMINAL_PROMPT 0))
    ((GIT_EDITOR true) (VISUAL emacs) (EDITOR nano) (GIT_TERMINAL_PROMPT 0))
    |}];
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

(* What a network child really sees, in a fixture repository, for each decision; every
   child gets GIT_EDITOR=true, even when the inherited environment names an editor. *)
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
                    {|echo "ssh=${GIT_SSH_COMMAND-unset} prompt=$GIT_TERMINAL_PROMPT editor=$GIT_EDITOR"|})
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
        ssh=ssh -o BatchMode=yes prompt=0 editor=true
        ssh=unset prompt=0 editor=true
        ssh=unset prompt=0 editor=true
        |}];
      let%bind () =
        with_runner
          ~inherited:
            (inherited @ [ "GIT_SSH_COMMAND", "ssh -F /dev/null"; "GIT_EDITOR", "vim" ])
          (fun runner -> probe runner 1)
      in
      [%expect {| ssh=ssh -F /dev/null prompt=0 editor=true |}];
      ignore
        (Fixture.git fixture [ "config"; "core.sshCommand"; "ssh -o IdentitiesOnly=yes" ]
         : string);
      let%map () = with_runner ~inherited (fun runner -> probe runner 1) in
      [%expect {| ssh=unset prompt=0 editor=true |}])
;;
