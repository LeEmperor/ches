open! Core

module Change = struct
  type t =
    | Unmodified
    | Modified
    | Type_changed
    | Added
    | Deleted
    | Renamed
    | Copied
    | Updated_unmerged
  [@@deriving sexp, equal, compare]

  let of_char = function
    | '.' -> Some Unmodified
    | 'M' -> Some Modified
    | 'T' -> Some Type_changed
    | 'A' -> Some Added
    | 'D' -> Some Deleted
    | 'R' -> Some Renamed
    | 'C' -> Some Copied
    | 'U' -> Some Updated_unmerged
    | _ -> None
  ;;
end

module Submodule = struct
  type t =
    { commit_changed : bool
    ; tracked_changes : bool
    ; untracked_changes : bool
    }
  [@@deriving sexp, equal]
end

module Conflict = struct
  type t =
    | Both_deleted
    | Added_by_us
    | Deleted_by_them
    | Added_by_them
    | Deleted_by_us
    | Both_added
    | Both_modified
  [@@deriving sexp, equal]

  let to_string_hum = function
    | Both_deleted -> "both deleted"
    | Added_by_us -> "added by us"
    | Deleted_by_them -> "deleted by them"
    | Added_by_them -> "added by them"
    | Deleted_by_us -> "deleted by us"
    | Both_added -> "both added"
    | Both_modified -> "both modified"
  ;;

  let of_string = function
    | "DD" -> Some Both_deleted
    | "AU" -> Some Added_by_us
    | "UD" -> Some Deleted_by_them
    | "UA" -> Some Added_by_them
    | "DU" -> Some Deleted_by_us
    | "AA" -> Some Both_added
    | "UU" -> Some Both_modified
    | _ -> None
  ;;
end

module Entry = struct
  type t =
    | Changed of
        { index : Change.t
        ; worktree : Change.t
        ; submodule : Submodule.t option
        ; head_mode : string
        ; index_mode : string
        ; worktree_mode : string
        ; path : string
        }
    | Renamed_or_copied of
        { index : Change.t
        ; worktree : Change.t
        ; submodule : Submodule.t option
        ; head_mode : string
        ; index_mode : string
        ; worktree_mode : string
        ; score : int
        ; path : string
        ; original : string
        }
    | Unmerged of
        { conflict : Conflict.t
        ; submodule : Submodule.t option
        ; path : string
        }
    | Untracked of string
    | Ignored of string
  [@@deriving sexp, equal]

  let path = function
    | Changed { path; _ }
    | Renamed_or_copied { path; _ }
    | Unmerged { path; _ }
    | Untracked path
    | Ignored path -> path
  ;;
end

module Branch = struct
  type t =
    { oid : string option
    ; head : string option
    ; upstream : string option
    ; ahead_behind : (int * int) option
    }
  [@@deriving sexp, equal]
end

type t =
  { branch : Branch.t
  ; entries : Entry.t list
  ; truncated : bool
  }
[@@deriving sexp, equal]

let command ?(ignored = false) ~cwd () =
  Cli.read
    ~cwd
    ([ "status"
     ; "--porcelain=v2"
     ; "-z"
     ; "--branch"
     ; "--untracked-files=all"
     ; "--find-renames"
     ]
     @ if ignored then [ "--ignored=matching" ] else [])
;;

(* [fields record n]: the first [n - 1] space-separated fields and the rest (a path, which
   may contain spaces) as the [n]th. *)
let fields record n =
  let rec go pos remaining acc =
    if remaining = 1
    then Some (List.rev (String.drop_prefix record pos :: acc))
    else (
      match String.index_from record pos ' ' with
      | None -> None
      | Some space ->
        go (space + 1) (remaining - 1) (String.sub record ~pos ~len:(space - pos) :: acc))
  in
  go 0 n []
;;

let is_mode mode =
  (not (String.is_empty mode))
  && String.for_all mode ~f:(fun c -> Char.between c ~low:'0' ~high:'7')
;;

let malformed record =
  Or_error.error_s [%message "malformed status record" (record : string)]
;;

let xy record xy =
  match String.to_list xy with
  | [ x; y ] ->
    (match Change.of_char x, Change.of_char y with
     | Some x, Some y -> Ok (x, y)
     | _ -> malformed record)
  | _ -> malformed record
;;

let submodule record field : Submodule.t option Or_error.t =
  match String.to_list field with
  | [ 'N'; '.'; '.'; '.' ] -> Ok None
  | [ 'S'; c; m; u ] ->
    let flag expected = function
      | '.' -> Ok false
      | c when Char.equal c expected -> Ok true
      | _ -> malformed record
    in
    let%bind.Or_error commit_changed = flag 'C' c in
    let%bind.Or_error tracked_changes = flag 'M' m in
    let%map.Or_error untracked_changes = flag 'U' u in
    Some { Submodule.commit_changed; tracked_changes; untracked_changes }
  | _ -> malformed record
;;

let modes record modes = if List.for_all modes ~f:is_mode then Ok () else malformed record
let path record path = if String.is_empty path then malformed record else Ok path

