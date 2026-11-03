(* Only compiled programs live here. All operations are best effort; callers
   always have a private compilation/execution directory to fall back to. *)
open Core

let digest text = Stdlib.Digest.to_hex (Stdlib.Digest.string text)
let max_bytes = 64 * 1024 * 1024

let with_input ~max path f =
  let bound = Int64.of_int max in
  let before = Core_unix.lstat path in
  if not (Poly.equal before.st_kind Core_unix.S_REG)
     || Int64.(before.st_size > bound) then failwith "invalid cache input";
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  let input = Core_unix.in_channel_of_descr fd in
  Exn.protect ~finally:(fun () -> In_channel.close input) ~f:(fun () ->
    let stat = Core_unix.fstat fd in
    if not (Poly.equal stat.st_kind Core_unix.S_REG)
       || stat.st_dev <> before.st_dev || stat.st_ino <> before.st_ino
       || Int64.(stat.st_size > bound) then failwith "cache input changed";
    f input (Int64.to_int_exn stat.st_size))
;;

let file_digest path =
  with_input ~max:max_bytes path (fun input length ->
    let result = Stdlib.Digest.channel input length |> Stdlib.Digest.to_hex in
    if Option.is_some (In_channel.input_char input) then failwith "cache input grew";
    result)
;;

let read ~max path =
  with_input ~max path (fun input length ->
    let text = Stdlib.really_input_string input length in
    if Option.is_some (In_channel.input_char input) then failwith "cache input grew";
    text)
;;

(* Stop inspecting a directory rather than doing unbounded cache maintenance. *)
let names ?(max_entries = 4096) path =
  let handle = Core_unix.opendir path in
  Exn.protect ~finally:(fun () -> Core_unix.closedir handle) ~f:(fun () ->
    let rec loop n acc =
      match Core_unix.readdir_opt handle with
      | None -> List.rev acc
      | Some ("." | "..") -> loop n acc
      | Some name ->
        if n >= max_entries then failwith "cache directory scan limit";
        loop (n + 1) (name :: acc)
    in loop 0 [])
;;

let location ~getenv =
  let absolute = function
    | Some path when not (String.is_empty path) && not (Filename.is_relative path) -> Some path
    | _ -> None
  in
  match absolute (getenv "XDG_CACHE_HOME") with
  | Some root -> Some (Filename.concat root "ches/config")
  | None -> Option.map (absolute (getenv "HOME")) ~f:(fun home ->
      Filename.concat home ".cache/ches/config")
;;

