open! Core
open Ches_vcs

let batch_ssh_command = "ssh -o BatchMode=yes"

(* [bindings] with each name once, at its first position, bound to its last value. *)
let dedup bindings =
  let last = String.Table.create () in
  List.iter bindings ~f:(fun (name, value) -> Hashtbl.set last ~key:name ~data:value);
  List.filter_map bindings ~f:(fun (name, _) ->
    Option.map (Hashtbl.find_and_remove last name) ~f:(fun value -> name, value))
;;

let set bindings name value =
  if List.Assoc.mem bindings name ~equal:String.equal
  then List.map bindings ~f:(fun (n, v) -> if String.equal n name then n, value else n, v)
  else bindings @ [ name, value ]
;;

let environment ~(kind : Exec.Kind.t) ~base ~ssh_command_configured =
  (* No prompt and no editor on the terminal: [true] keeps a prepared message. *)
  let env = set (set (dedup base) "GIT_TERMINAL_PROMPT" "0") "GIT_EDITOR" "true" in
  match kind with
  | Read | Mutate -> env
  | Network ->
    (* git's own precedence: GIT_SSH_COMMAND, then core.sshCommand, then GIT_SSH. *)
    let user_command =
      List.exists [ "GIT_SSH_COMMAND"; "GIT_SSH" ] ~f:(fun name ->
        match List.Assoc.find env name ~equal:String.equal with
        | Some command -> not (String.is_empty command)
        | None -> false)
    in
    if user_command || ssh_command_configured
    then env
    else set env "GIT_SSH_COMMAND" batch_ssh_command
;;

let ssh_command_probe ~cwd =
  Exec.Spec.create
    ~kind:Read
    ~cwd
    ~timeout:(Some (Time_ns.Span.of_int_sec 10))
    ~stdout_limit:(64 * 1024)
    "git"
    [ "--no-pager"; "config"; "--get"; "core.sshCommand" ]
;;

let ssh_command_configured (result : Exec.Result.t) =
  Exec.Result.succeeded result && not (String.is_empty (String.strip result.stdout))
;;
