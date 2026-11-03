open! Core
open Ches_screen
module P = Destination_picker_tile
module L = Ches_error.Language_query

let target ?(encoding = L.Utf16) path line character : L.target =
  let position : L.position = { line; character } in
  let range : L.range = { start = position; stop = position } in
  { path; range; selection = range; encoding }
;;

module Preview = Ches_navigation_preview_model.Model
let preview_rendered t ~width ~rows = (P.render t ~width ~rows).body

let preview text target =
  let buffer = Ches_core.Text_buffer.of_string text |> Result.ok |> Option.value_exn in
  Preview.of_buffer ~revision:4 target buffer
;;

let%test_unit "short preview window includes target and right aligned line numbers" =
  let a = target "file.ml" 10 0 in
  let source = String.concat ~sep:"\n" (List.init 30 ~f:(fun n -> sprintf "row%d" (n + 1))) in
  let t = P.create [a] |> fun t -> P.with_preview t (Some (preview source a)) in
  let body = preview_rendered t ~width:40 ~rows:8 |> List.concat
      |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  assert (String.is_substring body ~substring:"11 │ row11");
  assert (String.is_substring body ~substring:"10 │ row10")
;;

let%test_unit "every small preview allocation displays the exact Unicode target or zero width marker" =
  List.iter [L.Utf16, 3, 4; Utf32, 2, 3] ~f:(fun (encoding, start, stop) ->
    List.iter [start, stop, "é"; stop, stop, "X"] ~f:(fun (start, stop, expected) ->
      let a = target ~encoding "file.ml" 10 start in
      let a = { a with selection = { a.selection with stop = { line = 10; character = stop } } } in
      let source = String.concat ~sep:"\r\n" (List.init 40 ~f:(fun n ->
        if n = 10 then "\t😀éX" else sprintf "context%d" n)) in
      let pos = ref 0 in
      let state = Preview.collect ~source:(Disk { stamp = None }) ~target:a
          ~cancelled:(fun () -> false) ~read:(fun bytes ~pos:dst ~len ->
            let n = Int.min len (Int.min 1 (String.length source - !pos)) in
            Stdlib.Bytes.blit_string source !pos bytes dst n;
            pos := !pos + n; n) in
      let t = P.with_preview (P.create [a]) (Some state) in
      List.iter (List.init 13 ~f:(fun i -> i + 8)) ~f:(fun rows ->
        let body = preview_rendered t ~width:40 ~rows in
        let highlighted = List.concat body
            |> List.filter ~f:(fun s -> Style.equal s.Span.style (Style.document ~overlay:Selection ()))
            |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
        [%test_eq: string] highlighted expected;
        let text = List.concat body |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
        assert (String.is_substring text ~substring:"11 │"))))
;;

let%test_unit "target beyond bounded line prefix displays limit without highlighting context" =
  let a = target "file.ml" 3 5000 in
  let source = "before\nbefore\nbefore\n" ^ String.make 9000 'x' in
  let t = P.with_preview (P.create [a]) (Some (preview source a)) in
  let body = preview_rendered t ~width:60 ~rows:8 |> List.concat in
  assert (List.for_all body ~f:(fun s ->
    not (Style.equal s.Span.style (Style.document ~overlay:Selection ()))));
  let text = List.map body ~f:(fun s -> s.Span.text) |> String.concat in
  assert (String.is_substring text ~substring:"Preview limit:")
;;

let%test_unit "preview preserves counts and identity and clears when selection changes" =
  let a = target "alpha.ml" 0 1 and b = target "beta.ml" 0 0 in
  let t = P.create [a; a; b] in
  let shown = P.with_preview t (Some (preview "abc" a)) in
  [%test_eq: int option] (P.selected_identity shown) (Some 0);
  [%test_eq: string] (P.render shown ~width:50 ~rows:12).title
    (P.render t ~width:50 ~rows:12).title;
  let next = P.update shown ~rows:12 Next in
  [%test_eq: int option] (P.selected_identity next) (Some 1);
  let body = (P.render next ~width:50 ~rows:12).body |> List.concat
    |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  assert (not (String.is_substring body ~substring:"buffer r4"));
  let filtered = P.update shown ~rows:12 (Paste "beta") in
  [%test_eq: int option] (P.selected_identity filtered) (Some 2);
  [%test_eq: string] (P.render filtered ~width:50 ~rows:12).title
    "Choose destination (1/3)"
;;

let%test_unit "safe preview glyphs exact selection and tiny clipped dimensions" =
  let a = target "file.ml" 0 2 in
  let stop : L.position = { line = 0; character = 4 } in
  let a = { a with selection = { a.selection with stop } } in
  let t = P.create [a] |> fun t -> P.with_preview t
      (Some (preview "\tA😀é\027[31m" a)) in
  List.iter [0; 1; 2; 7; 12; 40] ~f:(fun width ->
    List.iter [0; 1; 7; 8; 12] ~f:(fun rows ->
      let body = preview_rendered t ~width ~rows in
      assert (List.length body <= rows);
      List.iter body ~f:(fun spans ->
        assert (Span.total_width spans <= width);
        List.iter spans ~f:(fun s ->
          assert (Stdlib.String.is_valid_utf_8 s.Span.text);
          assert (not (String.exists s.text ~f:(fun c -> Char.to_int c < 32)))))));
  let body = preview_rendered t ~width:40 ~rows:12 in
  let selection = Style.document ~overlay:Selection () in
  let highlighted = List.concat body |> List.filter ~f:(fun s -> Style.equal s.Span.style selection)
      |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  [%test_eq: string] highlighted "😀";
  List.iter (List.take body 5 |> List.concat) ~f:(fun s ->
    assert (not (Style.equal s.Span.style selection)));
  let zero = target "file.ml" 0 3 in
  let t = P.with_preview (P.create [zero]) (Some (preview "abc" zero)) in
  let highlighted = preview_rendered t ~width:40 ~rows:12 |> List.concat
      |> List.filter ~f:(fun s -> Style.equal s.Span.style selection)
      |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  [%test_eq: string] highlighted " "
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

let%test_unit "references heading and counts preserve selection query and navigation" =
  let a = target "/alpha.ml" 0 0 and b = target "/beta.ml" 2 3 in
  let t = P.create [a; b] in
  [%test_eq: string] (P.render t ~width:80 ~rows:5).title "Choose destination (2/2)";
  let t = P.update t ~rows:5 Next |> fun t -> P.with_title t "Find references" in
  assert (L.equal_target (selected t) b);
  let rendered = P.render t ~width:80 ~rows:5 in
  [%test_eq: string] rendered.title "Find references (2/2)";
  assert (String.is_substring (Option.value_exn rendered.footer).text ~substring:"2/2");
  let t = paste t "beta" |> fun t -> P.with_title t "Find references" in
  [%test_eq: string] (P.query t) "beta";
  assert (L.equal_target (selected t) b);
  [%test_eq: string] (P.render t ~width:80 ~rows:5).title "Find references (1/2)";
  [%test_eq: string] (P.render (paste t "absent") ~width:80 ~rows:5).title "Find references (0/2)";
  [%test_eq: string] (P.render (P.with_title (P.create []) "Find references") ~width:80 ~rows:5).title
    "Find references (0/0)";
  let t = P.with_title (P.create [b]) "Find references" in
  assert (L.equal_target (selected (P.update t ~rows:2 Next)) b)
;;
