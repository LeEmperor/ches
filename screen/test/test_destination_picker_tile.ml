open! Core
open Ches_screen
module P = Destination_picker_tile
module L = Ches_error.Language_query

let target ?(encoding = L.Utf16) path line character : L.target =
  let position : L.position = { line; character } in
  let range : L.range = { start = position; stop = position } in
  { path; range; selection = range; encoding }
;;
let selected t = P.selected t |> Option.value_exn
let paste t text = P.update t ~rows:6 (Paste text)
let rendered t ~width ~rows = (P.render t ~width ~rows).body
let text t = rendered t ~width:100 ~rows:6 |> List.concat
             |> List.map ~f:(fun s -> s.Span.text) |> String.concat

let%test_unit "search path line and multiple terms without losing target identity" =
  let a = target "/src/alpha.ml" 3 7 in
  let b = target "/src/beta.ml" 41 9 in
  let c = { b with encoding = Utf8; range = a.range } in
  let t = P.create [a; b; c] in
  assert (L.equal_target (selected t) a);
  List.iter ["beta"; "42"; "beta 42"; "beta 42:10"] ~f:(fun query ->
    assert (L.equal_target (selected (paste t query)) b));
  let filtered = paste t "beta" in
  assert (L.equal_target (selected (P.update filtered ~rows:2 Next)) c);
  assert (L.equal_target (selected (P.fit (P.update filtered ~rows:2 Next) ~rows:20)) c);
  let missing = paste t "zzzzzzzz" in
  assert (Option.is_none (P.selected missing));
  assert (String.is_substring (text missing) ~substring:"No matching destinations");
  assert (L.equal_target (selected (P.update missing ~rows:6 Delete_word)) a);
  assert (Option.is_none (P.selected (P.create [])))
;;

let%test_unit "display is one-based character with encoding and fits tiny windows" =
  let t = P.create [target ~encoding:Utf32 "界é.ml" 0 2] in
  List.iter ["界é.ml:1:3"; "line:character"; "UTF-32"] ~f:(fun substring ->
    assert (String.is_substring (text t) ~substring));
  List.iter [0; 1; 2; 3; 12; 80] ~f:(fun width ->
    List.iter [0; 1; 2; 8] ~f:(fun rows ->
      List.iter (rendered t ~width ~rows) ~f:(fun spans ->
        assert (Span.total_width spans <= width);
        List.iter spans ~f:(fun span ->
          assert (Result.is_ok (Ches_core.Text_buffer.validate span.Span.text))));
      let cursor = P.cursor t ~width in
      assert (cursor.column >= 0 && cursor.column <= Int.max 0 (width - 1))))
;;

let%test_unit "selection scrolls into view and query editing is Unicode-aware" =
  let targets = List.init 30 ~f:(fun i -> target (sprintf "/file%02d.ml" i) i 0) in
  let t = List.fold (List.init 20 ~f:Fn.id) ~init:(P.create targets)
      ~f:(fun t _ -> P.update t ~rows:4 Next) in
  assert (L.equal_target (selected t) (List.nth_exn targets 20));
  assert (String.is_substring (text (P.fit t ~rows:6)) ~substring:"> /file20.ml");
  let t = paste t "界é" |> fun t -> P.update t ~rows:6 Backspace in
  [%test_eq: string] (P.query t) "界"
;;