let executable path =
  let stat = Core_unix.stat path in
  if not (Poly.equal stat.st_kind Core_unix.S_REG) then failwith "not a regular executable";
  Core_unix.access path [ `Exec ] |> Result.ok_exn
;;

let resolve ~getenv prog =
  let absolute path =
    if Filename.is_relative path then Filename.concat (Core_unix.getcwd ()) path else path
  in
  if String.contains prog '/' then (executable prog; absolute prog)
  else
    String.split (Option.value (getenv "PATH") ~default:"/usr/bin:/bin") ~on:':'
    |> List.find_map ~f:(fun dir ->
      let path = absolute (Filename.concat (if String.is_empty dir then "." else dir) prog) in
      try executable path; Some path with _ -> None)
    |> Option.value_exn ~message:("compiler unavailable: " ^ prog)
;;

let identity path =
  let real = Filename_unix.realpath path in
  let stat = Core_unix.stat real in
  String.concat ~sep:"\000"
    [ path; real; Int.to_string stat.st_dev; Int.to_string stat.st_ino
    ; Int64.to_string stat.st_size; Float.to_string stat.st_mtime
    ; Float.to_string stat.st_ctime; file_digest real ]
;;

let rec mkdir path =
  try Core_unix.mkdir path ~perm:0o700 with
  | Core_unix.Unix_error (ENOENT, _, _) -> mkdir (Filename.dirname path); mkdir path
  | Core_unix.Unix_error (EEXIST, _, _) -> ()
;;

let prepare path =
  mkdir path;
  let stat = Core_unix.lstat path in
  if not (Poly.equal stat.st_kind Core_unix.S_DIR)
     || stat.st_uid <> Core_unix.getuid () || stat.st_perm land 0o777 <> 0o700
  then failwith "cache directory must be private and owned by current user";
  Core_unix.access path [ `Write; `Exec ] |> Result.ok_exn
;;

(* Lock the directory itself: no lock-file symlinks or persistent extra files.
   Contention simply disables this best-effort cache operation. *)
let with_lock ?(shared = false) dir f =
  prepare dir;
  let fd = Core_unix.openfile dir ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
    let before = Core_unix.lstat dir and opened = Core_unix.fstat fd in
    if not (Poly.equal opened.st_kind Core_unix.S_DIR)
       || before.st_dev <> opened.st_dev || before.st_ino <> opened.st_ino
       || not (Core_unix.flock fd (if shared then Core_unix.Flock_command.lock_shared
                                  else Core_unix.Flock_command.lock_exclusive))
    then failwith "cache busy or changed";
    f ())
;;

let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let copy source target =
  with_input ~max:max_bytes source (fun input length ->
    Out_channel.with_file target ~binary:true ~f:(fun output ->
      let buffer = Bytes.create 65536 in
      let rec loop remaining =
        if remaining > 0 then (
          let n = Stdlib.input input buffer 0 (Int.min remaining (Bytes.length buffer)) in
          if n = 0 then failwith "cache input shrank";
          Stdlib.output output buffer 0 n; loop (remaining - n))
      in loop length;
      if Option.is_some (In_channel.input_char input) then failwith "cache input grew"))
;;

let runtime program =
  let header = with_input ~max:max_bytes program (fun input _ ->
    let buffer = Buffer.create 128 in
    let rec loop () =
      if Buffer.length buffer >= 4096 then failwith "bytecode runtime header too long";
      match In_channel.input_char input with
      | Some '\n' -> Buffer.contents buffer
      | Some c -> Buffer.add_char buffer c; loop ()
      | None -> failwith "missing bytecode runtime header"
    in loop ()) in
  if not (String.is_prefix header ~prefix:"#!/") then failwith "unknown bytecode runtime";
  let path = String.drop_prefix header 2 in
  executable path;
  identity path
;;

let metadata ~key program =
  String.concat ~sep:"\n" [ "CHES_COMPILED_1"; key; file_digest program; digest (runtime program); "" ]
;;

let restore ~dir ~key ~target =
  try
    with_lock ~shared:true dir (fun () ->
    let entry = Filename.concat dir ("ches-" ^ key) in
    let stat = Core_unix.lstat entry in
    if not (Poly.equal stat.st_kind Core_unix.S_DIR)
       || stat.st_uid <> Core_unix.getuid () || stat.st_perm land 0o077 <> 0
    then failwith "invalid cache entry";
    List.iter ["program"; "metadata"] ~f:(fun name ->
      let stat = Core_unix.lstat (Filename.concat entry name) in
      if not (Poly.equal stat.st_kind Core_unix.S_REG)
         || stat.st_uid <> Core_unix.getuid () || stat.st_perm land 0o077 <> 0
         || stat.st_nlink <> 1 then failwith "invalid cache file");
    let meta = Filename.concat entry "metadata" in
    let expected = read ~max:4096 meta in
    executable (Filename.concat entry "program");
    copy (Filename.concat entry "program") target;
    if not (String.equal expected (metadata ~key target)) then failwith "cache integrity mismatch";
    Core_unix.chmod target ~perm:0o700;
    executable target;
    true)
  with _ -> (try Core_unix.unlink target with _ -> ()); false
;;

let owned_entry name =
  String.is_prefix name ~prefix:"ches-" && String.length name = 37
  && String.for_all (String.drop_prefix name 5) ~f:(function
    | '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
;;

(* Never recursively delete an entry. Extra files, subdirectories and symlinks
   make it somebody else's directory, even if its name resembles our namespace. *)
let entry_size path =
  let stat = Core_unix.lstat path in
  if not (Poly.equal stat.st_kind Core_unix.S_DIR)
     || stat.st_uid <> Core_unix.getuid () || stat.st_perm land 0o077 <> 0
     || not (List.equal String.equal (List.sort (names ~max_entries:2 path) ~compare:String.compare)
               ["metadata"; "program"])
  then failwith "unrecognized cache entry";
  List.sum (module Int) ["program"; "metadata"] ~f:(fun name ->
    let stat = Core_unix.lstat (Filename.concat path name) in
    if not (Poly.equal stat.st_kind Core_unix.S_REG)
       || stat.st_uid <> Core_unix.getuid () || stat.st_perm land 0o077 <> 0
       || stat.st_nlink <> 1 || Int64.(stat.st_size > of_int max_bytes)
    then failwith "unrecognized cache file";
    Int64.to_int_exn stat.st_size)
;;

let remove_entry path =
  ignore (entry_size path : int);
  Core_unix.unlink (Filename.concat path "program");
  Core_unix.unlink (Filename.concat path "metadata");
  Core_unix.rmdir path
;;

let prune_unlocked dir =
  let entries = names dir
    |> List.filter_map ~f:(fun name ->
      if not (owned_entry name) then None else
      try
        let path = Filename.concat dir name in
        let size = entry_size path in
        let meta = read ~max:4096 (Filename.concat path "metadata") in
        if not (String.is_prefix meta
          ~prefix:("CHES_COMPILED_1\n" ^ String.drop_prefix name 5 ^ "\n"))
        then failwith "foreign cache metadata";
        Some (path, (Core_unix.lstat path).st_mtime, size)
      with _ -> None)
    |> List.sort ~compare:(fun (_, a, _) (_, b, _) -> Float.compare b a)
  in
  ignore (List.fold entries ~init:(0, 0) ~f:(fun (count, bytes) (path, _, size) ->
    if count >= 16 || bytes + size > max_bytes then (
      (try remove_entry path with _ -> ()); count, bytes)
    else count + 1, bytes + size) : int * int)
;;

let prune dir = try with_lock dir (fun () -> prune_unlocked dir) with _ -> ()

let publish ~dir ~key ~program =
  try
    with_lock dir (fun () ->
    let staging = Core_unix.mkdtemp (Filename.concat dir ".pending-") in
    Exn.protect ~finally:(fun () -> try remove staging with _ -> ()) ~f:(fun () ->
      let target = Filename.concat staging "program" in
      copy program target;
      Core_unix.chmod target ~perm:0o700;
      Out_channel.write_all (Filename.concat staging "metadata") ~data:(metadata ~key target);
      Core_unix.chmod (Filename.concat staging "metadata") ~perm:0o600;
      let entry = Filename.concat dir ("ches-" ^ key) in
      (* Readers and publishers hold the same directory lock. Refuse to replace
         symlinks or directories containing anything beyond our two files. *)
      (try remove_entry entry with Core_unix.Unix_error (ENOENT, _, _) -> ());
      Core_unix.rename ~src:staging ~dst:entry);
    prune_unlocked dir)
  with _ -> ()
;;
