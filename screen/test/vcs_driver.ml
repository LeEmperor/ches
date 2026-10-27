(* Runs the jobs [Ui_state] hands out ([take_vcs_jobs]) synchronously in an isolated
   fixture repository, the way the frontend's runner ([Ches_ui.Vcs_host]) would, and
   feeds their events back as [Ui_state.Input.Vcs]: a [Started] per command step,
   then the [Finished] report. Every job runs to completion, in submission order: a
   real runner would cancel a job superseded in its lane, and the view drops it as
   stale either way. As in the runner, a mutation's steps stop at the first that
   does not succeed (a failed [apply --check] skips the apply); the rest are
   [Skipped] and get no [Started]. Shared by the VCS view's tests (phase 2 agent V) and the
   end-to-end tests (agent W); frozen for both. *)

open! Core
open Ches_screen
module Job = Ches_vcs.Job
module Event = Ches_vcs.Event
module Fixture = Ches_vcs_fixture.Fixture_repo

(* What a runner would report for [job], run to completion now. *)
let events repo (job : Job.t) : Event.t list =
  let steps =
    match Job.kind job with
    | Read -> Fixture.run_steps repo job.steps
    | Mutate | Network ->
      List.folding_map job.steps ~init:true ~f:(fun running step ->
        if running
        then (
          let report = List.hd_exn (Fixture.run_steps repo [ step ]) in
          Job.Step_report.succeeded report, report)
        else false, { Job.Step_report.step; outcome = Skipped })
  in
  let started =
    List.filter_mapi steps ~f:(fun step (report : Job.Step_report.t) : Event.t option ->
      match report.step, report.outcome with
      | Run spec, (Ran _ | Read _) -> Some (Started { job = job.id; step; spec })
      | Run _, Skipped | Read_file _, _ -> None)
  in
  started
  @ [ Finished { id = job.id; lane = job.lane; kind = Job.kind job; steps; cancelled = false } ]
;;

(* One round: take the submitted jobs, run them, and apply all their events as one
   batch. Returns the jobs run, in order. *)
let step repo t ~width ~height =
  let t, jobs = Ui_state.take_vcs_jobs t in
  let inputs =
    List.concat_map jobs ~f:(events repo)
    |> List.map ~f:(fun event -> Ui_state.Input.Vcs event)
  in
  Helpers.run ~width ~height t inputs, jobs
;;

(* Rounds until no view submits more work. Raises after [limit] rounds (default 10):
   a view that keeps submitting is a bug. Returns every job run, in order. *)
let settle ?(limit = 10) repo t ~width ~height =
  let rec loop t ran round =
    let t, jobs = step repo t ~width ~height in
    if List.is_empty jobs
    then t, List.concat (List.rev ran)
    else if round >= limit
    then raise_s [%message "Vcs_driver.settle: still submitting" (round : int)]
    else loop t (jobs :: ran) (round + 1)
  in
  loop t [] 1
;;

(* A job's lane and id, e.g. ["refresh g1.3"]. *)
let describe (job : Job.t) =
  sprintf "%s %s" (Option.value job.lane ~default:"-") (Job.Id.to_string_hum job.id)
;;
