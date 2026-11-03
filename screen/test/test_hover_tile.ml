open! Core
open Ches_screen
module H = Hover_tile
module L = Ches_error.Language_query

let create kind value = H.create { L.contents = [{ kind; value }]; range = None }
let body t ~width ~rows = (H.render t ~width ~rows).body
let text t ~width ~rows =
  body t ~width ~rows |> List.map ~f:(fun spans ->
    String.concat (List.map spans ~f:(fun s -> s.Span.text))) |> String.concat ~sep:"\n"
;;

let%test_unit "plaintext is literal; Markdown headings fences languages links are readable" =
  let source = "# Heading\n- list\n```ocaml\nlet x = 1\n```\n[label](https://example.test)" in
  let plain = text (create Plaintext source) ~width:80 ~rows:20 in
  assert (String.is_substring plain ~substring:"# Heading");
  assert (String.is_substring plain ~substring:"```ocaml");
  let markdown = text (create Markdown source) ~width:80 ~rows:20 in
  assert (not (String.is_substring markdown ~substring:"# Heading"));
  List.iter ["Heading"; "- list"; "[code: ocaml]"; "let x = 1";
             "[/code]"; "label"; "https://example.test"] ~f:(fun substring ->
    assert (String.is_substring markdown ~substring));
  let t = H.create { L.contents = [{kind = Plaintext; value = "first"};
                                   {kind = Markdown; value = "## second"}]; range = None } in
  List.iter ["first"; "second"] ~f:(fun substring ->
    assert (String.is_substring (text t ~width:40 ~rows:5) ~substring))
;;

let%test_unit "wrapping scrolling and resize clamp to content rows" =
  let t = create Plaintext "abcdef\nsecond\nthird\nfourth" in
  let rendered = text t ~width:3 ~rows:2 in
  [%test_eq: string] rendered "abc\ndef";
  let t = H.scroll t ~width:3 ~rows:2 Down in
  [%test_eq: int] (H.top t) 1;
  assert (String.is_prefix (text t ~width:3 ~rows:2) ~prefix:"def");
  let last = H.scroll t ~width:3 ~rows:2 Last in
  assert (H.top last > H.top t);
  [%test_eq: int] (H.top (H.scroll last ~width:3 ~rows:2 First)) 0;
  [%test_eq: int] (H.top (H.fit last ~width:80 ~rows:100)) 0;
  assert (H.top (H.scroll t ~width:3 ~rows:2 Half_down) > H.top t)
;;

let%test_unit "tiny windows Unicode controls and hostile lines remain bounded" =
  List.iter ["界é é\t\027[31m\n🙂"; String.make 100_000 'x';
             "e" ^ String.concat (List.init 50_000 ~f:(fun _ -> "́")) ^ "end"]
    ~f:(fun source ->
      let t = create Plaintext source in
      List.iter [0; 1; 2; 3; 12; 80] ~f:(fun width ->
        List.iter [0; 1; 2; 8] ~f:(fun rows ->
          let rendered = body t ~width ~rows in
          assert (List.length rendered <= rows);
          List.iter rendered ~f:(fun spans ->
            assert (Span.total_width spans <= width);
            List.iter spans ~f:(fun span ->
              assert (String.length span.Span.text < 10_000);
              assert (not (String.contains span.text '\027'));
              assert (Result.is_ok (Ches_core.Text_buffer.validate span.text)))))));
  let t = create Plaintext ("e" ^ String.concat (List.init 50_000 ~f:(fun _ -> "́"))) in
  assert (String.length (text t ~width:2 ~rows:1) < 100);
  let t = create Plaintext (String.make 100_000 'x') in
  let last = H.scroll t ~width:20 ~rows:2 Last in
  assert (String.is_substring (text last ~width:20 ~rows:2) ~substring:"…")
;;

let%test_unit "hover keys expose closure and shared scroll prefixes" =
  let open Ches_input in
  List.iter [Key.Escape; Key.char 'q'] ~f:(fun key ->
    match H.interpret [key] with Action Close -> () | _ -> failwith "close");
  List.iter [Key.char 'j'; Key.char 'k'; Key.Ctrl 'e'; Key.Ctrl 'y';
             Key.Ctrl 'd'; Key.Ctrl 'u'; Key.char 'G'] ~f:(fun key ->
    match H.interpret [key] with Action (Scroll _) -> () | _ -> failwith "scroll");
  (match H.interpret [Key.char 'g'; Key.char 'g'] with
   | Action (Scroll First) -> () | _ -> failwith "first");
  (match H.interpret [Key.char 'g'] with
   | Prefix -> () | _ -> failwith "prefix")
;;

let%test_unit "aggregate content truncation is visible even at an exact block boundary" =
  let contents = List.init 256 ~f:(fun _ -> { L.kind = Markdown; value = String.make 1024 'x' })
      @ [{ L.kind = Markdown; value = "omitted documentation" }] in
  let t = H.create { L.contents; range = None } in
  let last = H.scroll t ~width:80 ~rows:2 Last in
  let rendered = text last ~width:80 ~rows:2 in
  assert (String.is_substring rendered ~substring:"…");
  assert (not (String.is_substring rendered ~substring:"omitted documentation"))
;;
