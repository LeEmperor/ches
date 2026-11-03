open! Core
module M = Ches_navigation_preview_model.Model
module L = Ches_error.Language_query
module T = Ches_core.Text_buffer

let target ?(encoding = L.Utf16) line character stop_line stop_character : L.target =
  let selection : L.range =
    { start = { line; character }; stop = { line = stop_line; character = stop_character } } in
  { path = "test"; range = { start = { line = 0; character = 0 }; stop = { line = 999; character = 0 } };
    selection; encoding }
;;
let collect ?(chunk = 8192) ?(cancelled = fun () -> false) target text =
  let pos = ref 0 in
  let state = M.collect ~source:(Disk { stamp = Some "stamp" }) ~target ~cancelled
      ~read:(fun bytes ~pos:dst ~len ->
        let n = Int.min chunk (Int.min len (String.length text - !pos)) in
        Stdlib.Bytes.blit_string text !pos bytes dst n;
        pos := !pos + n; n) in
  state, !pos
;;
let ready = function M.Ready p -> p | state -> failwith (Sexp.to_string_hum (M.sexp_of_state state))
let buffer text = T.of_string text |> Result.ok |> Option.value_exn
let spans p = List.map p.M.lines ~f:(fun line ->
  List.map line.M.highlights ~f:(fun h -> h.M.start, h.stop))

let%test_unit "selection encoding, CRLF split across reads and multiline" =
  let text = "context\r\n\t😀éX\r\nsecond\r\nlast" in
  List.iter [L.Utf8, 5; Utf16, 3; Utf32, 2] ~f:(fun (encoding, character) ->
    let p = collect ~chunk:1 (target ~encoding 1 character 2 3) text |> fst |> ready in
    assert (List.equal String.equal (List.map p.lines ~f:(fun l -> l.M.text))
      ["context"; "\t😀éX"; "second"; "last"]);
    assert (Poly.equal (spans p) [[]; [5, 8]; [0, 3]; []]));
  let p = collect (target 1 3 1 3) text |> fst |> ready in
  assert (Poly.equal (spans p) [[]; [5, 5]; []; []]);
  let p = collect (target 1 0 2 0) text |> fst |> ready in
  assert (Poly.equal (spans p) [[]; [0, 8]; []; []])
;;

let%test_unit "invalid encoding binary invalid coordinates and cancellation explicit" =
  List.iter ["ok\000bad"; "ok\255"; "\240\159"; "\237\160\128"; "a\rb"] ~f:(fun text ->
    assert (match fst (collect ~chunk:1 (target 0 0 0 0) text) with Unsupported _ -> true | _ -> false));
  List.iter [target (-1) 0 0 0; target 0 2 0 1; target 3 0 3 0;
             target 0 1 0 1; target 0 0 4 0] ~f:(fun target ->
    assert (match fst (collect target "😀") with Invalid_target _ -> true | _ -> false));
  let state, bytes = collect ~cancelled:(fun () -> true) (target 0 0 0 0) "hello" in
  assert (match state with Cancelled -> bytes = 0 | _ -> false)
;;

let%test_unit "far target scan bound and indexed buffer extraction" =
  let text = String.make (M.max_scan_bytes + 100) 'x' ^ "\ntarget" in
  let state, bytes = collect (target 1 0 1 1) text in
  assert (bytes = M.max_scan_bytes);
  assert (match state with Limit _ -> true | _ -> false);
  let text = String.concat ~sep:"\n" (List.init 200000 ~f:(fun _ -> "abcdef")) in
  let b = buffer text in
  let state, work = T.For_testing.measure (fun () ->
    M.of_buffer ~revision:7 (target 199990 2 199990 4) b) in
  let p = ready state in
  assert (p.first_line = 199987 && List.length p.lines = 13);
  assert (work.full_scan_bytes = 0 && work.destination_bytes = 0);
  assert (match p.source with Buffer { revision = 7 } -> true | _ -> false)
;;

let%test_unit "long lines bounded valid UTF8 prefix and target past prefix is limit" =
  let text = String.make 4095 'a' ^ "😀é" ^ String.make 9000 'x' in
  let p = collect (target 0 2 0 4) text |> fst |> ready in
  let line = List.hd_exn p.lines in
  assert (String.length line.text = 4095 && line.truncated);
  assert (Stdlib.String.is_valid_utf_8 line.text);
  assert (match fst (collect (target 0 5000 0 5001) text) with Limit _ -> true | _ -> false);
  let p = M.of_buffer ~revision:0 (target 0 2 0 4) (buffer text) |> ready in
  assert (String.length (List.hd_exn p.lines).text = 4095);
  let text = String.concat ~sep:"\n" (List.init 40 ~f:(fun _ -> String.make 5000 'x')) in
  let p = collect (target 3 0 3 2) text |> fst |> ready in
  assert (List.length p.lines <= M.max_lines);
  assert (List.sum (module Int) p.lines ~f:(fun l -> String.length l.M.text) <= M.max_output_bytes)
;;

let%test_unit "huge invalid line index cannot overflow" =
  assert (match fst (collect (target Int.max_value 0 Int.max_value 0) "x") with
    Invalid_target _ -> true | _ -> false)
;;

let%test_unit "cancellation while scanning and final empty line" =
  let polls = ref 0 in
  let cancelled () = Int.incr polls; !polls > 8 in
  let state, bytes = collect ~cancelled (target 1 0 1 0) (String.make 100000 'x') in
  assert (match state with Cancelled -> bytes <= 8192 | _ -> false);
  let p = collect ~chunk:1 (target 1 0 1 0) "x\r\n" |> fst |> ready in
  assert (Poly.equal (spans p) [[]; [0, 0]]);
  assert (not p.truncated);
  let p = collect (target 0 1 0 2) "aé" |> fst |> ready in
  assert (Poly.equal (spans p) [[1, 2]])
;;
