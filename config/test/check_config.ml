open Core
open Async
open Ches_config_runtime

let () =
  let path = match Sys.get_argv () with
    | [| _; path |] -> path
    | _ -> eprintf "Usage: check_config.exe PATH\n%!"; Stdlib.exit 2
  in
  don't_wait_for (
    let%bind result = Loader.load ~path () in
    match result with
    | Ok settings ->
      printf "Configuration valid: %d snippet operations\n%!" (List.length settings.snippets);
      Shutdown.exit 0
    | Error message -> eprintf "%s\n%!" message; Shutdown.exit 1);
  never_returns (Scheduler.go ())
