open! Core
open Ches_vcs

module Kind = struct
  type t =
    | Commit
    | Amend
  [@@deriving sexp, equal]
end

module Choice = struct
  type t =
    | Message of
        { kind : Kind.t
        ; flags : string list
        }
    | Extend of { flags : string list }
  [@@deriving sexp, equal]
end

let no_verify = "--no-verify"
let signoff = "--signoff"
let allow_empty = "--allow-empty"

let popup : Choice.t Popup.t =
  let switch key flag description =
    { Popup.Switch.key; flag; description; group = None }
  in
  let action key description run = { Popup.Action.key; description; run } in
  Popup.create
    ~title:"Commit"
    ~switches:
      [ switch 'n' no_verify "Disable hooks"
      ; switch 's' signoff "Add Signed-off-by line"
      ; switch 'e' allow_empty "Allow an empty commit"
      ]
    ~actions:
      [ action 'c' "Commit" (fun ~enabled ->
          Choice.Message { kind = Commit; flags = enabled })
      ; action 'a' "Amend" (fun ~enabled ->
          Choice.Message { kind = Amend; flags = enabled })
      ; action 'e' "Extend" (fun ~enabled -> Choice.Extend { flags = enabled })
      ]
  |> Or_error.ok_exn
;;

let flags = [ no_verify; signoff; allow_empty ]

(* The index side of an entry that has one: what [git commit] would record. *)
let staged_change : Status.Entry.t -> Status.Change.t option = function
  | Changed { index = Unmodified; _ } | Renamed_or_copied { index = Unmodified; _ } ->
    None
  | Changed { index; _ } | Renamed_or_copied { index; _ } -> Some index
  | Unmerged _ | Untracked _ | Ignored _ -> None
;;

let staged entry = Option.is_some (staged_change entry)

let refusal (status : Status.t) (choice : Choice.t) =
  let kind, given =
    match choice with
    | Message { kind; flags } -> `Kind kind, flags
    | Extend { flags } -> `Extend, flags
  in
  let amends =
    match kind with
    | `Kind Amend | `Extend -> true
    | `Kind Commit -> false
  in
  let needs_staged =
    match kind with
    | `Kind Commit | `Extend -> true
    | `Kind Amend -> false
  in
  match
    List.find given ~f:(fun flag -> not (List.mem flags flag ~equal:String.equal))
  with
  | Some flag -> Some (sprintf "Unknown commit switch %s; nothing ran" flag)
  | None ->
    if List.exists status.entries ~f:(function
         | Unmerged _ -> true
         | _ -> false)
    then Some "Resolve the conflicted files first (s marks one resolved); nothing ran"
    else if amends && Option.is_none status.branch.oid
    then Some "Nothing to amend: there is no commit yet; nothing ran"
    else if needs_staged
            && (not (List.exists status.entries ~f:staged))
            && not (List.mem given allow_empty ~equal:String.equal)
    then
      Some
        "Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing \
         ran"
    else None
;;

let message_path = "CHES_COMMIT_EDITMSG"

let prepare (repository : Repository.t) (kind : Kind.t) =
  let read args = Job.Step.Run (Cli.read ~cwd:repository.root args) in
  let path = read [ "rev-parse"; "--git-path"; message_path ] in
  match kind with
  | Commit -> [ path ]
  | Amend ->
    [ path; read [ "log"; "-1"; "--no-show-signature"; "--format=%B"; "HEAD"; "--" ] ]
;;

module Prepared = struct
  type t =
    { message_file : string
    ; head_message : string option
    }
  [@@deriving sexp_of, equal]
end

(* A succeeded command's stdout, else the step's failure. *)
let stdout_of (report : Job.Step_report.t) =
  match report.outcome with
  | Ran result when Job.Step_report.succeeded report -> Ok result.stdout
  | _ -> Or_error.error_string (Step_failure.of_report report)
;;

let message_file (repository : Repository.t) (report : Job.Step_report.t) =
  let%bind.Or_error stdout = stdout_of report in
  let path = String.chop_suffix_if_exists stdout ~suffix:"\n" in
  if String.is_empty path || String.mem path '\n'
  then (
    let command =
      match report.step with
      | Run spec -> Exec.Spec.to_string_hum spec
      | Read_file { path; _ } -> path
    in
    Or_error.error_string (sprintf "%s: expected one path, got %S" command stdout))
  else if Filename.is_absolute path
  then Ok path
  else Ok (Filename.concat repository.root path)
