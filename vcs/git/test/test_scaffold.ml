open! Core
module Fixture = Ches_vcs_fixture.Fixture_repo

(* Scaffolding for agent G: the fixture works from this test library, and the git on
   PATH is at least the version the CLI rules in Cli assume. Calls no stub. *)
let%expect_test "fixture repositories and the git version" =
  Fixture.with_repo (fun t ->
    let version = String.strip (Fixture.git t [ "--version" ]) in
    let numbers =
      String.chop_prefix_exn version ~prefix:"git version "
      |> String.split ~on:'.'
      |> List.take_while ~f:(String.for_all ~f:Char.is_digit)
      |> List.map ~f:Int.of_string
    in
    print_s
      [%sexp
        (List.compare Int.compare numbers [ 2; 43 ] >= 0 : bool)
      , (Ches_vcs_git.Cli.prefix : string list)]);
  [%expect {| (true (--no-pager -c color.ui=false -c core.quotepath=false)) |}]
;;
