open! Core

(* A fresh directory [<prefix><random>] under the system temp dir ($TMPDIR, else /tmp),
   with symlinks resolved so paths compare equal to the ones the session canonicalizes.
   The caller removes it. *)
let scratch_dir prefix =
  Filename_unix.realpath (Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name prefix))
;;
