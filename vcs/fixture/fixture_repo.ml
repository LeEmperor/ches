open! Core
module Exec = Ches_vcs.Exec
module Job = Ches_vcs.Job

type t =
  { dir : string
  ; work : string
  ; remote : string option
  }
[@@deriving sexp_of]

(* 2026-01-01T00:00:00Z: fixed so that commit hashes are reproducible. *)
let date = "1767225600 +0000"

let isolation t =
  [ "GIT_CONFIG_GLOBAL", "/dev/null"
  ; "GIT_CONFIG_NOSYSTEM", "1"
  ; "GIT_AUTHOR_NAME", "Ches Test"
  ; "GIT_AUTHOR_EMAIL", "ches-test@example.invalid"
  ; "GIT_COMMITTER_NAME", "Ches Test"
  ; "GIT_COMMITTER_EMAIL", "ches-test@example.invalid"
  ; "GIT_AUTHOR_DATE", date
  ; "GIT_COMMITTER_DATE", date
  ; "GIT_TERMINAL_PROMPT", "0"
  ; "GIT_CEILING_DIRECTORIES", t.dir
  ; "HOME", t.dir
  ; "LC_ALL", "C"
  ]
;;

(* Every inherited GIT_* variable can redirect or reconfigure git (GIT_DIR,
   GIT_INDEX_FILE, GIT_CONFIG_COUNT, GIT_SSH_COMMAND, GIT_TRACE, ...): drop them all. *)
let inherited () =
  Core_unix.environment ()
  |> Array.to_list
  |> List.filter_map ~f:(fun binding -> String.lsplit2 binding ~on:'=')
  |> List.filter ~f:(fun (name, _) -> not (String.is_prefix name ~prefix:"GIT_"))
;;

let environment t =
  let ours = isolation t in
  List.filter (inherited ()) ~f:(fun (name, _) ->
    not (List.Assoc.mem ours name ~equal:String.equal))
  @ ours
;;

let with_temp f =
  let path = Filename_unix.temp_file "ches-vcs-fixture" "" in
  Exn.protect
    ~f:(fun () -> f path)
    ~finally:(fun () -> try Core_unix.unlink path with
      | _ -> ())
;;

let unix_message = function
  | Core_unix.Unix_error (error, _, _) -> Core_unix.Error.message error
  | exn -> Exn.to_string exn
;;

