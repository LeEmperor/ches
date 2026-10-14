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
  List.map2_exn files (Session.buffer_labels session) ~f:(fun (id, c) (_, label) ->
    { id; label
    ; active = Option.equal Buffer_id.equal (Some id) (Session.active_id session)
    ; modified = Editor.is_dirty (Controller.editor c)
    ; missing = Controller.is_missing c })
;;
