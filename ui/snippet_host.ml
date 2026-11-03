open! Core
open! Async
module Catalog = Ches_completion.User_snippets

type catalog = (Catalog.t, string) Result.t

let config_path ~getenv =
  match getenv "XDG_CONFIG_HOME" with
  | Some path when not (String.is_empty path) && not (Filename.is_relative path) ->
    Ok (Filename.concat path "ches/snippets.json")
  | _ ->
    (match getenv "HOME" with
     | Some home when not (String.is_empty home) ->
       Ok (Filename.concat home ".config/ches/snippets.json")
     | _ -> Or_error.error_string "HOME is unset or empty; cannot locate snippets.json")
;;

let max_bytes = 1024 * 1024

let read_catalog ~path =
  let regular (stats : Core_unix.stats) =
    match stats.st_kind with S_REG -> true | _ -> false in
  let read () =
    if not (regular (Core_unix.stat path)) then failwith "expected a regular file";
    (* Nonblocking open closes the stat/open FIFO race. Check the opened identity
       too, before reading. Symlinks to regular files are supported. *)
    let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
    Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
      if not (regular (Core_unix.fstat fd)) then failwith "expected a regular file";
      (* Exactly one byte beyond the cap is sufficient to detect growth/overflow.
         Never use read_all: even an unexpectedly growing file stays bounded. *)
      let bytes = Bytes.create (max_bytes + 1) in
      let rec loop pos =
        if pos > max_bytes then failwith "file exceeds 1 MiB limit";
        match Core_unix.read ~restart:true fd ~buf:bytes ~pos ~len:(max_bytes + 1 - pos) with
        | 0 -> Catalog.parse (Bytes.to_string (Bytes.sub bytes ~pos:0 ~len:pos))
        | n -> loop (pos + n)
      in
      loop 0)
  in
  let result =
    try read () with
    | Core_unix.Unix_error (ENOENT, _, _) -> Ok Catalog.builtins
    | exn -> Or_error.of_exn exn
  in
  Result.map_error result ~f:(fun error ->
    sprintf "%s: %s" path (Error.to_string_hum error))
;;

let load ~path = In_thread.run (fun () -> read_catalog ~path)

type t =
  { load : unit -> catalog Deferred.t
  ; mutable latest : int
  ; mutable pending : int option
  ; mutable active : bool
  ; mutable stopped : bool
  ; mutable reply : (int * catalog) option
  ; mutable changed : unit Ivar.t
  }

let notify t =
  let changed = t.changed in
  t.changed <- Ivar.create ();
  Ivar.fill_if_empty changed ()
;;

let rec launch t =
  match t.pending with
  | Some generation when not t.active && not t.stopped ->
    t.pending <- None;
    t.active <- true;
    don't_wait_for (
      let%bind result = Monitor.try_with t.load in
      t.active <- false;
      if not t.stopped && generation = t.latest then (
        let result = match result with Ok result -> result | Error exn -> Error (Exn.to_string exn) in
        t.reply <- Some (generation, result);
        notify t);
      launch t;
      return ())
  | _ -> ()
;;

let make ~load =
  { load; latest = 0; pending = None; active = false; stopped = false
  ; reply = None; changed = Ivar.create () }
;;

let create () =
  make ~load:(fun () ->
    match config_path ~getenv:Sys.getenv with
    | Error error -> return (Error (Error.to_string_hum error))
    | Ok path -> load ~path)
;;

let submit t generations =
  if not t.stopped then (
    List.iter generations ~f:(fun generation ->
      if generation > t.latest then (
        t.latest <- generation;
        t.pending <- Some generation;
        t.reply <- None));
    launch t)
;;

let rec next t =
  if t.stopped then return None else
  match t.reply with
  | Some reply -> t.reply <- None; return (Some reply)
  | None -> let%bind () = Ivar.read t.changed in next t
;;

let stop t =
  t.stopped <- true;
  t.pending <- None;
  t.reply <- None;
  notify t
;;

module For_testing = struct
  let load = load
  let create ~load = make ~load
end
