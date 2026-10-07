open! Core

(* Shared ripgrep policy: normal ignores, no hidden files or symlink following,
   no config injection, and an explicit metadata exclusion. *)
let rg_args = [ "--no-config"; "--glob"; "!**/.git/**" ]
let visible_path path =
  not (List.exists (String.split path ~on:'/') ~f:(String.is_prefix ~prefix:"."))
;;