;;

let prepared
  (repository : Repository.t)
  (kind : Kind.t)
  (reports : Job.Step_report.t list)
  =
  let expected = List.length (prepare repository kind) in
  match kind, reports with
  | Commit, [ path ] ->
    let%map.Or_error message_file = message_file repository path in
    { Prepared.message_file; head_message = None }
  | Amend, [ path; log ] ->
    let%bind.Or_error message_file = message_file repository path in
    let%map.Or_error head_message = stdout_of log in
    { Prepared.message_file; head_message = Some head_message }
  | _ ->
    Or_error.error_string
      (sprintf
         "commit preparation: expected %d step reports, got %d"
         expected
         (List.length reports))
;;

(* git's quote_c_style with core.quotePath on (its default): a name with a byte other than
   printable ASCII, a double quote or a backslash is double-quoted, with C escapes and
   octal for the rest. *)
let needs_quoting c =
  let code = Char.to_int c in
  code < 0x20 || code >= 0x7f || Char.equal c '"' || Char.equal c '\\'
;;

let quote name =
  if not (String.exists name ~f:needs_quoting)
  then name
  else (
    let buffer = Buffer.create (String.length name + 8) in
    Buffer.add_char buffer '"';
    String.iter name ~f:(fun c ->
      match c with
      | '\007' -> Buffer.add_string buffer "\\a"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\011' -> Buffer.add_string buffer "\\v"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | c when needs_quoting c ->
        Buffer.add_string buffer (sprintf "\\%03o" (Char.to_int c))
      | c -> Buffer.add_char buffer c);
    Buffer.add_char buffer '"';
    Buffer.contents buffer)
;;

(* git status's labels, padded to 12 columns. *)
let label : Status.Change.t -> string = function
  | Added -> "new file:   "
  | Deleted -> "deleted:    "
  | Renamed -> "renamed:    "
  | Copied -> "copied:     "
  | Type_changed -> "typechange: "
  | Modified | Unmodified | Updated_unmerged -> "modified:   "
;;

let staged_line (entry : Status.Entry.t) =
  Option.map (staged_change entry) ~f:(fun change ->
    let name =
      match entry with
      | Renamed_or_copied { original; path; _ } ->
        sprintf "%s -> %s" (quote original) (quote path)
      | entry -> quote (Status.Entry.path entry)
    in
    sprintf "#\t%s%s" (label change) name)
;;

let branch_line ({ oid; head; _ } : Status.Branch.t) =
  match oid, head with
  | None, Some branch -> sprintf "# Initial commit on %s" (quote branch)
  | None, None -> "# Initial commit (HEAD detached)"
  | Some oid, None -> sprintf "# HEAD detached at %s" (String.prefix oid 7)
  | Some _, Some branch -> sprintf "# On branch %s" (quote branch)
;;

let template (status : Status.t) (kind : Kind.t) ~flags ~head_message =
  let message =
    match kind with
    | Commit -> ""
    | Amend ->
      Option.value head_message ~default:""
      |> String.rstrip ~drop:(function
        | ' ' | '\t' | '\n' | '\r' -> true
        | _ -> false)
  in
  let staged =
    match List.filter_map status.entries ~f:staged_line with
    | [] -> [ "#\t(nothing staged)" ]
    | lines -> lines
  in
  let heading =
    match kind with
    | Commit -> "# Changes to be committed:"
    | Amend -> "# Staged changes added to HEAD:"
  in
  let block =
    [ [ "# Write the commit message above. Lines starting with '#' are removed."
      ; "# Space g c commits; Space g a aborts."
      ; "#"
      ; branch_line status.branch
      ]
    ; (match flags with
       | [] -> []
       | flags -> [ "# Switches: " ^ String.concat ~sep:" " flags ])
    ; [ "#"; heading ]
    ; staged
    ]
    |> List.concat
  in
  let lead =
    match message with
    | "" -> [ "" ]
    | message -> [ message; "" ]
  in
  String.concat (List.map (lead @ block) ~f:(fun line -> line ^ "\n"))
;;

let summary (reports : Job.Step_report.t list) =
  List.find_map reports ~f:(fun (report : Job.Step_report.t) ->
    match report.outcome with
    | Ran result when Job.Step_report.succeeded report ->
      List.find (String.split_lines result.stdout) ~f:(fun line ->
        not (String.is_empty (String.strip line)))
      |> Option.map ~f:String.rstrip
    | _ -> None)
;;
