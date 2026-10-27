open! Core
open Ches_vcs

let of_result spec (result : Exec.Result.t) =
  let command = Exec.Spec.to_string_hum spec in
  let status = Exec.Result.status_hum result in
  match String.strip result.stderr with
  | "" -> sprintf "%s: %s" command status
  | stderr -> sprintf "%s: %s: %s" command status stderr
;;

let step_name : Job.Step.t -> string = function
  | Run spec -> Exec.Spec.to_string_hum spec
  | Read_file { path; _ } -> path
;;

let of_report ({ step; outcome } : Job.Step_report.t) =
  match step, outcome with
  | Run spec, Ran result -> of_result spec result
  | _, Skipped -> sprintf "%s: skipped" (step_name step)
  | _, Read Missing -> sprintf "%s: missing" (step_name step)
  | _, Read (Failed message) -> sprintf "%s: %s" (step_name step) message
  | _, Read (Contents _) -> sprintf "%s: read" (step_name step)
  | Read_file _, Ran result ->
    sprintf "%s: %s" (step_name step) (Exec.Result.status_hum result)
;;
