open! Core
module Buffer_id = Ches_app.Buffer_id
module View_id = Ches_tile.View_id

module Entry = struct
  type t =
    | File of Buffer_id.t
    | View of View_id.t
  [@@deriving sexp_of, equal]
end

module Item = struct
  type t =
    { label : string
    ; active : bool
    ; modified : bool
    ; missing : bool
    }
  [@@deriving sexp_of]

  let of_file ({ label; active; modified; missing; id = _ } : Ches_app.Open_buffers.t) =
    { label; active; modified; missing }
  ;;
end

(* [order] may name closed files or views no longer placed [Tab]; [entries] filters
   them, so the session never has to tell the strip. *)
type t =
  { order : Entry.t list
  ; active : View_id.t option
  }
[@@deriving sexp_of]

let empty = { order = []; active = None }

let entries t ~files ~views =
  let present : Entry.t -> bool = function
    | File id -> List.mem files id ~equal:Buffer_id.equal
    | View id -> List.mem views id ~equal:View_id.equal
  in
  let kept = List.filter t.order ~f:present in
  let seen entry = List.mem kept entry ~equal:Entry.equal in
  kept
  @ List.filter_map files ~f:(fun id ->
    Option.some_if (not (seen (File id))) (Entry.File id))
  @ List.filter_map views ~f:(fun id ->
    Option.some_if (not (seen (View id))) (Entry.View id))
;;

let active t = t.active

let add t ~files ~views view ~after =
  let views = List.filter views ~f:(fun id -> not (View_id.equal id view)) in
  let current = entries t ~files ~views in
  let order =
    match after with
    | Some after when List.mem current after ~equal:Entry.equal ->
      List.concat_map current ~f:(fun entry ->
        if Entry.equal entry after then [ entry; Entry.View view ] else [ entry ])
    | Some _ | None -> current @ [ Entry.View view ]
  in
  { order; active = Some view }
;;

let activate t active = { t with active }