let ordinary record =
  match fields record 9 with
  | Some [ _; xy_field; sub; head_mode; index_mode; worktree_mode; _; _; p ] ->
    let%bind.Or_error index, worktree = xy record xy_field in
    let%bind.Or_error submodule = submodule record sub in
    let%bind.Or_error () = modes record [ head_mode; index_mode; worktree_mode ] in
    let%map.Or_error path = path record p in
    Entry.Changed
      { index; worktree; submodule; head_mode; index_mode; worktree_mode; path }
  | _ -> malformed record
;;

let renamed record ~original =
  match fields record 10 with
  | Some [ _; xy_field; sub; head_mode; index_mode; worktree_mode; _; _; score_field; p ]
    ->
    let%bind.Or_error index, worktree = xy record xy_field in
    let%bind.Or_error submodule = submodule record sub in
    let%bind.Or_error () = modes record [ head_mode; index_mode; worktree_mode ] in
    let%bind.Or_error path = path record p in
    let%bind.Or_error original =
      if String.is_empty original then malformed record else Ok original
    in
    (match String.to_list score_field with
     | ('R' | 'C') :: digits
       when (not (List.is_empty digits)) && List.for_all digits ~f:Char.is_digit ->
       let score = Int.of_string (String.of_char_list digits) in
       Ok
         (Entry.Renamed_or_copied
            { index
            ; worktree
            ; submodule
            ; head_mode
            ; index_mode
            ; worktree_mode
            ; score
            ; path
            ; original
            })
     | _ -> malformed record)
  | _ -> malformed record
;;

let unmerged record =
  match fields record 11 with
  | Some [ _; xy_field; sub; m1; m2; m3; mw; _; _; _; p ] ->
    let%bind.Or_error conflict =
      match Conflict.of_string xy_field with
      | Some conflict -> Ok conflict
      | None -> malformed record
    in
    let%bind.Or_error submodule = submodule record sub in
    let%bind.Or_error () = modes record [ m1; m2; m3; mw ] in
    let%map.Or_error path = path record p in
    Entry.Unmerged { conflict; submodule; path }
  | _ -> malformed record
;;

let ahead_behind header value =
  match String.split value ~on:' ' with
  | [ ahead; behind ] ->
    (match
       String.chop_prefix ahead ~prefix:"+", String.chop_prefix behind ~prefix:"-"
     with
     | Some ahead, Some behind ->
       (match Int.of_string_opt ahead, Int.of_string_opt behind with
        | Some ahead, Some behind when ahead >= 0 && behind >= 0 -> Ok (ahead, behind)
        | _ -> malformed header)
     | _ -> malformed header)
  | _ -> malformed header
;;

let parse ~cut stdout =
  let pieces = String.split stdout ~on:'\000' in
  (* Every record is NUL-terminated: the piece after the last NUL is empty, or (when the
     output was cut) the incomplete start of a record. *)
  let pieces, tail =
    match List.rev pieces with
    | tail :: rev -> List.rev rev, tail
    | [] -> [], ""
  in
  let%bind.Or_error () =
    if cut || String.is_empty tail
    then Ok ()
    else Or_error.error_s [%message "unterminated status record" (tail : string)]
  in
  let oid = ref None
  and head = ref None
  and upstream = ref None
  and ab = ref None in
  let header record =
    match String.chop_prefix record ~prefix:"# " with
    | None -> malformed record
    | Some header ->
      (match String.lsplit2 header ~on:' ' with
       | Some ("branch.oid", value) ->
         oid := Some (if String.equal value "(initial)" then None else Some value);
         Ok ()
       | Some ("branch.head", value) ->
         head := Some (if String.equal value "(detached)" then None else Some value);
         Ok ()
       | Some ("branch.upstream", value) ->
         upstream := Some value;
         Ok ()
       | Some ("branch.ab", value) ->
         let%map.Or_error value = ahead_behind record value in
         ab := Some value
       | _ -> Ok ())
  in
  let rec go pieces acc =
    match pieces with
    | [] -> Ok (List.rev acc)
    | record :: rest ->
      (match String.prefix record 2 with
       | "# " ->
         let%bind.Or_error () = header record in
         go rest acc
       | "1 " ->
         let%bind.Or_error entry = ordinary record in
         go rest (entry :: acc)
       | "2 " ->
         (match rest with
          | original :: rest ->
            let%bind.Or_error entry = renamed record ~original in
            go rest (entry :: acc)
          | [] ->
            (* Its original path was cut off with the tail. *)
            if cut then Ok (List.rev acc) else malformed record)
       | "u " ->
         let%bind.Or_error entry = unmerged record in
         go rest (entry :: acc)
       | "? " ->
         let%bind.Or_error p = path record (String.drop_prefix record 2) in
         go rest (Entry.Untracked p :: acc)
       | "! " ->
         let%bind.Or_error p = path record (String.drop_prefix record 2) in
         go rest (Entry.Ignored p :: acc)
       | _ -> Or_error.error_s [%message "unknown status record" (record : string)])
  in
  let%bind.Or_error entries = go pieces [] in
  match !oid, !head with
  | None, _ -> Or_error.error_s [%message "status output has no branch.oid header"]
  | _, None -> Or_error.error_s [%message "status output has no branch.head header"]
  | Some oid, Some head ->
    Ok
      { branch = { oid; head; upstream = !upstream; ahead_behind = !ab }
      ; entries
      ; truncated = cut
      }
;;
