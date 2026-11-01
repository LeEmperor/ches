open! Core
open Ches_vcs

module Commit = struct
  type t =
    { hash : string
    ; parents : string list
    ; author_name : string
    ; author_email : string
    ; author_time : int
    ; refs : string list
    ; subject : string
    }
  [@@deriving sexp, equal]

  let short_hash t = String.prefix t.hash 7
end

let command ~cwd (scope : Log_scope.t) =
  if scope.limit <= 0
  then
    raise_s [%message "Log.command: limit must be positive" ~limit:(scope.limit : int)];
  let order = if Log_scope.graph_shown scope then [ "--topo-order" ] else [] in
  (* [--branches --remotes] are options here: after [--end-of-options] they would be
     taken as revisions. *)
  let filters =
    List.filter_opt
      [ Option.some_if (not scope.merges) "--no-merges"
      ; Option.some_if scope.first_parent "--first-parent"
      ; Option.map scope.path ~f:(fun _ -> "--follow")
      ]
    @
    match scope.range with
    | Head | Branch _ -> []
    | All -> [ "--branches"; "--remotes" ]
  in
  let revisions =
    match scope.range with
    | Head | All -> [ "HEAD" ]
    | Branch branch -> [ "refs/heads/" ^ branch ]
  in
  Cli.read
    ~cwd
    ([ "--literal-pathspecs"
     ; "log"
     ; "-z"
     ; "--no-color"
     ; "--no-show-signature"
     ; "--decorate=short"
     ; sprintf "--max-count=%d" scope.limit
     ]
     @ order
     @ filters
     @ [ "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s"; "--end-of-options" ]
     @ revisions
     @ ("--" :: Option.to_list scope.path))
;;

let commit = function
  | [ hash; parents; author_name; author_email; time; refs; subject ] as fields ->
    (match Int.of_string_opt time with
     | Some author_time when not (String.is_empty hash) ->
       Ok
         { Commit.hash
         ; parents =
             String.split parents ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
         ; author_name
         ; author_email
         ; author_time
         ; refs =
             (if String.is_empty refs then [] else String.Search_pattern.(split_on (create ", ") refs))
         ; subject
         }
     | _ -> Or_error.error_s [%message "malformed log record" (fields : string list)])
  | fields -> Or_error.error_s [%message "malformed log record" (fields : string list)]
;;

let parse ~cut stdout =
  if String.is_empty stdout
  then Ok []
  else (
    (* Seven NUL-terminated fields per commit: the piece after the last NUL is empty, or
       (when cut) the incomplete start of a field. *)
    let fields, tail =
      match List.rev (String.split stdout ~on:'\000') with
      | tail :: rev -> List.rev rev, tail
      | [] -> [], ""
    in
    let groups = List.chunks_of fields ~length:7 in
    let groups =
      if cut then List.filter groups ~f:(fun group -> List.length group = 7) else groups
    in
    if (not cut) && not (String.is_empty tail)
    then Or_error.error_s [%message "unterminated log record" (tail : string)]
    else List.map groups ~f:commit |> Or_error.all)
;;

module Target = struct
  type t =
    | Head
    | Branch of string option
    | All
    | File of string option
  [@@deriving sexp, equal]
end

module Choice = struct
  type t =
    { target : Target.t
    ; flags : string list
    }
  [@@deriving sexp, equal]
end

let graph = "--graph"
let no_merges = "--no-merges"
let first_parent = "--first-parent"
let flags = [ graph; no_merges; first_parent ]

let popup ~branch ~file : Choice.t Popup.t =
  let switch key flag description = { Popup.Switch.key; flag; description; group = None } in
  let action key description target =
    { Popup.Action.key
    ; description
    ; run = (fun ~enabled -> { Choice.target; flags = enabled })
    }
  in
  Popup.create
    ~title:"Log"
    ~switches:
      [ switch 'g' graph "Show the graph"
      ; switch 'm' no_merges "Omit merges"
      ; switch 'p' first_parent "First parent only"
      ]
    ~actions:
      [ action 'l' "Log HEAD" Head
      ; action
          'b'
          (match branch with
           | Some branch -> "Log " ^ branch
           | None -> "Log a branch (select one in Branches first)")
          (Branch branch)
      ; action 'a' "Log all branches" All
      ; action
          'f'
          (match file with
           | Some file -> "History of " ^ file
           | None -> "History of a file (select one first)")
          (File file)
      ]
  |> Or_error.ok_exn
;;

let enabled (scope : Log_scope.t) =
  List.filter flags ~f:(fun flag ->
    if String.equal flag graph
    then scope.graph
    else if String.equal flag no_merges
    then not scope.merges
    else scope.first_parent)
;;

let scope ({ target; flags } : Choice.t) =
  let on flag = List.mem flags flag ~equal:String.equal in
  let scope range path : Log_scope.t =
    { range
    ; path
    ; graph = on graph
    ; merges = not (on no_merges)
    ; first_parent = on first_parent
    ; limit = Log_scope.default_limit
    }
  in
  match target with
  | Head -> Ok (scope Head None)
  | Branch (Some branch) -> Ok (scope (Branch branch) None)
  | Branch None -> Error "Select a branch in Branches first"
  | All -> Ok (scope All None)
  | File (Some path) -> Ok (scope Head (Some path))
  | File None -> Error "Select a file first: a Files item, or a file in the diff"
;;
