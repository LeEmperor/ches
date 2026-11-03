open Core
open Async

let limit = 1024 * 1024

let config_path ~getenv =
  match getenv "XDG_CONFIG_HOME" with
  | Some root when not (String.is_empty root) && not (Filename.is_relative root) ->
    Some (Filename.concat root "ches/config.ml")
  | _ ->
    Option.bind (getenv "HOME") ~f:(fun home ->
      if String.is_empty home then None
      else Some (Filename.concat home ".config/ches/config.ml"))
;;

let read_bounded path =
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK ] in
  Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
    if not (Poly.equal (Core_unix.fstat fd).st_kind Core_unix.S_REG)
    then failwith "configuration/result must be a regular file";
    let bytes = Bytes.create (limit + 1) in
    let rec loop pos =
      if pos > limit then failwith "configuration/result exceeds 1 MiB";
      match Core_unix.read fd ~buf:bytes ~pos ~len:(limit + 1 - pos) with
      | 0 -> Bytes.To_string.sub bytes ~pos:0 ~len:pos
      | count -> loop (pos + count)
    in
    loop 0)
;;

let decode text =
  if String.length text > limit then failwith "settings result exceeds 1 MiB";
  let lines = ref (String.split text ~on:'\n') in
  let remaining_lines = ref (List.length !lines) in
  let next () = match !lines with
    | line :: rest -> lines := rest; decr remaining_lines; line
    | [] -> failwith "truncated settings result"
  in
  let boolean () = match next () with
    | "true" -> true
    | "false" -> false
    | _ -> failwith "invalid boolean in settings result"
  in
  let number name ~max =
    let value = next () in
    if String.is_empty value
       || not (String.for_all value ~f:Char.is_digit)
       || (String.length value > 1 && Char.equal value.[0] '0')
    then failwith ("invalid " ^ name ^ " in settings result");
    match Int.of_string_opt value with
    | Some n when n <= max -> n
    | _ -> failwith ("invalid or excessive " ^ name ^ " in settings result")
  in
  let hex () =
    let encoded = next () in
    if String.length encoded mod 2 <> 0 then failwith "invalid string encoding";
    let hex_digit = function
      | '0' .. '9' as c -> Char.to_int c - Char.to_int '0'
      | 'a' .. 'f' as c -> Char.to_int c - Char.to_int 'a' + 10
      | _ -> failwith "invalid string encoding"
    in
    String.init (String.length encoded / 2) ~f:(fun i ->
      Char.of_int_exn ((hex_digit encoded.[i * 2] * 16) + hex_digit encoded.[i * 2 + 1]))
  in
  if not (String.equal (next ()) "CHES_SETTINGS_2") then
    failwith "malformed or unsupported settings result";
  let completion_enabled = boolean () in
  let completion_ghost_preview = boolean () in
  let completion_min_prefix_chars = number "minimum prefix (must be positive)" ~max:Int.max_value in
  let completion_prefer_local_snippets = boolean () in
  let line_numbers = boolean () in
  let theme = hex () in
  let count = number "snippet count (maximum 1000)" ~max:1000 in
  let read_list count read =
    let rec loop remaining acc =
      if remaining = 0 then List.rev acc
      else let value = read () in loop (remaining - 1) (value :: acc)
    in
    loop count []
  in
  let snippets = read_list count (fun () ->
    let open Ches_completion.User_snippets in
    match next () with
    | "disable" -> Disable (hex ())
    | "add" ->
      let id = hex () in
      let prefix = hex () in
      (* Every scope requires at least its terminating newline. *)
      let count = number "scope count" ~max:!remaining_lines in
      let scopes = read_list count hex in
      let description = match next () with
        | "none" -> None
        | "some" -> Some (hex ())
        | _ -> failwith "invalid description tag in settings result"
      in
      let body = hex () in
      Add { id; prefix; scopes; description; body }
    | _ -> failwith "invalid snippet operation in settings result") in
  (match !lines with
   | [ "" ] -> ()
   | _ -> failwith "malformed settings result framing");
  Settings.validate
    { completion_enabled; completion_ghost_preview; completion_min_prefix_chars
    ; completion_prefer_local_snippets; line_numbers; theme; snippets }
  |> Or_error.ok_exn
;;

(* Drain continuously but retain at most 1 MiB per stream. User stdout never
   participates in the result protocol. *)
let drain reader =
  let buffer = Bytes.create 8192 in
  let kept = Buffer.create 4096 in
  let rec loop () =
    match%bind Reader.read reader buffer with
    | `Eof -> return (Buffer.contents kept)
    | `Ok length ->
      Buffer.add_subbytes kept buffer ~pos:0 ~len:(Int.min length (limit - Buffer.length kept));
      loop ()
  in
  loop ()
;;

