open! Core

type t =
  { generation : int
  ; sequence : int
  ; lanes : Job.Id.t String.Map.t
  }
[@@deriving sexp_of, equal]

let create () = { generation = 0; sequence = 0; lanes = String.Map.empty }
let generation t = t.generation
let invalidate t = { t with generation = t.generation + 1; lanes = String.Map.empty }

let issue ?lane t =
  let sequence = t.sequence + 1 in
  let id = { Job.Id.generation = t.generation; sequence } in
  let lanes =
    match lane with
    | None -> t.lanes
    | Some lane -> Map.set t.lanes ~key:lane ~data:id
  in
  { t with sequence; lanes }, id
;;

let latest t ~lane = Map.find t.lanes lane

let is_current t ?lane (id : Job.Id.t) =
  id.generation = t.generation
  &&
  match lane with
  | None -> true
  | Some lane -> Option.exists (latest t ~lane) ~f:(Job.Id.equal id)
;;

let accepts t (report : Job.Report.t) = is_current t ?lane:report.lane report.id
