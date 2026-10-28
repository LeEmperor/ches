open! Core
open Ches_vcs

let switch key flag description = { Popup.Switch.key; flag; description; group = None }
let action key description run = { Popup.Action.key; description; run }

module Push = struct
  module Target = struct
    type t =
      | Upstream
      | Set_upstream
    [@@deriving sexp, equal]
  end

  module Choice = struct
    type t =
      { target : Target.t
      ; flags : string list
      }
    [@@deriving sexp, equal]
  end

  let force_with_lease = "--force-with-lease"
  let no_verify = "--no-verify"

  let popup (status : Status.t) : Choice.t Popup.t =
    let title, set_upstream =
      match status.branch.head with
      | Some branch -> "Push " ^ branch, sprintf "Push to origin/%s, set upstream" branch
      | None -> "Push", "Push to origin, set upstream"
    in
    let upstream =
      match status.branch.upstream with
      | Some upstream -> "Push to " ^ upstream
      | None -> "Push to upstream (none set)"
    in
    let choose target ~enabled = { Choice.target; flags = enabled } in
    Popup.create
      ~title
      ~switches:
        [ switch 'f' force_with_lease "Force with lease (confirmed)"
        ; switch 'n' no_verify "Disable hooks"
        ]
      ~actions:
        [ action 'p' upstream (choose Upstream)
        ; action 'u' set_upstream (choose Set_upstream)
        ]
    |> Or_error.ok_exn
  ;;

  let flags = [ force_with_lease; no_verify ]
end

module Pull = struct
  module Choice = struct
    type t = { flags : string list } [@@deriving sexp, equal]
  end

  let rebase = "--rebase"

  let popup (status : Status.t) : Choice.t Popup.t =
    let pull =
      match status.branch.upstream with
      | Some upstream -> "Pull from " ^ upstream
      | None -> "Pull from upstream (none set)"
    in
    Popup.create
      ~title:"Pull"
      ~switches:[ switch 'r' rebase "Rebase local commits onto the upstream" ]
      ~actions:[ action 'p' pull (fun ~enabled -> { Choice.flags = enabled }) ]
    |> Or_error.ok_exn
  ;;

  let flags = [ rebase ]
end

(* In the contract's order: the first rule with a text found in stderr wins. *)
let hints =
  [ ( [ "Permission denied (publickey" ]
    , "SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?" )
  ; ( [ "Host key verification failed" ]
    , "SSH does not know the host's key: connect once with ssh in a terminal to accept it"
    )
  ; ( [ "terminal prompts disabled"; "could not read Username"; "could not read Password" ]
    , "Git needs credentials and Ches cannot prompt: use an SSH key in ssh-agent or a \
       credential helper" )
  ; ( [ "Could not resolve hostname"; "Could not resolve host" ]
    , "Could not resolve the remote's host: check the network" )
  ; ( [ "Not possible to fast-forward" ]
    , "The branch and its upstream have diverged: pull with rebase (p -r p) or merge \
       outside Ches" )
  ; ( [ "(stale info)" ]
    , "The remote branch moved since the last fetch: fetch (f) and look before forcing" )
  ; ( [ "(fetch first)"; "(non-fast-forward)" ]
    , "The remote has commits this branch lacks: pull first (p p)" )
  ; ( [ "does not appear to be a git repository"; "No remote repository specified" ]
    , "The remote is missing or unreachable: check git remote -v" )
  ]
;;

let hint (report : Job.Step_report.t) =
  match report.outcome with
  | Ran result when not (Job.Step_report.succeeded report) ->
    List.find_map hints ~f:(fun (patterns, hint) ->
      Option.some_if
        (List.exists patterns ~f:(fun pattern ->
           String.is_substring result.stderr ~substring:pattern))
        hint)
  | Ran _ | Read _ | Skipped -> None
;;