let run ~cwd ~prog ~args ~timeout =
  let%bind created = Process.create ~prog ~args ~working_dir:cwd
    ~setpgid:Core_unix.Pgid.new_process_group ~buf_len:8192 () in
  match created with
  | Error error -> return (Error (Error.to_string_hum error))
  | Ok process ->
    let signaled = ref false in
    let kill () =
      if not !signaled then (
        signaled := true;
        try ignore (Signal_unix.send Signal.kill (`Group (Process.pid process))
                    : [ `Ok | `No_such_process ]) with _ -> ())
    in
    let exited = Process.wait process in
    Monitor.protect ~finally:(fun () ->
      kill ();
      let%bind _ = exited in
      Deferred.all_unit
        [ Writer.close (Process.stdin process)
        ; Reader.close (Process.stdout process)
        ; Reader.close (Process.stderr process)
        ]) (fun () ->
    let stdout = Monitor.try_with (fun () -> drain (Process.stdout process)) in
    let stderr = Monitor.try_with (fun () -> drain (Process.stderr process)) in
    let stdin = Writer.close (Process.stdin process) in
    let%bind outcome = Clock_ns.with_timeout (Time_ns.Span.of_sec timeout) exited in
    (* Also remove children left behind by a successful parent. *)
    kill ();
    let%bind exit = exited in
    let%bind () = stdin in
    (* Descendants that deliberately detach can hold pipe descriptors open. Close
       readers rather than waiting indefinitely for EOF in that case. *)
    let%bind output = Clock_ns.with_timeout (Time_ns.Span.of_ms 100.)
      (Deferred.both stdout stderr) in
    let%bind () = Deferred.all_unit
      [ Reader.close (Process.stdout process); Reader.close (Process.stderr process) ] in
    let diagnostics = match output with
      | `Result (out, err) ->
        Result.ok err |> Option.value ~default:(Result.ok out |> Option.value ~default:"")
      | `Timeout -> "output pipes remained open after process exit"
    in
    match outcome, exit with
    | `Timeout, _ -> return (Error ("timed out: " ^ prog ^ "\n" ^ diagnostics))
    | `Result _, Ok () -> return (Ok ())
    | `Result _, Error status ->
      return (Error (sprintf "%s failed (%s)\n%s" prog
        (Sexp.to_string_hum ([%sexp_of: Unix.Exit_or_signal.error] status)) diagnostics)))
;;

let remove_directory root =
  let rec remove path =
    match (Core_unix.lstat path).st_kind with
    | S_DIR ->
      Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove (Filename.concat path name));
      Core_unix.rmdir path
    | _ -> Core_unix.unlink path
  in
  remove root
;;

let load_impl ?path ?(getenv = Sys.getenv) ?(compiler = "ocamlc")
    ?(compile_timeout = 10.) ?(runtime_timeout = 2.) () =
  let path = match path with Some _ -> path | None -> config_path ~getenv in
  match path with
  | None -> return (Ok Settings.default)
  | Some path ->
    let%bind source = In_thread.run (fun () ->
      try Ok (Some (read_bounded path)) with
      | Core_unix.Unix_error (ENOENT, _, _) -> Ok None
      | exn -> Error (Exn.to_string exn)) in
    match source with
    | Error error -> return (Error error)
    | Ok None -> return (Ok Settings.default)
    | Ok (Some source) ->
      let%bind result = Monitor.try_with (fun () ->
        let%bind root = In_thread.run (fun () -> Core_unix.mkdtemp "/tmp/ches-config-") in
        Monitor.protect ~finally:(fun () -> In_thread.run (fun () -> remove_directory root))
          (fun () ->
            let file name = Filename.concat root name in
            let%bind () = In_thread.run (fun () ->
              Out_channel.write_all (file "ches_config.ml") ~data:Api_source.source;
              Out_channel.write_all (file "user_config.ml")
                ~data:(sprintf "# 1 %S\n%s\n" path source);
              Out_channel.write_all (file "result_writer.ml")
                ~data:(sprintf "let () = Ches_config.write_result %S\n" (file "settings.result"))) in
            let%bind compiled = run ~cwd:root ~prog:compiler ~timeout:compile_timeout
              ~args:[ "-o"; "config.exe"; "ches_config.ml"; "user_config.ml"; "result_writer.ml" ] in
            match compiled with
            | Error error -> return (Error error)
            | Ok () ->
              let%bind executed = run ~cwd:root ~prog:(file "config.exe") ~args:[] ~timeout:runtime_timeout in
              match executed with
              | Error error -> return (Error error)
              | Ok () -> In_thread.run (fun () ->
                try Ok (decode (read_bounded (file "settings.result")))
                with exn -> Error ("Invalid settings result: " ^ Exn.to_string exn)))) in
      return (match result with Ok result -> result | Error exn -> Error (Exn.to_string exn))
;;

let load ?path () = load_impl ?path ()

module For_testing = struct
  let load = load_impl
  let decode text = Or_error.try_with (fun () -> decode text)
end
