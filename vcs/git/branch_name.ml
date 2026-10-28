open! Core

(* git's rules for [refs/heads/<name>] (refs.c check_refname_format, plus check-ref-format
   --branch's own: no leading '-', not HEAD), as the reasons the contract names, in its
   order. One is stricter than git 2.43: it accepts a branch named "@" (verified), which
   would read as HEAD in a revision. *)
let forbidden = [ '~'; '^'; ':'; '?'; '*'; '['; '\\' ]
let control c = Char.to_int c < 0x20 || Char.to_int c = 0x7f

let invalid name =
  let parts = String.split name ~on:'/' in
  let contains substring = String.is_substring name ~substring in
  if String.is_prefix name ~prefix:"-"
  then Some "it starts with '-'"
  else if String.equal name "HEAD"
  then Some "it is HEAD"
  else if String.equal name "@"
  then Some "it is '@'"
  else if String.mem name ' '
  then Some "it contains a space"
  else if String.exists name ~f:control
  then Some "it contains a control character"
  else (
    match List.find forbidden ~f:(String.mem name) with
    | Some c -> Some (sprintf "it contains '%c'" c)
    | None ->
      if contains ".."
      then Some "it contains '..'"
      else if contains "@{"
      then Some "it contains '@{'"
      else if String.is_prefix name ~prefix:"/" || String.is_suffix name ~suffix:"/"
      then Some "it starts or ends with '/'"
      else if contains "//"
      then Some "it contains '//'"
      else if String.is_suffix name ~suffix:"."
      then Some "it ends with '.'"
      else if List.exists parts ~f:(String.is_prefix ~prefix:".")
      then Some "a part starts with '.'"
      else if List.exists parts ~f:(String.is_suffix ~suffix:".lock")
      then Some "a part ends with '.lock'"
      else None)
;;

let refusal ~existing name =
  if String.is_empty name
  then Some "Enter a branch name"
  else (
    match invalid name with
    | Some reason -> Some ("Not a valid branch name: " ^ reason)
    | None ->
      if List.mem existing name ~equal:String.equal
      then Some (sprintf "A branch named %s already exists" name)
      else None)
;;
