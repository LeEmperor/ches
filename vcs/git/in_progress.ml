open! Core
open Ches_vcs

type t =
  | Rebase of
      { interactive_backend : bool
      ; branch : string option
      ; onto : string option
      }
  | Apply_mailbox
  | Merge of { head : string option }
  | Cherry_pick of { commit : string option }
  | Revert of { commit : string option }
  | Bisect
[@@deriving sexp, equal]

let names =
  [ "rebase-merge/head-name"
  ; "rebase-merge/onto"
  ; "rebase-apply/head-name"
  ; "rebase-apply/onto"
  ; "rebase-apply/applying"
  ; "MERGE_HEAD"
  ; "CHERRY_PICK_HEAD"
  ; "REVERT_HEAD"
  ; "BISECT_LOG"
  ]
;;

let reads ~git_dir =
  List.map names ~f:(fun name -> { Job.File_read.path = git_dir ^/ name; limit = 4096 })
;;

(* The first line, stripped; [None] if empty. *)
let field text =
  match String.strip text |> String.split_lines with
  | first :: _ when not (String.is_empty (String.strip first)) ->
    Some (String.strip first)
  | _ -> None
;;

let branch_of_head_name text =
  match field text with
  | None | Some "detached HEAD" -> None
  | Some name -> Some (String.chop_prefix_if_exists name ~prefix:"refs/heads/")
;;

let parse ~git_dir (outcomes : (Job.File_read.t * Job.File_read.Result.t) list) =
  let expected = reads ~git_dir in
  if not
       (List.equal
          Job.File_read.equal
          expected
          (List.map outcomes ~f:(fun (read, _) -> read)))
  then
    Or_error.error_s
      [%message
        "state-file reads do not match In_progress.reads"
          (git_dir : string)
          ~got:(List.map outcomes ~f:fst : Job.File_read.t list)]
  else (
    let%bind.Or_error contents =
      List.map outcomes ~f:(fun ({ path; _ }, result) ->
        match (result : Job.File_read.Result.t) with
        | Missing -> Ok None
        | Contents { text; truncated = _ } -> Ok (Some text)
        | Failed message ->
          Or_error.error_s [%message "cannot read state file" (path : string) message])
      |> Or_error.all
    in
    match contents with
    | [ merge_head_name
      ; merge_onto
      ; apply_head_name
      ; apply_onto
      ; applying
      ; merge_head
      ; cherry_pick_head
      ; revert_head
      ; bisect_log
      ] ->
      let sequence =
        match merge_head_name, applying, apply_head_name with
        | Some head_name, _, _ ->
          Some
            (Rebase
               { interactive_backend = true
               ; branch = branch_of_head_name head_name
               ; onto = Option.bind merge_onto ~f:field
               })
        | None, Some _, _ -> Some Apply_mailbox
        | None, None, Some head_name ->
          Some
            (Rebase
               { interactive_backend = false
               ; branch = branch_of_head_name head_name
               ; onto = Option.bind apply_onto ~f:field
               })
        | None, None, None -> None
      in
      Ok
        (List.filter_opt
           [ sequence
           ; Option.map merge_head ~f:(fun text -> Merge { head = field text })
           ; Option.map cherry_pick_head ~f:(fun text ->
               Cherry_pick { commit = field text })
           ; Option.map revert_head ~f:(fun text -> Revert { commit = field text })
           ; Option.map bisect_log ~f:(fun _ -> Bisect)
           ])
    | _ -> assert false)
;;

let short hash = String.prefix hash 7

let describe = function
  | Rebase { branch; onto; interactive_backend = _ } ->
    let subject = Option.value branch ~default:"detached HEAD" in
    (match onto with
     | Some onto -> sprintf "Rebasing %s onto %s" subject (short onto)
     | None -> sprintf "Rebasing %s" subject)
  | Apply_mailbox -> "Applying patches"
  | Merge { head = Some hash } -> sprintf "Merging %s" (short hash)
  | Merge { head = None } -> "Merging"
  | Cherry_pick { commit = Some hash } -> sprintf "Cherry-picking %s" (short hash)
  | Cherry_pick { commit = None } -> "Cherry-picking"
  | Revert { commit = Some hash } -> sprintf "Reverting %s" (short hash)
  | Revert { commit = None } -> "Reverting"
  | Bisect -> "Bisecting"
;;
