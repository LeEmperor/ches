open! Core
open Ches_app

(** Status tile composition is separate from both status fields and buffer data.
    Keep up to three metadata rows (mode / pending / urgent feedback by priority)
    and devote the remainder to buffers. Even the smallest tile retains a buffer
    row; both renderers do their own bounded fitting. *)
let body ~rect fields (buffers : Open_buffers.t list) =
  if List.is_empty buffers then (Status.vertical ~rect fields).rows else
  let fields = List.filter fields ~f:(fun field ->
    not (List.mem [ Status_field.Id.Filename; Dirty ] field.Status_field.id
      ~equal:Status_field.Id.equal)) in
  let metadata_rows = Int.min 3 (Int.max 0 (rect.Geometry.Rect.height - 1)) in
  let metadata = Status.vertical ~rect:{ rect with height = metadata_rows } fields in
  metadata.rows @ Buffer_rows.render buffers ~width:rect.width ~rows:(rect.height - metadata_rows)
;;
