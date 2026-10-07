open! Core

module Fuzzy = Ches_palette.Fuzzy

type field = Basename of int | Path
type t = (Model.Candidate.t, field) Fuzzy.Prepared.t list

let fields candidate =
  let path = Model.Candidate.relative_path candidate in
  let start =
    match String.rindex path '/' with
    | None -> 0
    | Some index -> index + 1
  in
  [ { Fuzzy.Field.tag = Basename start
    ; text = String.sub path ~pos:start ~len:(String.length path - start)
    ; weight = 150
    }
  ; { Fuzzy.Field.tag = Path; text = path; weight = 100 }
  ]
;;

let prepare candidates =
  List.map candidates ~f:(fun candidate -> Fuzzy.Prepared.create (candidate, fields candidate))
;;

let result (matched : _ Fuzzy.Match.t) =
  let raw_positions =
    List.concat_map matched.positions ~f:(fun (field, offsets) ->
      match field.tag with
      | Path -> offsets
      | Basename start -> List.map offsets ~f:(( + ) start))
  in
  { Model.Query_result.candidate = matched.item
  ; score = matched.score
  ; positions = Model.Candidate.display_positions matched.item ~raw_positions
  }
;;

let rank ~query t =
  Fuzzy.rank_prepared ~policy:Loose_subsequence ~query t |> List.map ~f:result
;;
