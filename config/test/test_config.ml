open Core
open Async
open Ches_config_runtime

let check condition message = if not condition then failwith message
let ok = function Ok value -> value | Error error -> failwith error
let error = function Error message -> message | Ok _ -> failwith "expected failure"
let contains text part = String.is_substring text ~substring:part

let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let main () =
  let root = Core_unix.mkdtemp "/tmp/ches-config-tests-" in
  Monitor.protect ~finally:(fun () -> In_thread.run (fun () -> remove root)) (fun () ->
    let path = Filename.concat root "user's config ; $(no shell).ml" in
    let marker = Filename.concat root "private directory" in
    let write source = Out_channel.write_all path ~data:source in
    let load source = write source; Loader.load ~path () in
    let remember = sprintf "let () = let c = open_out %S in output_string c (Sys.getcwd ()); close_out c\n" marker in
    let check_clean () =
      let private_dir = In_channel.read_all marker in
      check (not (Stdlib.Sys.file_exists private_dir)) "private directory leaked"
    in
    let env entries name = List.Assoc.find entries name ~equal:String.equal in
    check (Option.equal String.equal
      (Loader.config_path ~getenv:(env [ "XDG_CONFIG_HOME", "/xdg"; "HOME", "/home/test" ]))
      (Some "/xdg/ches/config.ml")) "XDG path";
    List.iter [ ""; "relative" ] ~f:(fun xdg ->
      check (Option.equal String.equal
        (Loader.config_path ~getenv:(env [ "XDG_CONFIG_HOME", xdg; "HOME", "/home/test" ]))
        (Some "/home/test/.config/ches/config.ml")) "HOME fallback");
    check (Option.is_none (Loader.config_path ~getenv:(env []))) "no location";
    let%bind missing = Loader.load ~path () in
    check (Settings.equal (ok missing) Settings.default) "missing defaults";
    let%bind absent_env = Loader.For_testing.load ~getenv:(env []) () in
    check (Settings.equal (ok absent_env) Settings.default) "missing environment defaults";
    let%bind result = load (remember ^ {|open Ches_config
let () =
  let words = String.split_on_char ',' "hello,world" in
  if List.length words = 2 then Completion.set_enabled false;
  Completion.set_ghost_preview true;
  Completion.set_min_prefix_chars (List.fold_left (+) 0 [1; 2]);
  Completion.set_prefer_local_snippets false;
  View.set_line_numbers true;
  Theme.set (String.concat "-" ["custom"; "theme"])
|}) in
    let expected : Settings.t =
      { completion_enabled = false; completion_ghost_preview = true
      ; completion_min_prefix_chars = 3; completion_prefer_local_snippets = false
      ; line_numbers = true; theme = "custom-theme" } in
    check (Settings.equal (ok result) expected) "real Stdlib configuration";
    check_clean ();
    let%bind defaults = load "let () = ()" in
    check (Settings.equal (ok defaults) Settings.default) "fresh defaults each load";
    let%bind result = load "open Ches_config\nlet () = Completion.set_min_prefix_chars 0" in
    check (contains (error result) "must be positive") "prefix validation";
    let%bind result = load "open Ches_config\nlet () = Theme.set \"  \"" in
    check (contains (error result) "nonempty") "theme validation";
    check (Result.is_error (Settings.validate { Settings.default with theme = "" })) "snapshot theme validation";
    let%bind result = load (remember ^ "let () = failwith \"config exception\"") in
    check (contains (error result) "config exception") "exception diagnostic";
    check_clean ();
    let%bind result = load "\nlet bad = this_name_does_not_exist\n" in
    let diagnostic = error result in
    check (contains diagnostic (Filename.basename path) && contains diagnostic "line 2")
      "original config filename/line";
    let runtime_marker = Filename.concat root "runtime must not start" in
    let mark_runtime = sprintf "let () = close_out (open_out %S)\n" runtime_marker in
    let%bind result = load (mark_runtime ^ "let bad = this_name_does_not_exist\n") in
    ignore (error result : string);
    check (not (Stdlib.Sys.file_exists runtime_marker)) "compile error executed configuration";
    let%bind result = load "let () = exit 7" in
    check (contains (error result) "7") "nonzero exit";
    let%bind result = load "let () = exit 0" in
    check (contains (error result) "Invalid settings result") "exit without protocol";
    write mark_runtime;
    let%bind result = Loader.For_testing.load ~path ~compiler:(Filename.concat root "missing compiler") () in
    ignore (error result : string);
    check (not (Stdlib.Sys.file_exists runtime_marker)) "missing compiler executed configuration";
    let%bind result = load {|let () =
  let chunk = String.make 8192 'x' in
  for _ = 1 to 256 do print_string chunk; prerr_string chunk done;
  print_endline "CHES_SETTINGS_1\nfalse\nfalse\n0";
  Ches_config.View.set_line_numbers true
|} in
    check (ok result).line_numbers "stdout noise contaminated protocol";
    let%bind result = load {|let () =
  prerr_string (String.make (2 * 1024 * 1024) 'e');
  failwith "after oversized diagnostic"
|} in
    check (String.length (error result) <= 1024 * 1024 + 1024) "unbounded diagnostic";
    let%bind result = load {|let () = at_exit (fun () ->
  let c = open_out "settings.result" in output_string c "CHES_SETTINGS_999\n"; close_out c)
|} in
    check (contains (error result) "malformed") "malformed result accepted";
    let%bind result = load {|let () = at_exit (fun () ->
  let c = open_out_bin "settings.result" in
  output_string c "CHES_SETTINGS_1\ntrue\nfalse\n";
  output_string c (String.make (512 * 1024) '\000');
  output_string c "\ntrue\nfalse\n76696d2d636c6173736963\n"; close_out c)
|} in
    check (String.length (error result) <= 1024 * 1024 + 1024)
      "malformed protocol expanded diagnostic beyond limit";
    let%bind result = load {|let () = at_exit (fun () ->
  let c = open_out "settings.result" in
  output_string c "CHES_SETTINGS_1\ntrue\nfalse\n1\ntrue\nfalse\n_1\n"; close_out c)
|} in
    check (contains (error result) "encoding") "non-hex theme encoding accepted";
    let%bind result = load {|let () = at_exit (fun () ->
  let c = open_out "settings.result" in
  output_string c (String.make (1024 * 1024 + 1) 'x'); close_out c)
|} in
    check (contains (error result) "exceeds 1 MiB") "oversized result accepted";
    let%bind result = load "let () = Ches_config.theme := String.make (1024 * 1024) 'x'" in
    check (contains (error result) "exceeds 1 MiB") "writer did not bound result";
    let%bind result = load (String.make (1024 * 1024 + 1) ' ') in
    check (contains (error result) "exceeds 1 MiB") "oversized source accepted";
    (* Even bypassing setters cannot bypass host-side validation. *)
    let%bind result = load "let () = Ches_config.min_prefix_chars := -1" in
    check (contains (error result) "must be positive") "result validation";
    write (remember ^ "let () = while true do () done");
    let%bind result = Loader.For_testing.load ~path ~runtime_timeout:0.1 () in
    check (contains (error result) "timed out") "runtime deadline";
    check_clean ();
    (* Fake compiler is itself ordinary OCaml compiled with the real ocamlc.
       This exercises compile supervision without changing PATH globally. *)
    let fake_source = Filename.concat root "slow compiler.ml" in
    let fake_compiler = Filename.concat root "slow compiler.exe" in
    Out_channel.write_all fake_source ~data:(remember ^ "let () = while true do () done");
    let%bind () = Process.run_exn ~prog:"ocamlc" ~args:[ "-o"; fake_compiler; fake_source ] ()
      >>| fun _ -> () in
    Core_unix.unlink marker;
    let%bind result = Loader.For_testing.load ~path:(Filename.concat root "absent.ml")
      ~compiler:fake_compiler ~compile_timeout:0.1 () in
    check (Settings.equal (ok result) Settings.default) "missing file defaults with compiler override";
    check (not (Stdlib.Sys.file_exists marker)) "missing configuration started compiler";
    write "let () = ()";
    let%bind result = Loader.For_testing.load ~path ~compiler:fake_compiler ~compile_timeout:0.1 () in
    check (contains (error result) "timed out") "compile deadline";
    check_clean ();
    (* Use Stdlib's process facility to exercise descendant cleanup. *)
    let child_pid = Filename.concat root "child pid" in
    write (remember ^ sprintf {|let () =
  ignore (Sys.command %S);
  while true do () done
|} (sprintf "sleep 30 & printf '%%s' $! > %s" (Filename.quote child_pid)));
    let%bind result = Loader.For_testing.load ~path ~runtime_timeout:0.2 () in
    check (contains (error result) "timed out") "descendant test deadline";
    let pid = Int.of_string (In_channel.read_all child_pid) in
    let running pid =
      try
        let stat = In_channel.read_all (sprintf "/proc/%d/stat" pid) in
        let pos = String.rindex_exn stat ')' in
        not (Char.equal stat.[pos + 2] 'Z')
      with _ -> false
    in
    check (not (running pid)) "child survived process-group termination";
    check_clean ();
    let%bind result = load (remember ^ sprintf "let () = ignore (Sys.command %S)\n"
      (sprintf "sleep 30 & printf '%%s' $! > %s" (Filename.quote child_pid))) in
    check (Settings.equal (ok result) Settings.default) "successful parent result";
    let pid = Int.of_string (In_channel.read_all child_pid) in
    check (not (running pid)) "child survived successful parent exit";
    check_clean ();
    print_endline "configuration tests passed";
    return ())
;;

let () =
  don't_wait_for (
    let%bind result = Monitor.try_with main in
    match result with
    | Ok () -> Shutdown.exit 0
    | Error exn -> eprintf "%s\n%!" (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
