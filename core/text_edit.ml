open! Core

type t = { start : int; stop : int; text : string }
[@@deriving sexp_of, equal]

let sorted_valid text edits =
  let edits = List.sort edits ~compare:(fun a b -> Int.compare a.start b.start) in
  let valid_range e =
    e.start <= e.stop
    && Text_buffer.is_boundary text e.start
    && Text_buffer.is_boundary text e.stop
    && Result.is_ok (Text_buffer.validate e.text)
  in
  let rec disjoint = function
    | [] | [ _ ] -> true
    | a :: (b :: _ as rest) ->
      (a.stop < b.start
       || (a.stop = b.start && a.start < a.stop && b.start < b.stop))
      && disjoint rest
  in
  if List.for_all edits ~f:valid_range && disjoint edits then Ok edits
  else Or_error.error_string "Invalid or overlapping text edits"
;;

let apply_batch text edits =
  let open Or_error.Let_syntax in
  let%bind edits = sorted_valid text edits in
  List.fold_result (List.rev edits) ~init:text ~f:(fun text e ->
    Text_buffer.replace text ~pos:e.start ~len:(e.stop - e.start) e.text
    |> Result.map_error ~f:(fun e -> Error.of_string (Text_buffer.Invalid_text.to_string_hum e)))
;;

let apply text batches = List.fold_result batches ~init:text ~f:apply_batch

let inverse text edits =
  let open Or_error.Let_syntax in
  let%map edits = sorted_valid text edits in
  let _, inverse = List.fold edits ~init:(0, []) ~f:(fun (shift, acc) e ->
    let start = e.start + shift in
    let inverse =
      { start; stop = start + String.length e.text
      ; text = Text_buffer.slice text ~pos:e.start ~len:(e.stop - e.start) }
    in
    shift + String.length e.text - (e.stop - e.start), inverse :: acc)
  in
  (* Adjacent deletions can collapse to coincident inverse insertions. Combine
     adjacent inverses into one replacement, retaining the original text order. *)
  List.fold (List.rev inverse) ~init:[] ~f:(fun acc e ->
    match acc with
    | a :: rest when a.stop = e.start ->
      { a with stop = e.stop; text = a.text ^ e.text } :: rest
    | _ -> e :: acc)
  |> List.rev
;;
