open! Core
open! Async
module Fixture = Ches_vcs_fixture.Fixture_repo

(* Scaffolding for agent H: an Async expect test, a fixture repository with a local
   bare remote, and its environment as a runner's [inherited]. Calls no stub. *)
let%expect_test "async fixture with a bare remote" =
  let t = Fixture.create ~remote:true () in
  let%map () =
    Monitor.protect
      ~finally:(fun () ->
        Fixture.remove t;
        return ())
      (fun () ->
        let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
        let env = Fixture.environment t in
        print_s
          [%sexp
            (Option.is_some t.remote : bool)
          , (List.Assoc.find env "GIT_SSH_COMMAND" ~equal:String.equal : string option)
          , (Ches_vcs_host.Auth.batch_ssh_command : string)])
  in
  [%expect {| (true () "ssh -o BatchMode=yes") |}]
;;
