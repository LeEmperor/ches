open! Core
module Candidate = Ches_file_picker.Model.Candidate
module Run_id = Ches_file_picker.Model.Run_id
module Status = Ches_file_picker.Model.Discovery

type request = { run_id : Run_id.t; root : string; query : string }
type hit =
  { candidate : Candidate.t
  ; line : int
  ; start_byte : int
  ; end_byte : int
  ; text : string
  }
type snapshot = { request : request; hits : hit list; status : Status.status }
type 'token intent =
  { token : 'token
  ; path : string
  ; line : int
  ; byte_column : int
  ; end_byte : int
  ; expected_text : string
  ; literal : string
  }

let same_request a b =
  Run_id.equal a.run_id b.run_id && String.equal a.root b.root && String.equal a.query b.query
;;
let same_hit a b =
  Candidate.Id.equal (Candidate.id a.candidate) (Candidate.id b.candidate)
  && a.line = b.line && a.start_byte = b.start_byte && a.end_byte = b.end_byte
;;
let payload (h : hit) =
  String.length (Candidate.root h.candidate) + String.length (Candidate.path h.candidate)
  + String.length (Candidate.relative_path h.candidate)
  + String.length (Candidate.display_path h.candidate) + String.length h.text
;;

(* rg JSON encodes arbitrary bytes as base64, independently for path and lines. *)
let parse ~request raw =
  Or_error.try_with (fun () ->
    let open Yojson.Basic.Util in
    let json = Yojson.Basic.from_string raw in
    let field value name = member name value in
    let bytes value =
      match field value "text", field value "bytes" with
      | `String text, `Null -> text
      | `Null, `String encoded -> Base64.decode_exn encoded
      | _ -> failwith "Invalid ripgrep text/bytes field"
    in
    match field json "type" |> to_string with
    | "begin" | "end" | "summary" -> []
    | "match" ->
      let data = field json "data" in
      let path = bytes (field data "path") in
      let path = Option.value (String.chop_prefix path ~prefix:"./") ~default:path in
      let candidate = Candidate.create ~root:request.root ~relative_path:path |> Or_error.ok_exn in
      let text = bytes (field data "lines") in
      let line = field data "line_number" |> to_int in
      if line <= 0 || String.is_empty request.query then failwith "Invalid match line/query";
      let hits = field data "submatches" |> to_list |> List.map ~f:(fun sub ->
        let start_byte = field sub "start" |> to_int in
        let end_byte = field sub "end" |> to_int in
        if start_byte < 0 || end_byte <= start_byte || end_byte > String.length text
           || not (String.equal (String.sub text ~pos:start_byte ~len:(end_byte - start_byte)) request.query)
           || not (String.equal (bytes (field sub "match")) request.query)
        then failwith "Invalid literal match offsets";
        { candidate; line; start_byte; end_byte; text }) in
      if List.is_empty hits then failwith "Missing submatches";
      if Ches_file_picker.Scope.visible_path path then hits else []
    | _ -> failwith "Unknown ripgrep JSON record")
;;

type 'token t =
  { token : 'token
  ; mutable query : string
  ; mutable snapshot : snapshot
  ; mutable selected : hit option
  ; mutable closed : bool
  ; mutable query_truncated : bool
  }
let create ~token snapshot =
  { token; query = snapshot.request.query; snapshot
  ; selected = List.hd snapshot.hits; closed = false; query_truncated = false }
;;
let query t = t.query
let snapshot t = t.snapshot
let selected t = t.selected
let pending t = not (String.equal t.query t.snapshot.request.query)
let closed t = t.closed
let query_truncated t = t.query_truncated
let expect t (request : request) =
  if not t.closed && String.equal t.query request.query then (
    t.snapshot <- { request; hits = []; status = Status.Loading };
    t.selected <- None)
;;
let install t snapshot =
  if t.closed || not (same_request t.snapshot.request snapshot.request)
     || not (String.equal t.query snapshot.request.query)
  then false
  else (
    let found = Option.bind t.selected ~f:(fun selected -> List.find snapshot.hits ~f:(same_hit selected)) in
    t.selected <- Option.first_some found (List.hd snapshot.hits);
    t.snapshot <- snapshot;
    true)
;;
let update t event =
  if not t.closed then (
    let bounded query =
      if String.length query <= 4096 then query
      else (
        let prefix = String.prefix query 4096 in
        let rec trim n =
          let prefix = String.prefix prefix n in
          if Stdlib.String.is_valid_utf_8 prefix then prefix else trim (n - 1)
        in trim 4096)
    in
    let edit query =
      t.query_truncated <- String.length query > 4096;
      t.query <- bounded query
    in
    let move delta =
      if not (pending t) then (
        let hits = t.snapshot.hits in
        let index = Option.bind t.selected ~f:(fun selected -> List.findi hits ~f:(fun _ h -> same_hit selected h))
                    |> Option.value_map ~default:0 ~f:fst in
        t.selected <- List.nth hits (Int.max 0 (Int.min (List.length hits - 1) (index + delta))))
    in
    match (event : Ches_palette.Palette.Event.t) with
    | Insert c -> edit (Ches_palette.Query.append t.query (Uchar.Utf8.to_string c))
    | Paste text -> edit (Ches_palette.Query.append t.query text)
    | Backspace -> edit (Ches_palette.Query.backspace t.query)
    | Delete_word -> edit (Ches_palette.Query.delete_word t.query)
    | Next -> move 1
    | Previous -> move (-1))
;;
let close t =
  t.closed <- true;
  t.selected <- None;
  t.snapshot <- { t.snapshot with hits = [] }
;;
let cancel t ~release = if not t.closed then (close t; release ())
let accept t ~release ~consume =
  if not t.closed && not (pending t) && not (String.is_empty t.query) then
    Option.iter t.selected ~f:(fun (hit : hit) ->
      let intent =
        { token = t.token; path = Candidate.path hit.candidate; line = hit.line
        ; byte_column = hit.start_byte; end_byte = hit.end_byte
        ; expected_text = hit.text; literal = t.snapshot.request.query }
      in
      close t;
      release ();
      consume intent)
;;
