(* Helpers shared by the phase 6 and 7 tests (test_remote.ml, test_branches.ml,
   test_merges.ml, test_resolution.ml): snapshots of real fixture repositories, plans
   printed without Cli.prefix (paths under the fixture's temp directory as $DIR), and
   plans run the way the runner runs a mutation or network job (stopping at the first
   failed step). Failures print git's error lines only: progress lines vary (throughput,
   timing). *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend

let relative (t : Fixture.t) text =
  String.substr_replace_all text ~pattern:t.dir ~with_:"$DIR"
;;

let git ?cwd t args = ignore (Fixture.git ?cwd t args : string)
let commit t message = ignore (Fixture.commit_all t message : string)
let output ?cwd t args = String.rstrip (Fixture.git ?cwd t args)

let repository (t : Fixture.t) =
  match B.detected ~cwd:t.work (Fixture.run_steps t (B.detect ~cwd:t.work)) with
  | Found repository -> repository
  | _ -> failwith "not a repository"
;;

let snapshot t =
  let refresh = Ches_vcs.Backend.Refresh.default in
  let repository = repository t in
  ok_exn
    (B.snapshot repository refresh (Fixture.run_steps t (B.refresh repository refresh)))
;;

let command spec =
  String.chop_prefix_if_exists
    (Exec.Spec.to_string_hum spec)
    ~prefix:(Exec.Spec.to_string_hum (Git.Cli.mutate ~cwd:"/" []) ^ " ")
;;

let print_plan t (plan : Ches_vcs.Backend.Plan.t) =
  printf
    "  plan %S%s\n"
    plan.title
    (if plan.rewrites_worktree then " (rewrites the work tree)" else "");
  List.iter plan.steps ~f:(function
    | Run spec ->
      printf
        "  $ %s (%s%s%s)\n"
        (relative t (command spec))
        (Sexp.to_string [%sexp (spec.kind : Exec.Kind.t)])
        (if spec.stream then ", streamed" else "")
        (String.concat
           (List.map spec.env ~f:(fun (name, value) -> sprintf ", %s=%s" name value)))
    | Read_file _ -> print_endline "  (file read)")
;;

(* Print the decision for [action] in [snapshot] (default: a fresh one); the plan to run,
   if any (a confirmation's plan as if confirmed). *)
let decide ?snapshot:s t action =
  let s =
    match s with
    | Some s -> s
    | None -> snapshot t
  in
  match B.plan s.repository s action with
  | Refused message ->
    printf "refused: %s\n" message;
    None
  | Run plan ->
    print_endline "run";
    print_plan t plan;
    Some plan
  | Confirm { title; message; plan } ->
    printf "confirm %S: %s\n" title message;
    print_plan t plan;
    Some plan
;;

(* git's lines that say why a command failed. *)
let error_lines text =
  String.split_lines text
  |> List.concat_map ~f:(String.split ~on:'\r')
  |> List.filter ~f:(fun line ->
    List.exists [ "fatal:"; "error:"; " ! "; "CONFLICT"; "Permission" ] ~f:(fun prefix ->
      String.is_prefix line ~prefix))
;;

(* Run [plan]'s steps (each spec's environment extended with [env]) as a mutation job runs
   them. Prints ["ok"], or the failure with git's error lines (also stdout's with
   [~stdout:true]: git prints CONFLICT lines there) and [hint] (default
   {!Git.Remote.hint}). *)
let execute
  ?(env = [])
  ?(stdout = false)
  ?(hint = Git.Remote.hint)
  t
  (plan : Ches_vcs.Backend.Plan.t)
  =
  let with_env : Job.Step.t -> Job.Step.t = function
    | Run spec -> Run { spec with env = spec.env @ env }
    | Read_file _ as step -> step
  in
  let rec go = function
    | [] -> print_endline "  ok"
    | step :: rest ->
      (match Fixture.run_steps t [ with_env step ] with
       | [ ({ outcome = Ran result; _ } as report) ] ->
         if Exec.Result.succeeded result
         then go rest
         else (
           printf "  failed: %s\n" (Exec.Result.status_hum result);
           if stdout
           then
             List.iter (error_lines result.stdout) ~f:(fun line ->
               printf "  > %s\n" (relative t line));
           List.iter (error_lines result.stderr) ~f:(fun line ->
             printf "  | %s\n" (relative t line));
           printf "  hint: %s\n" (Option.value (hint report) ~default:"(none)");
           List.iter rest ~f:(fun _ -> print_endline "  (skipped)"))
       | _ -> failwith "unexpected report")
  in
  go plan.steps
;;

(* Decide, then run what was decided. *)
let act ?snapshot ?env ?stdout ?hint t action =
  Option.iter (decide ?snapshot t action) ~f:(fun plan ->
    execute ?env ?stdout ?hint t plan)
;;

(* A second clone of the bare remote, in [dir/<name>]: another pusher. *)
let clone t name =
  let dir = Fixture.plain_dir t name in
  git ~cwd:t.dir t [ "clone"; "-q"; Option.value_exn t.remote; dir ];
  dir
;;

(* In the clone [dir]: write [path], commit it as [message], and push. *)
let push_from t dir ~path ~contents message =
  Out_channel.write_all (Filename.concat dir path) ~data:contents;
  git ~cwd:dir t [ "add"; "-A" ];
  git ~cwd:dir t [ "commit"; "-q"; "-m"; message ];
  git ~cwd:dir t [ "push"; "-q" ]
;;

(* Subjects of [rev]'s history, newest first, on one line. *)
let subjects ?cwd t rev =
  output ?cwd t [ "log"; "--format=%s"; rev; "--" ]
  |> String.split_lines
  |> String.concat ~sep:" < "
;;

let status t =
  match output t [ "status"; "--porcelain"; "--untracked-files=all" ] with
  | "" -> print_endline "  status: clean"
  | text -> List.iter (String.split_lines text) ~f:(printf "  status |%s\n")
;;

(* The branch, the operations in progress and the conflicted paths, from a snapshot. *)
let head t =
  let s = snapshot t in
  printf
    "  head: %s%s%s\n"
    (Option.value s.status.branch.head ~default:"(detached)")
    (String.concat
       (List.map s.operations ~f:(fun op -> "; " ^ Git.In_progress.describe op)))
    (String.concat
       (List.filter_map s.status.entries ~f:(function
         | Unmerged { path; _ } -> Some ("; conflicted " ^ path)
         | _ -> None)))
;;
