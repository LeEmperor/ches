open! Core
open Ches_core

type t =
  { id : Buffer_id.t
  ; label : string
  ; active : bool
  ; modified : bool
  ; missing : bool
  }
[@@deriving sexp_of]

let of_session session =
  let files = Session.buffers session in
  let parts c = Option.value_map (Editor.path (Controller.editor c))
    ~default:[ "[unnamed]" ] ~f:(fun p -> String.split p ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)) in
  let suffix parts n = List.drop parts (Int.max 0 (List.length parts - n)) in
  List.map files ~f:(fun (id, c) ->
    let path = parts c in
    let rec label n =
      let candidate = suffix path n in
      if n < List.length path && List.exists files ~f:(fun (other, c) ->
        not (Buffer_id.equal id other) && [%equal: string list] candidate (suffix (parts c) n))
      then label (n + 1)
      else String.concat ~sep:"/" (List.map candidate ~f:Directory_identity.encode_name)
    in
    { id; label = label 1
    ; active = Option.equal Buffer_id.equal (Some id) (Session.active_id session)
    ; modified = Editor.is_dirty (Controller.editor c)
    ; missing = Controller.is_missing c })
;;
