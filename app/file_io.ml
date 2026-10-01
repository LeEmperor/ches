open! Core
open Ches_core

module Loaded = struct
  type t =
    | Existing of Text_buffer.t
    | Missing
  [@@deriving sexp_of]
end

let unix_error error = Error (Error.of_string (Core_unix.Error.message error))

let read_all fd =
  let buffer = Buffer.create 65536 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    match Core_unix.read ~restart:true fd ~buf:chunk with
    | 0 -> Buffer.contents buffer
    | n ->
      Buffer.add_subbytes buffer chunk ~pos:0 ~len:n;
      loop ()
  in
  loop ()
;;

let read path : Loaded.t Or_error.t =
  (* [stat] first: opening a FIFO for reading would block. *)
  match Core_unix.stat path with
  | exception Core_unix.Unix_error (ENOENT, _, _) -> Ok Missing
  | exception Core_unix.Unix_error (error, _, _) -> unix_error error
  | { st_kind = S_DIR; _ } -> Or_error.error_string "is a directory"
  | { st_kind = S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK; _ } ->
    Or_error.error_string "is not a regular file"
  | { st_kind = S_REG; _ } ->
    (match Core_unix.with_file path ~mode:[ O_RDONLY ] ~f:read_all with
     | exception Core_unix.Unix_error (error, _, _) -> unix_error error
     | contents ->
       (match Text_buffer.of_string contents with
        | Ok text -> Ok (Existing text)
        | Error invalid ->
          Or_error.error_string (Text_buffer.Invalid_text.to_string_hum invalid)))
;;

let write_all fd s =
  let rec loop pos =
    if pos < String.length s
    then (
      let written =
        Core_unix.single_write_substring
          ~restart:true
          fd
          ~buf:s
          ~pos
          ~len:(String.length s - pos)
      in
      loop (pos + written))
  in
  loop 0
;;

let write path text =
  match Core_unix.openfile path ~mode:[ O_WRONLY; O_CREAT; O_TRUNC ] ~perm:0o666 with
  | exception Core_unix.Unix_error (error, _, _) -> unix_error error
  | fd ->
    (match write_all fd (Text_buffer.to_string text) with
     | exception Core_unix.Unix_error (error, _, _) ->
       (* Report the write error, not a secondary one from closing. *)
       (try Core_unix.close fd with
        | Core_unix.Unix_error _ -> ());
       unix_error error
     | () ->
       (* [close] can report a delayed write error, e.g. on NFS. *)
       (match Core_unix.close fd with
        | exception Core_unix.Unix_error (error, _, _) -> unix_error error
        | () -> Ok ()))
;;
