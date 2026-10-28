open! Core

module Tracking = struct
  type t =
    | In_sync
    | Ahead_behind of
        { ahead : int
        ; behind : int
        }
    | Gone
  [@@deriving sexp, equal]
end

module Upstream = struct
  type t =
    { name : string
    ; refname : string
    ; tracking : Tracking.t
    ; remote : string
    ; merge : string
    }
  [@@deriving sexp, equal]
end

module Branch = struct
  type t =
    { name : string
    ; oid : string
    ; current : bool
    ; upstream : Upstream.t option
    ; subject : string
    ; committer_time : int
    }
  [@@deriving sexp, equal]
end

let format =
  [ "%(refname:short)"
  ; "%(objectname)"
  ; "%(HEAD)"
  ; "%(upstream)"
  ; "%(upstream:short)"
  ; "%(upstream:track,nobracket)"
  ; "%(committerdate:unix)"
  ; "%(contents:subject)"
  ; "%(upstream:remotename)"
  ; "%(upstream:remoteref)"
  ]
  |> List.map ~f:(fun field -> field ^ "%00")
  |> String.concat
;;

let command ~cwd = Cli.read ~cwd [ "for-each-ref"; "--format=" ^ format; "refs/heads" ]
let malformed line = Or_error.error_s [%message "malformed branch line" (line : string)]

let count line text =
  match Int.of_string_opt text with
  | Some n when n >= 0 && String.for_all text ~f:Char.is_digit -> Ok n
  | _ -> malformed line
;;

let tracking line track : Tracking.t Or_error.t =
  match track with
  | "" -> Ok In_sync
  | "gone" -> Ok Gone
  | _ ->
    let parts = String.split track ~on:',' |> List.map ~f:String.strip in
    let%bind.Or_error ahead, behind =
      List.fold_result parts ~init:(None, None) ~f:(fun (ahead, behind) part ->
        match String.lsplit2 part ~on:' ', ahead, behind with
        | Some ("ahead", n), None, _ ->
          let%map.Or_error n = count line n in
          Some n, behind
        | Some ("behind", n), _, None ->
          let%map.Or_error n = count line n in
          ahead, Some n
        | _ -> malformed line)
    in
    let ahead = Option.value ahead ~default:0
    and behind = Option.value behind ~default:0 in
    if ahead = 0 && behind = 0
    then malformed line
    else Ok (Tracking.Ahead_behind { ahead; behind })
;;

let parse_line line =
  match String.split line ~on:'\000' with
  | [ name; oid; head; refname; short; track; time; subject; remote; merge; "" ] ->
    let%bind.Or_error current =
      match head with
      | "*" -> Ok true
      | " " -> Ok false
      | _ -> malformed line
    in
    let%bind.Or_error committer_time =
      match Int.of_string_opt time with
      | Some time -> Ok time
      | None -> malformed line
    in
    (* Without an upstream git leaves every upstream field empty. *)
    let%bind.Or_error upstream =
      if String.is_empty refname
      then Ok None
      else if String.is_empty remote || String.is_empty merge
      then malformed line
      else (
        let%map.Or_error tracking = tracking line track in
        Some
          { Upstream.name = (if String.is_empty short then refname else short)
          ; refname
          ; tracking
          ; remote
          ; merge
          })
    in
    if String.is_empty name || String.is_empty oid
    then malformed line
    else Ok { Branch.name; oid; current; upstream; subject; committer_time }
  | _ -> malformed line
;;

let parse ~cut stdout =
  let lines = String.split stdout ~on:'\n' in
  let lines, tail =
    match List.rev lines with
    | tail :: rev -> List.rev rev, tail
    | [] -> [], ""
  in
  if (not cut) && not (String.is_empty tail)
  then Or_error.error_s [%message "unterminated branch line" (tail : string)]
  else List.map lines ~f:parse_line |> Or_error.all
;;
