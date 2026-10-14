open! Core
module Fast = Ches_palette.Fuzzy.Fast

type prepared = { candidate : Model.Candidate.t; text : Fast.Text.t; fields : Fast.Field.t array }
type t = prepared list
type query = Fast.Query.t
type scratch = Fast.Scratch.t

let prepare_candidate candidate =
  let path = Model.Candidate.relative_path candidate in
  let start = match String.rindex path '/' with None -> 0 | Some index -> index + 1 in
  let text = Fast.Text.create path in
  { candidate; text
  ; fields = [| Fast.Field.create text ~byte_start:start ~weight:150
              ; Fast.Field.create text ~byte_start:0 ~weight:100 |] }
;;
let prepare candidates = List.map candidates ~f:prepare_candidate
let rebind prepared candidate =
  if phys_equal prepared.candidate candidate then prepared
  else if Model.Candidate.Id.equal (Model.Candidate.id prepared.candidate) (Model.Candidate.id candidate)
          && String.equal (Model.Candidate.relative_path prepared.candidate) (Model.Candidate.relative_path candidate)
  then { prepared with candidate }
  else invalid_arg "File preparation can only rebind the same raw path"
;;
let compile = Fast.Query.compile
let is_blank = Fast.Query.is_empty
let same_query = Fast.Query.equal
let is_extension = Fast.Query.is_extension
let query_bytes = Fast.Query.retained_bytes
let scratch () = Fast.Scratch.create ()
let no_match = Fast.no_match
let score scratch query prepared = Fast.score ~policy:Loose_subsequence scratch query prepared.fields
let positions query prepared =
  if is_blank query then [] else (
    let raw_positions = Fast.positions ~policy:Loose_subsequence (scratch ()) query prepared.fields in
    Model.Candidate.display_positions prepared.candidate ~raw_positions)
;;
let retained_bytes prepared = Fast.Text.retained_bytes prepared.text
let ownership_bytes prepared = retained_bytes prepared + 512
let rank ~query candidates =
  let query = compile query and scratch = scratch () in
  if is_blank query then List.map candidates ~f:(fun prepared ->
    { Model.Query_result.candidate = prepared.candidate; score = 0; positions = [] })
  else List.filter_map candidates ~f:(fun prepared ->
    let score = score scratch query prepared in
    if score = no_match then None else
      Some { Model.Query_result.candidate = prepared.candidate; score
           ; positions = positions query prepared })
  |> List.stable_sort ~compare:(fun (a : Model.Query_result.t) b -> Int.compare b.score a.score)
;;