let spawn ~env (spec : Exec.Spec.t) : Exec.Result.t =
  with_temp (fun out ->
    with_temp (fun err ->
      with_temp (fun input ->
        let stdin_path =
          match spec.stdin with
          | Null -> "/dev/null"
          | Data data ->
            Out_channel.write_all input ~data;
            input
        in
        let stdin_fd = Core_unix.openfile stdin_path ~mode:[ O_RDONLY ] in
        let out_fd = Core_unix.openfile out ~mode:[ O_WRONLY; O_TRUNC ] in
        let err_fd = Core_unix.openfile err ~mode:[ O_WRONLY; O_TRUNC ] in
        let start = Time_ns.now () in
        let status =
          Exn.protect
            ~f:(fun () ->
              match
                Core_unix.create_process_with_fds
                  ~working_dir:spec.cwd
                  ~env:(`Replace env)
                  ~prog:spec.prog
                  ~args:spec.args
                  ~stdin:(Use_this stdin_fd)
                  ~stdout:(Use_this out_fd)
                  ~stderr:(Use_this err_fd)
                  ()
              with
              | exception exn -> Exec.Status.Not_started (unix_message exn)
              | { pid; _ } ->
                (match Core_unix.waitpid pid with
                 | Ok () -> Exited 0
                 | Error (`Exit_non_zero code) -> Exited code
                 | Error (`Signal signal) -> Signaled (Signal.to_string signal)))
            ~finally:(fun () ->
              List.iter [ stdin_fd; out_fd; err_fd ] ~f:(fun fd -> Core_unix.close fd))
        in
        let elapsed =
          match status with
          | Not_started _ -> Time_ns.Span.zero
          | Exited _ | Signaled _ -> Time_ns.diff (Time_ns.now ()) start
        in
        let stdout = In_channel.read_all out in
        let stderr = In_channel.read_all err in
        { Exec.Result.status
        ; stdout = String.prefix stdout spec.stdout_limit
        ; stdout_truncated = String.length stdout > spec.stdout_limit
        ; stderr = String.suffix stderr spec.stderr_limit
        ; stderr_truncated = String.length stderr > spec.stderr_limit
        ; timed_out = false
        ; cancelled = false
        ; elapsed
        })))
;;

let read_file ({ path; limit } : Job.File_read.t) : Job.File_read.Result.t =
  match Core_unix.openfile path ~mode:[ O_RDONLY ] with
  | exception Core_unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Missing
  | exception exn -> Failed (unix_message exn)
  | fd ->
    Exn.protect
      ~f:(fun () ->
        let buffer = Bytes.create (limit + 1) in
        let rec fill pos =
          if pos > limit
          then pos
          else (
            match Core_unix.read fd ~buf:buffer ~pos ~len:(limit + 1 - pos) with
            | 0 -> pos
            | n -> fill (pos + n))
        in
        match fill 0 with
        | exception exn -> Job.File_read.Result.Failed (unix_message exn)
        | length ->
          Contents
            { text = Bytes.To_string.sub buffer ~pos:0 ~len:(Int.min length limit)
            ; truncated = length > limit
            })
      ~finally:(fun () -> Core_unix.close fd)
;;

let run_steps t steps =
  List.map steps ~f:(fun (step : Job.Step.t) ->
    let outcome : Job.Step.Outcome.t =
      match step with
      | Run spec -> Ran (spawn ~env:(environment t @ spec.env) spec)
      | Read_file read -> Read (read_file read)
    in
    { Job.Step_report.step; outcome })
;;

let run t spec =
  match run_steps t [ Run spec ] with
  | [ { outcome = Ran result; _ } ] -> result
  | _ -> assert false
;;

let git ?cwd t args =
  let cwd = Option.value cwd ~default:t.work in
  let spec = Exec.Spec.create ~kind:Mutate ~cwd "git" args in
  let result = run t spec in
  if Exec.Result.succeeded result
  then result.stdout
  else
    raise_s
      [%message
        "Fixture git command failed"
          ~command:(Exec.Spec.to_string_hum spec)
          ~status:(Exec.Result.status_hum result)
          ~stderr:(result.stderr : string)]
;;

let rec remove_tree path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Array.iter (Sys_unix.readdir path) ~f:(fun name -> remove_tree (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let remove t =
  match Core_unix.lstat t.dir with
  | exception Core_unix.Unix_error (ENOENT, _, _) -> ()
  | _ -> remove_tree t.dir
;;

let create ?(remote = false) () =
  let dir = Filename_unix.realpath (Filename_unix.temp_dir "ches-vcs-fixture" "") in
  let t =
    { dir
    ; work = Filename.concat dir "work"
    ; remote = Option.some_if remote (Filename.concat dir "remote.git")
    }
  in
  try
    Core_unix.mkdir t.work;
    ignore (git t [ "init"; "-q"; "-b"; "main" ] : string);
    Option.iter t.remote ~f:(fun remote ->
      ignore (git ~cwd:dir t [ "init"; "-q"; "--bare"; "-b"; "main"; remote ] : string);
      ignore (git t [ "remote"; "add"; "origin"; remote ] : string));
    t
  with
  | exn ->
    remove t;
    raise exn
;;

let with_repo ?remote f =
  let t = create ?remote () in
  Exn.protect ~f:(fun () -> f t) ~finally:(fun () -> remove t)
;;

let path t relative = Filename.concat t.work relative

let rec mkdir_p path =
  match Core_unix.mkdir path with
  | () -> ()
  | exception Core_unix.Unix_error (EEXIST, _, _) -> ()
  | exception Core_unix.Unix_error (ENOENT, _, _) ->
    mkdir_p (Filename.dirname path);
    Core_unix.mkdir path
;;

let write t relative data =
  let path = path t relative in
  mkdir_p (Filename.dirname path);
  Out_channel.write_all path ~data
;;

let plain_dir t name =
  let path = Filename.concat t.dir name in
  mkdir_p path;
  path
;;

let commit_all t message =
  ignore (git t [ "add"; "-A" ] : string);
  ignore (git t [ "commit"; "-q"; "-m"; message ] : string);
  String.strip (git t [ "rev-parse"; "HEAD" ])
;;
