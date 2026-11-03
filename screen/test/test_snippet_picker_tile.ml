open! Core
open Ches_screen
module P = Snippet_picker_tile
module U = Ches_completion.User_snippets

let item id prefix description body : U.item =
  { declaration = { id; prefix; description = Some description; body; scopes = ["ocaml"] }
  ; origin = Ocaml }
;;

let items =
  [ item "clock.id" "aff" "Clocked always block" "${1:clock}\n$0"
  ; item "module.id" "mod" "Module declaration" "module $TM_FILENAME_BASE\n$0"
  ; item "unicode.id" "界é" "Unicode é preview" "界é\nsecond\nthird\nfourth" ]
;;

let selected t = (P.selected t |> Option.value_exn).U.declaration.id
let paste t s = P.update t ~rows:10 (Paste s)
let body t ~width ~rows = (P.render t ~width ~rows).body
let row_text spans = String.concat (List.map spans ~f:(fun span -> span.Span.text))
let rendered t ~width ~rows = body t ~width ~rows |> List.map ~f:row_text |> String.concat ~sep:"\n"

let%test_unit "prefix description and ID filter independently and across fields" =
  let t = P.create items in
  [%test_eq: string] (selected t) "clock.id";
  List.iter ["mod"; "declaration"; "module.id"; "mod declaration"] ~f:(fun q ->
    let filtered = paste t q in
    [%test_eq: string] (P.query filtered) q;
    [%test_eq: string] (selected filtered) "module.id");
  let none = paste t "zzzzzzzz" in
  assert (Option.is_none (P.selected none));
  assert (String.is_substring (rendered none ~width:40 ~rows:10) ~substring:"No matching snippets");
  let cleared = P.update none ~rows:10 Delete_word in
  [%test_eq: string] (P.query cleared) "";
  [%test_eq: string] (selected cleared) "clock.id";
  assert (Option.is_none (P.selected (P.create [])))
;;

let%test_unit "selection follows ID through fitting and selected row remains visible" =
  let items = List.init 30 ~f:(fun i -> item (sprintf "id%02d" i) (sprintf "p%02d" i) "description" "$0") in
  let t = List.fold (List.init 20 ~f:Fn.id) ~init:(P.create items)
      ~f:(fun t _ -> P.update t ~rows:4 Next) in
  [%test_eq: string] (selected t) "id20";
  List.iter [2; 4; 8; 20] ~f:(fun rows ->
    let fitted = P.fit t ~rows in
    [%test_eq: string] (selected fitted) "id20";
    assert (String.is_substring (rendered fitted ~width:50 ~rows) ~substring:"> p20"));
  [%test_eq: string] (selected (P.update t ~rows:4 Previous)) "id19";
  let changed = paste t "p00" in
  [%test_eq: string] (selected changed) "id00"
;;

let%test_unit "preview shows raw body scope origin only when tall and clips Unicode safely" =
  let t = paste (P.create items) "界é" in
  let tall = rendered t ~width:80 ~rows:10 in
  List.iter ["界é"; "Unicode"; "Scope: ocaml"; "Origin: OCaml"; "界é"; "second"]
    ~f:(fun substring -> assert (String.is_substring tall ~substring));
  let short = rendered t ~width:80 ~rows:7 in
  assert (not (String.is_substring short ~substring:"Scope:"));
  List.iter [0; 1; 2; 3; 7; 15; 80] ~f:(fun width ->
    List.iter [0; 1; 2; 7; 8; 10] ~f:(fun rows ->
      let rendered = body t ~width ~rows in
      assert (List.length rendered <= rows);
      List.iter rendered ~f:(fun spans ->
        assert (Span.total_width spans <= width);
        List.iter spans ~f:(fun span ->
          assert (Result.is_ok (Ches_core.Text_buffer.validate span.Span.text))));
      let cursor = P.cursor t ~width in
      assert (cursor.column >= 0 && cursor.column <= Int.max 0 (width - 1))));
  let backspaced = P.update t ~rows:10 Backspace in
  [%test_eq: string] (P.query backspaced) "界"
;;

let%test_unit "key interpretation delegates accept navigation and leaves cancellation to host" =
  let open Ches_input in
  List.iter [Key.Escape; Key.Ctrl 'c'] ~f:(fun key ->
    match P.interpret [key] with Unbound -> () | _ -> failwith "cancel must remain host-owned");
  (match P.interpret [Key.Enter] with
   | Action Palette_tile.Accept -> () | _ -> failwith "expected accept");
  List.iter [Key.Tab; Key.Ctrl 'n'] ~f:(fun key ->
    match P.interpret [key] with
    | Action (Palette_tile.Event Next) -> () | _ -> failwith "expected next");
  List.iter [Key.Shift_tab; Key.Ctrl 'p'] ~f:(fun key ->
    match P.interpret [key] with
    | Action (Palette_tile.Event Previous) -> () | _ -> failwith "expected previous");
  List.iter ['j'; 'k'; ' '] ~f:(fun c ->
    match P.interpret [Key.char c] with
    | Action (Palette_tile.Event (Insert _)) -> () | _ -> failwith "expected query character")
;;

let%test_unit "long body lines and combining floods have bounded preview allocations" =
  List.iter
    [ String.make 65_536 'x'
    ; "界é" ^ String.concat (List.init 20_000 ~f:(fun _ -> "́"))
    ] ~f:(fun source ->
      let t = P.create [item "long" "long" "long body" source] in
      let before = Stdlib.Gc.allocated_bytes () in
      let rendered = body t ~width:12 ~rows:10 in
      let allocated = Stdlib.Gc.allocated_bytes () -. before in
      assert (Float.(allocated < 2_000_000.));
      assert (List.length rendered <= 10);
      List.iter rendered ~f:(fun spans ->
        assert (Span.total_width spans <= 12);
        List.iter spans ~f:(fun span ->
          assert (Result.is_ok (Ches_core.Text_buffer.validate span.Span.text)))));
  let t = P.create [item "long" "long" "long body" (String.make 65_536 'x')] in
  List.iter [0; 1; 2] ~f:(fun width ->
    List.iter [0; 1; 8; 10] ~f:(fun rows ->
      List.iter (body t ~width ~rows) ~f:(fun spans ->
        assert (Span.total_width spans <= width))))
;;
