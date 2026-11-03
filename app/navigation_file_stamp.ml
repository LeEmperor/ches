open! Core

type t = int * int * int64 * float * float [@@deriving equal]

let read path =
  Option.try_with (fun () ->
    let stat = Core_unix.stat path in
    if not (Poly.equal stat.st_kind Core_unix.S_REG) then
      failwith "Navigation destination is not a regular file";
    stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime, stat.st_ctime)
;;

let to_string t = Sexp.to_string ([%sexp_of: int * int * int64 * float * float] t)
