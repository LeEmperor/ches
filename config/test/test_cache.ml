open Core
open Async
open Ches_config_runtime

let check condition message = if not condition then failwith message
let ok = function Ok value -> value | Error message -> failwith message
let failed result = check (Result.is_error result) "expected failure"

let main () =
  let root = Core_unix.mkdtemp "/tmp/ches-cache-tests-" in
  Monitor.protect ~finally:(fun () -> In_thread.run (fun () -> Compiled_cache.remove root)) (fun () ->
    let file name = Filename.concat root name in
    let path = file "user.ml" in
    let cache_dir = file "cache" in
    let compiler = file "compiler" in
    let counter = file "compiles" in
    let executions = file "executions" in
    let data = file "data" in
    let real_compiler = Compiled_cache.resolve ~getenv:Sys.getenv "ocamlc" in
    let wrapper suffix =
      Out_channel.write_all compiler ~data:(sprintf
        "#!/bin/sh\nif [ \"$1\" != '-config' ]; then printf 'compile\\n' >> %s; fi\nexec %s \"$@\"\n# %s\n"
        (Filename.quote counter) (Filename.quote real_compiler) suffix);
      Core_unix.chmod compiler ~perm:0o700
    in
    wrapper "one";
    let count path = if Stdlib.Sys.file_exists path then List.length (In_channel.read_lines path) else 0 in
    let source = sprintf {|let () =
  let c = open_out_gen [Open_creat; Open_append; Open_text] 0o600 %S in
  output_string c (Sys.getcwd () ^ "\n"); close_out c;
  let c = open_in %S in let value = input_line c in close_in c;
  Ches_config.Theme.set (value ^ (match Sys.getenv_opt "OCAMLPARAM" with None -> "" | Some s -> s));
  Ches_config.Signature_help.set_enabled (value = "first");
  Ches_config.Completion.set_color ~role:"detail" (if value = "first" then "#AbC123" else "#456DEF");
  if value = "first" then Ches_config.Completion.set_color ~role:"documentation" "#112233";
  Ches_config.Snippets.add ~id:"fresh" ~prefix:"q" value
|} executions data in
    Out_channel.write_all path ~data:source;
    Out_channel.write_all data ~data:"first\n";
    let load ?api_source ?getenv ?runtime_timeout ?(path = path) ?(compiler = compiler) ?(cache_dir = cache_dir) () =
      Loader.For_testing.load ~path ~compiler ~cache_dir ?api_source ?getenv ?runtime_timeout ()
    in
    let timed f =
      let start = Time_ns.now () in
      let%map result = f () in
      result, Time_ns.Span.to_ms (Time_ns.diff (Time_ns.now ()) start)
    in
    let%bind cold, cold_ms = timed load in
    check (String.equal (ok cold).theme "first") "cold load";
    check (count counter = 1) "cold compilation count";
    Out_channel.write_all data ~data:"second\n";
    let%bind warm, warm_ms = timed load in
    check (String.equal (ok warm).theme "second") "cached settings instead of program";
    check ((ok cold).signature_help_enabled && not (ok warm).signature_help_enabled)
      "cached signature settings instead of program";
    check ([%equal: (string * string) list] (ok cold).completion_colors
        ["detail", "#abc123"; "documentation", "#112233"]
      && [%equal: (string * string) list] (ok warm).completion_colors
        ["detail", "#456def"])
      "cached colors instead of fresh values or fresh empty role defaults";
    let body settings = match settings.Settings.snippets with
      | [Ches_completion.User_snippets.Add declaration] -> declaration.body
      | _ -> failwith "missing fresh snippet" in
    check (String.equal (body (ok cold)) "first" && String.equal (body (ok warm)) "second")
      "cached snippet declarations instead of program";
    check (count counter = 1 && count executions = 2) "warm load did not reuse compilation and execute";
    check (String.equal (In_channel.read_all path) source) "loader wrote user configuration";
    let cwd = In_channel.read_lines executions in
    check (List.length (List.dedup_and_sort cwd ~compare:String.compare) = 2) "cwd reused";
    List.iter cwd ~f:(fun path -> check (not (Stdlib.Sys.file_exists path)) "execution cwd leaked");
    let entry () =
      Stdlib.Sys.readdir cache_dir |> Array.to_list
      |> List.filter ~f:Compiled_cache.owned_entry |> List.hd_exn
      |> Filename.concat cache_dir
    in
    let program () = Filename.concat (entry ()) "program" in
    check ((Core_unix.stat cache_dir).st_perm land 0o077 = 0) "cache directory permissions";
    check ((Core_unix.stat (program ())).st_perm land 0o077 = 0) "program permissions";
    Out_channel.write_all (program ()) ~data:"corrupt";
    let%bind result = load () in
    ignore (ok result : Settings.t);
    check (count counter = 2) "corrupt artifact did not recompile";
    Out_channel.write_all (Filename.concat (entry ()) "metadata") ~data:"corrupt metadata";
    let%bind result = load () in
    ignore (ok result : Settings.t);
    check (count counter = 3) "corrupt metadata did not recompile";
    (* Unavailable interpreter must be discovered before user execution. *)
    let cached_program = program () in
    let bytes = In_channel.read_all cached_program in
    let newline = String.index_exn bytes '\n' in
    Out_channel.write_all cached_program ~data:("#!/missing/runtime" ^ String.drop_prefix bytes newline);
    let%bind result = load () in
    ignore (ok result : Settings.t);
    check (count counter = 4) "unavailable bytecode runtime did not recompile";
    let changed_api = Api_source.source ^ "\n(* cache identity test *)\n" in
    let%bind result = load ~api_source:changed_api () in
    ignore (ok result : Settings.t);
    check (count counter = 5) "API invalidation";
    let other_path = file "other.ml" in
    Out_channel.write_all other_path ~data:source;
    let%bind result = load ~path:other_path () in
    ignore (ok result : Settings.t);
    check (count counter = 6) "original path invalidation";
    Out_channel.write_all path ~data:(source ^ "\n(* changed *)\n");
    let%bind result = load () in
    ignore (ok result : Settings.t);
    check (count counter = 7) "source invalidation";
    wrapper "two";
    let%bind result = load () in
    ignore (ok result : Settings.t);
    check (count counter = 8) "same-path same-size compiler content invalidation";
    let link = file "compiler-link" in
    Core_unix.symlink ~target:compiler ~link_name:link;
    let%bind result = load ~compiler:link () in
    ignore (ok result : Settings.t);
    let second_compiler = file "compiler-two" in
    Compiled_cache.copy compiler second_compiler;
    Core_unix.chmod second_compiler ~perm:0o700;
    Core_unix.unlink link;
    Core_unix.symlink ~target:second_compiler ~link_name:link;
    let%bind result = load ~compiler:link () in
    ignore (ok result : Settings.t);
    check (count counter = 10) "compiler symlink target invalidation";
    let getenv name = if String.equal name "OCAMLPARAM" then Some "_,w=-a" else Sys.getenv name in
    let%bind result = load ~getenv () in
    check (String.equal (ok result).theme "second_,w=-a") "local compile/runtime environment";
    check (count counter = 11) "compile environment invalidation";
    let%bind result = load ~getenv () in
    ignore (ok result : Settings.t);
    check (count counter = 11) "environment cache reuse";
    let blocked = file "not-a-directory" in
    Out_channel.write_all blocked ~data:"unchanged";
    let%bind result = load ~cache_dir:(Filename.concat blocked "cache") () in
    ignore (ok result : Settings.t);
    check (count counter = 12 && String.equal (In_channel.read_all blocked) "unchanged") "cache failure fallback";
    let readonly = file "readonly" in
    Core_unix.mkdir readonly ~perm:0o500;
    let%bind result = load ~cache_dir:readonly () in
    ignore (ok result : Settings.t);
    check (count counter = 13) "unwritable cache fallback";
    Core_unix.chmod readonly ~perm:0o700;
    let isolated = file "parallel-cache" in
    let before = count executions in
    let%bind results = Deferred.all (List.init 6 ~f:(fun _ -> load ~cache_dir:isolated ())) in
    List.iter results ~f:(fun result -> ignore (ok result : Settings.t));
    check (count executions = before + 6) "concurrent execution count";
    let compiles = count counter in
    let%bind results = Deferred.all (List.init 6 ~f:(fun _ -> load ~cache_dir:isolated ())) in
    List.iter results ~f:(fun result -> ignore (ok result : Settings.t));
    check (count counter = compiles) "concurrent warm compilation";
    let single_entry = Stdlib.Sys.readdir isolated |> Array.to_list
      |> List.find_exn ~f:Compiled_cache.owned_entry |> Filename.concat isolated in
    Core_unix.chmod (Filename.concat single_entry "program") ~perm:0o600;
    let%bind result = load ~cache_dir:isolated () in
    ignore (ok result : Settings.t);
    check (count counter = compiles + 1) "nonexecutable cached artifact reused";
    let by_name_env name = if String.equal name "PATH" then Some root else Sys.getenv name in
    let%bind result = load ~compiler:"compiler" ~getenv:by_name_env () in
    ignore (ok result : Settings.t);
    let before = count counter in
    let%bind result = load ~compiler:"compiler" ~getenv:by_name_env () in
    ignore (ok result : Settings.t);
    check (count counter = before) "injected PATH compiler reuse";
    let alternate_bin = file "alternate-bin" in
    Core_unix.mkdir alternate_bin ~perm:0o700;
    let alternate_compiler = Filename.concat alternate_bin "compiler" in
    Compiled_cache.copy compiler alternate_compiler;
    Core_unix.chmod alternate_compiler ~perm:0o700;
    let alternate_env name = if String.equal name "PATH" then Some alternate_bin else Sys.getenv name in
    let%bind result = load ~compiler:"compiler" ~getenv:alternate_env () in
    ignore (ok result : Settings.t);
    check (count counter = before + 1) "resolved PATH identity invalidation";
    (* A preprocessor is an external compile dependency, not just an env string.
       Replacing its content must never return the old compiled snapshot. *)
    let preprocessor = file "preprocessor" in
    let write_pp theme =
      Out_channel.write_all preprocessor ~data:(sprintf
        "#!/bin/sh\n/bin/cat \"$1\"\ncase \"$1\" in *user_config.ml) printf '\\nlet () = Ches_config.Theme.set %s\\n';; esac\n"
        (sprintf "%S" theme));
      Core_unix.chmod preprocessor ~perm:0o700 in
    let pp_env name = if String.equal name "OCAMLPARAM"
      then Some ("_,pp=" ^ preprocessor) else Sys.getenv name in
    write_pp "pp-first";
    let%bind result = load ~getenv:pp_env () in
    check (String.equal (ok result).theme "pp-first") "preprocessor cold result";
    let before = count counter in
    write_pp "pp-second";
    let%bind result = load ~getenv:pp_env () in
    check (String.equal (ok result).theme "pp-second" && count counter = before + 1)
      "preprocessor dependency served stale snapshot";
    write_pp "unused";
    Out_channel.write_all preprocessor ~data:"#!/bin/sh\nexit 1\n";
    let before = count executions in
    let%bind result = load ~getenv:pp_env () in
    failed result;
    check (count executions = before) "preprocessor failure executed an outdated snapshot";
    let failing = source ^ "\nlet () = failwith \"runtime failure\"\n" in
    Out_channel.write_all path ~data:failing;
    let before = count executions in
    let%bind result = load () in
    failed result;
    let compiles = count counter in
    let%bind result = load () in
    failed result;
    check (count counter = compiles && count executions = before + 2) "runtime failure retried user code";
    let%bind () = Deferred.List.iter ~how:`Sequential
      [ "let () = exit 0", "missing protocol"
      ; "let () = at_exit (fun () -> let c = open_out Sys.argv.(1) in output_string c \"bad\\n\"; close_out c)", "bad protocol"
       ; "let () = Ches_config.theme := \"\"", "invalid settings"
       ; "let () = Ches_config.completion_colors := [\"detail\", \"invalid\"]", "invalid colors"
      ; "let () = while true do () done", "timeout"
      ] ~f:(fun (ending, label) ->
        Out_channel.write_all path ~data:(source ^ "\n" ^ ending ^ "\n");
        let before = count executions in
        let%bind result = load ~runtime_timeout:0.1 () in
        failed result;
        let compiles = count counter in
        let%map result = load ~runtime_timeout:0.1 () in
        failed result;
        check (count executions = before + 2 && count counter = compiles)
          (label ^ " retried runtime or failed to use cached program")) in
    let before = count executions in
    let entries_before = Array.length (Stdlib.Sys.readdir cache_dir) in
    Out_channel.write_all path ~data:(source ^ "\nlet bad = undefined_identifier\n");
    let%bind result = load () in
    failed result;
    check (count executions = before) "compile failure executed user code or stale snapshot";
    check (Array.length (Stdlib.Sys.readdir cache_dir) = entries_before) "compile failure published partial entry";
    let%bind result = Loader.For_testing.load ~path ~compiler:(file "absent") ~cache_dir () in
    failed result;
    (* Default test entry point must not touch any real cache. *)
    Out_channel.write_all path ~data:source;
    let%bind result = Loader.For_testing.load ~path ~compiler () in
    ignore (ok result : Settings.t);
    Out_channel.write_all path ~data:"let () = Ches_config.Theme.set __FILE__\n";
    let%bind result = load () in
    check (String.equal (ok result).theme path) "original __FILE__ on cold load";
    let%bind result = load () in
    check (String.equal (ok result).theme path) "original __FILE__ on warm load";
    let env pairs name = List.Assoc.find pairs name ~equal:String.equal in
    List.iter [""; "relative"] ~f:(fun xdg ->
      check (Option.equal String.equal
        (Loader.For_testing.cache_path ~getenv:(env ["XDG_CACHE_HOME", xdg; "HOME", "/home/test"]))
        (Some "/home/test/.cache/ches/config")) "cache HOME fallback");
    check (Option.equal String.equal
      (Loader.For_testing.cache_path ~getenv:(env ["XDG_CACHE_HOME", "/xdg"]))
      (Some "/xdg/ches/config")) "cache XDG location";
    check (Option.is_none (Loader.For_testing.cache_path ~getenv:(env []))) "absent cache location";
    check (Option.is_none (Loader.For_testing.cache_path ~getenv:(env ["HOME", "relative"]))) "relative HOME cache";
    (* Pruning only recognizes owned key directories, leaves unrelated files alone. *)
    let unrelated = Filename.concat cache_dir "keep-me" in
    Out_channel.write_all unrelated ~data:"keep";
    let foreign = Filename.concat cache_dir (Compiled_cache.digest "foreign-cache") in
    Core_unix.mkdir foreign ~perm:0o700;
    Out_channel.write_all (Filename.concat foreign "program") ~data:"foreign";
    Out_channel.write_all (Filename.concat foreign "metadata") ~data:"foreign metadata";
    let extra = Filename.concat cache_dir ("ches-" ^ Compiled_cache.digest "extra-files") in
    Core_unix.mkdir extra ~perm:0o700;
    Out_channel.write_all (Filename.concat extra "keep") ~data:"extra";
    let%bind () = Deferred.List.iter (List.init 18 ~f:Fn.id) ~how:`Sequential ~f:(fun i ->
      Out_channel.write_all path ~data:(sprintf "let () = Ches_config.Theme.set %S\n" (Int.to_string i));
      let%map result = load () in ignore (ok result : Settings.t)) in
    let entries = Stdlib.Sys.readdir cache_dir |> Array.to_list |> List.filter ~f:(fun name ->
      Compiled_cache.owned_entry name && not (String.equal (Filename.concat cache_dir name) extra)) in
    check (List.length entries <= 16) "cache entry bound";
    check (String.equal (In_channel.read_all unrelated) "keep") "pruning removed unrelated file";
    check (String.equal (In_channel.read_all (Filename.concat foreign "program")) "foreign")
      "pruning removed unrelated hex-named cache";
    check (String.equal (In_channel.read_all (Filename.concat extra "keep")) "extra")
      "pruning recursively removed foreign contents";
    let%bind results = Deferred.all (List.init 6 ~f:(fun i ->
      let parallel_path = file (sprintf "parallel-%d.ml" i) in
      Out_channel.write_all parallel_path ~data:(sprintf "let () = Ches_config.Theme.set %S\n"
        (sprintf "parallel-%d" i));
      load ~path:parallel_path ())) in
    List.iteri results ~f:(fun i result ->
      check (String.equal (ok result).theme (sprintf "parallel-%d" i))
        "concurrent publication/pruning returned wrong helper");
    let entries = Stdlib.Sys.readdir cache_dir |> Array.to_list |> List.filter ~f:(fun name ->
      Compiled_cache.owned_entry name && not (String.equal (Filename.concat cache_dir name) extra)) in
    check (List.length entries <= 16) "concurrent pruning exceeded entry cap";
    check (String.equal (In_channel.read_all (Filename.concat foreign "program")) "foreign")
      "concurrent publication/pruning lost unrelated cache";
    let budget_dir = file "byte-budget" in
    Compiled_cache.prepare budget_dir;
    List.iter (List.init 14 ~f:Fn.id) ~f:(fun i ->
      let key = Compiled_cache.digest (Int.to_string i) in
      let entry = Filename.concat budget_dir ("ches-" ^ key) in
      Core_unix.mkdir entry ~perm:0o700;
      let program = Filename.concat entry "program" in
      Out_channel.write_all program ~data:"";
      Core_unix.chmod program ~perm:0o700;
      let metadata = Filename.concat entry "metadata" in
      Out_channel.write_all metadata ~data:("CHES_COMPILED_1\n" ^ key ^ "\n");
      Core_unix.chmod metadata ~perm:0o600;
      Core_unix.truncate program ~len:(Int64.of_int (5 * 1024 * 1024)));
    Compiled_cache.prune budget_dir;
    let bytes = Stdlib.Sys.readdir budget_dir |> Array.fold ~init:0 ~f:(fun sum name ->
      sum + Int64.to_int_exn (Core_unix.stat (Filename.concat (Filename.concat budget_dir name) "program")).st_size) in
    check (bytes <= 64 * 1024 * 1024) "cache byte bound";
    (* Symlinked roots/entries/files are cache misses; never follow them for
       publication, deletion, or restoring an executable. *)
    Out_channel.write_all path ~data:source;
    let safety_cache = file "safety-cache" in
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    let name = List.find_exn (Array.to_list (Stdlib.Sys.readdir safety_cache)) ~f:Compiled_cache.owned_entry in
    let safety_entry = Filename.concat safety_cache name in
    let saved = file "saved-entry" in
    Core_unix.rename ~src:safety_entry ~dst:saved;
    Core_unix.symlink ~target:saved ~link_name:safety_entry;
    let saved_program = In_channel.read_all (Filename.concat saved "program") in
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    check (String.equal saved_program (In_channel.read_all (Filename.concat saved "program")))
      "entry symlink altered target";
    check (Poly.equal (Core_unix.lstat safety_entry).st_kind Core_unix.S_LNK) "entry symlink replaced";
    Core_unix.unlink safety_entry;
    Core_unix.rename ~src:saved ~dst:safety_entry;
    let safety_program = Filename.concat safety_entry "program" in
    let safety_metadata = Filename.concat safety_entry "metadata" in
    Core_unix.unlink safety_metadata;
    Core_unix.symlink ~target:unrelated ~link_name:safety_metadata;
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    check (String.equal (In_channel.read_all unrelated) "keep") "metadata symlink altered target";
    Core_unix.unlink safety_metadata;
    Out_channel.write_all safety_metadata ~data:(String.make 4097 'x');
    Core_unix.chmod safety_metadata ~perm:0o600;
    let before = count counter in
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    check (count counter = before + 1) "oversized metadata accepted";
    Out_channel.write_all safety_program ~data:(String.make 8192 'x');
    let before = count counter in
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    check (count counter = before + 1) "unterminated runtime header accepted";
    Core_unix.unlink safety_program;
    Core_unix.symlink ~target:unrelated ~link_name:safety_program;
    let%bind result = load ~cache_dir:safety_cache () in
    ignore (ok result : Settings.t);
    check (String.equal (In_channel.read_all unrelated) "keep") "program symlink altered target";
    let root_link = file "cache-link" in
    Core_unix.symlink ~target:cache_dir ~link_name:root_link;
    let before = count counter in
    let%bind result = load ~cache_dir:root_link () in
    ignore (ok result : Settings.t);
    check (count counter = before + 1) "cache root symlink accepted";
    let public = file "public-cache" in
    Core_unix.mkdir public ~perm:0o755;
    let before = count counter in
    let%bind result = load ~cache_dir:public () in
    ignore (ok result : Settings.t);
    check (count counter = before + 1 && Array.is_empty (Stdlib.Sys.readdir public))
      "nonprivate cache used instead of ephemeral fallback";
    (* Oversized regular files and FIFOs must be rejected without reading them. *)
    let bounded = file "bounded" in
    Out_channel.write_all bounded ~data:"";
    Core_unix.truncate bounded ~len:(Int64.of_int (Compiled_cache.max_bytes + 1));
    check (Result.is_error (Or_error.try_with (fun () -> Compiled_cache.file_digest bounded)))
      "oversized fingerprint accepted";
    Core_unix.unlink bounded;
    Core_unix.mkfifo bounded ~perm:0o600;
    check (Result.is_error (Or_error.try_with (fun () -> Compiled_cache.file_digest bounded)))
      "FIFO fingerprint accepted";
    let busy = file "busy-cache" in
    Compiled_cache.prepare busy;
    let lock = Core_unix.openfile busy ~mode:[O_RDONLY; O_CLOEXEC] in
    check (Core_unix.flock lock Core_unix.Flock_command.lock_exclusive) "test cache lock";
    let%bind result = Monitor.protect
      ~finally:(fun () -> Core_unix.close lock; return ())
      (fun () -> load ~cache_dir:busy ()) in
    ignore (ok result : Settings.t);
    check (Array.is_empty (Stdlib.Sys.readdir busy)) "busy cache published without a lock";
    check (not (List.exists (Array.to_list (Stdlib.Sys.readdir cache_dir))
      ~f:(String.is_prefix ~prefix:".pending-"))) "staging directory leaked";
    printf "compiled cache tests passed; cold %.2f ms, warm %.2f ms (%.2fx)\n%!"
      cold_ms warm_ms (cold_ms /. warm_ms);
    return ())
;;

let () =
  don't_wait_for (
    let%bind result = Monitor.try_with main in
    match result with
    | Ok () -> Shutdown.exit 0
    | Error exn -> eprintf "%s\n%!" (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
