open! Core
open Ches_vcs

module Side = struct
  type t =
    | Ours
    | Theirs
    | Markers
  [@@deriving sexp, equal]
end

let has_file (conflict : Status.Conflict.t) (side : Side.t) =
  match side, conflict with
  | _, (Both_modified | Both_added) -> true
  | _, Both_deleted -> false
  | Ours, (Added_by_us | Deleted_by_them) | Theirs, (Added_by_them | Deleted_by_us) ->
    true
  | Ours, (Added_by_them | Deleted_by_us) | Theirs, (Added_by_us | Deleted_by_them) ->
    false
  | Markers, (Added_by_us | Deleted_by_them | Added_by_them | Deleted_by_us) -> false
;;

let labels (operations : In_progress.t list) =
  match List.hd operations with
  | Some (Rebase _) -> "the upstream", "your commit"
  | Some (Merge { head }) ->
    ( "HEAD"
    , (match head with
       | Some head -> String.prefix head 7
       | None -> "the merged branch") )
  | Some (Apply_mailbox | Cherry_pick _ | Revert _ | Bisect) | None ->
    "HEAD", "the other side"
;;

let popup ~path (conflict : Status.Conflict.t) operations : Side.t Popup.t =
  let ours, theirs = labels operations in
  let take (side : Side.t) key name label =
    let description =
      if has_file conflict side
      then sprintf "Take %s (%s)" name label
      else sprintf "Take %s: delete the file (%s)" name label
    in
    { Popup.Action.key; description; run = (fun ~enabled:_ -> side) }
  in
  let markers =
    match conflict with
    | Both_modified | Both_added ->
      [ { Popup.Action.key = 'm'
        ; description = "Restore the conflict markers"
        ; run = (fun ~enabled:_ -> Side.Markers)
        }
      ]
    | Both_deleted | Added_by_us | Deleted_by_them | Added_by_them | Deleted_by_us -> []
  in
  Popup.create
    ~title:("Resolve " ^ path)
    ~switches:[]
    ~actions:(take Ours 'o' "ours" ours :: take Theirs 't' "theirs" theirs :: markers)
  |> Or_error.ok_exn
;;
