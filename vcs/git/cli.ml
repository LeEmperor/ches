open! Core
open Ches_vcs

let prefix = [ "--no-pager"; "-c"; "color.ui=false"; "-c"; "core.quotepath=false" ]
let read_env = [ "GIT_OPTIONAL_LOCKS", "0"; "LC_ALL", "C" ]

let read ?stdout_limit ~cwd args =
  Exec.Spec.create ~env:read_env ?stdout_limit ~kind:Read ~cwd "git" (prefix @ args)
;;

let mutate ?stdin ~cwd args =
  Exec.Spec.create ?stdin ~kind:Mutate ~cwd "git" (prefix @ args)
;;

let network ~cwd args =
  Exec.Spec.create ~stream:true ~kind:Network ~cwd "git" (prefix @ args)
;;
