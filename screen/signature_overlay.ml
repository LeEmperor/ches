open! Core
module Q = Ches_error.Language_query

type t = { payload : Q.signature_help; index : int }

let create (payload : Q.signature_help) =
  { payload; index = Int.max 0 (Int.min payload.active_signature (List.length payload.signatures - 1)) }
;;

let cycle t delta =
  let count = List.length t.payload.signatures in
  if count = 0 then t else { t with index = (t.index + delta + count) mod count }
;;

let bounded text =
  let rec boundary n =
    if n > 0 && n < String.length text && Char.to_int text.[n] land 0xc0 = 0x80
    then boundary (n - 1) else n in
  String.prefix text (boundary (Int.min 1024 (String.length text)))
;;

let rows t =
  match List.nth t.payload.signatures t.index with
  | None -> []
  | Some signature ->
    let label = bounded signature.label in
    let index = Option.value
      (Option.first_some signature.active_parameter t.payload.active_parameter) ~default:0 in
    let active = Option.first_some
      (if index < 0 then None else List.nth signature.parameters index)
      (List.hd signature.parameters) in
    let spans text style = Span.of_text text ~style ~special:style in
    let boundary n = n >= 0 && n <= String.length label
      && (n = String.length label || Char.to_int label.[n] land 0xc0 <> 0x80) in
    let label = match active with
      | Some p when boundary p.label_start && boundary p.label_stop && p.label_start <= p.label_stop ->
        spans (String.prefix label p.label_start) Status
        @ spans (String.sub label ~pos:p.label_start ~len:(p.label_stop - p.label_start)) Pending
        @ spans (String.drop_prefix label p.label_stop) Status
      | _ -> spans label Status in
    let docs = Option.value_map active ~default:[] ~f:(fun p -> p.Q.documentation)
      @ signature.documentation in
    let docs = List.concat_map (List.take docs 2) ~f:(fun content ->
      String.split (bounded content.Q.value) ~on:'\n') |> Fn.flip List.take 2 in
    label :: (List.map docs ~f:(fun text -> spans text Hint))
    @ [spans (sprintf "Signature %d/%d · Insert: Ctrl-g next / Ctrl-b previous · Esc dismiss"
        (t.index + 1) (List.length t.payload.signatures)) Hint]
;;
