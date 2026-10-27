open! Core
open Ches_vcs

type t =
  { root : string
  ; git_dir : string
  }
[@@deriving sexp, equal]

let root t = t.root
let args = [ "rev-parse"; "--show-toplevel"; "--absolute-git-dir" ]
let detect ~cwd : Job.Step.t list = [ Run (Cli.read ~cwd args) ]

let first_line text =
  match String.lsplit2 (String.strip text) ~on:'\n' with
  | Some (line, _) -> line
  | None -> String.strip text
;;

let detected ~cwd (reports : Job.Step_report.t list) : t Ches_vcs.Backend.Detection.t =
  match reports with
  | [ { step = Run spec; outcome = Ran result } ] ->
    if Exec.Result.succeeded result
    then (
      let output =
        String.chop_suffix result.stdout ~suffix:"\n"
        |> Option.value ~default:result.stdout
      in
      match String.split output ~on:'\n' with
      | [ root; git_dir ]
        when (not (String.is_empty root)) && not (String.is_empty git_dir) ->
        Found { root; git_dir }
      | _ ->
        Failed
          (sprintf
             "%s: cannot read the repository paths (a path containing a newline is not \
              supported): %S"
             (Exec.Spec.to_string_hum spec)
             result.stdout))
    else if Exec.Result.exited_with result [ 128 ]
            && String.is_substring result.stderr ~substring:"not a git repository"
    then Not_a_repository { cwd }
    else if Exec.Result.exited_with result [ 128 ]
            && String.is_substring result.stderr ~substring:"must be run in a work tree"
    then No_work_tree { cwd; message = first_line result.stderr }
    else Failed (Step_failure.of_result spec result)
  | reports ->
    Failed
      (sprintf
         "git repository detection: expected one command report, got: %s"
         (String.concat ~sep:"; " (List.map reports ~f:Step_failure.of_report)))
;;
