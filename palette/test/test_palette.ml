open! Core
open Ches_palette

let normal : Catalog.Context.t = { mode = Normal }

(* Opened from view 1 by default. *)
let create ?(catalog = Catalog.default) ?(context = normal) () =
  Palette.create catalog context ~token:1
;;

let type_ palette text =
  String.fold text ~init:palette ~f:(fun palette c ->
    Palette.update palette (Insert (Uchar.of_char c)))
;;

let events palette events = List.fold events ~init:palette ~f:Palette.update

(* The query and the first [limit] results, with the selection marked. *)
let show ?(limit = 4) palette =
  printf "query: %S\n" (Palette.query palette);
  let ids =
    List.map (Palette.results palette) ~f:(fun (result : Catalog.result) ->
      Catalog.Entry.id result.item)
  in
  List.iter (List.take ids limit) ~f:(fun id ->
    let marker =
      if [%equal: Catalog.Id.t option] (Some id) (Palette.selected palette) then ">" else " "
    in
    printf "%s %s\n" marker (Catalog.Id.to_string id));
  if List.length ids > limit then printf "  ... %d more\n" (List.length ids - limit);
  if Option.is_none (Palette.selected palette) then print_endline "(no selection)"
;;

let%expect_test "opening lists available commands and selects the first" =
  show (create ());
  [%expect
    {|
    query: ""
    > file.save
      app.quit
      app.quit-discarding-changes
      edit.undo
      ... 12 more
    |}]
;;

let%expect_test "typing filters; ordinary letters such as j and k are query text" =
  show (type_ (create ()) "rel num");
  [%expect
    {|
    query: "rel num"
    > view.toggle-relative-numbers
    |}];
  show (type_ (create ()) "jk");
  [%expect
    {|
    query: "jk"
    (no selection)
    |}]
;;

let%expect_test "next and previous stop at the ends" =
  let palette = type_ (create ()) "quit" in
  show palette;
  [%expect
    {|
    query: "quit"
    > app.quit
      app.quit-discarding-changes
    |}];
  show (events palette [ Previous ]);
  [%expect
    {|
    query: "quit"
    > app.quit
      app.quit-discarding-changes
    |}];
  show (events palette [ Next; Next; Next ]);
  [%expect
    {|
    query: "quit"
      app.quit
    > app.quit-discarding-changes
    |}];
  show (events palette [ Next; Next; Previous ]);
  [%expect
    {|
    query: "quit"
    > app.quit
      app.quit-discarding-changes
    |}]
;;

let%expect_test "the selected command stays selected while it still matches" =
  let palette = events (type_ (create ()) "numbers") [ Next ] in
  show palette;
  [%expect
    {|
    query: "numbers"
      view.toggle-absolute-numbers
    > view.toggle-relative-numbers
    |}];
  (* Still matches, though it may move: stays selected. *)
  show (type_ palette " toggle");
  [%expect
    {|
    query: "numbers toggle"
      view.toggle-absolute-numbers
    > view.toggle-relative-numbers
    |}];
  (* Backspacing to a broader query keeps it too. *)
  show (events palette [ Backspace; Backspace; Backspace ]);
  [%expect
    {|
    query: "numb"
      view.toggle-absolute-numbers
    > view.toggle-relative-numbers
      view.narrow-tile-10
      view.widen-tile-10
    |}];
  (* Filtered out: the best match is selected instead. *)
  show (type_ palette " abso");
  [%expect
    {|
    query: "numbers abso"
    > view.toggle-absolute-numbers
    |}]
;;

let%expect_test "no matches: no selection, navigation and accept do nothing" =
  let palette = type_ (create ()) "zzz" in
  let palette = events palette [ Next; Previous ] in
  show palette;
  [%expect
    {|
    query: "zzz"
    (no selection)
    |}];
  print_s [%sexp (Palette.accept palette ~context:(Some normal) : int Palette.Accept.t)];
  [%expect {| No_selection |}];
  (* Backspacing until something matches selects the best match again. *)
  show ~limit:1 (events palette [ Backspace; Backspace; Backspace ]);
  [%expect
    {|
    query: ""
    > file.save
      ... 15 more
    |}]
;;

let%expect_test "backspace removes a whole code point, and nothing when empty" =
  let palette = create () in
  let palette = events palette [ Insert (Uchar.of_scalar_exn 0xE9); Insert (Uchar.of_char 'x') ] in
  print_s [%sexp (Palette.query palette : string)];
  let palette = events palette [ Backspace ] in
  print_s [%sexp (Palette.query palette : string)];
  let palette = events palette [ Backspace ] in
  print_s [%sexp (Palette.query palette : string)];
  let palette = events palette [ Backspace ] in
  print_s [%sexp (Palette.query palette : string)];
  [%expect
    {|
    "\195\169x"
    "\195\169"
    ""
    ""
    |}]
;;

let%expect_test "pasted and typed text is one line of valid UTF-8" =
  let paste text =
    let palette = events (create ()) [ Paste text ] in
    print_s [%sexp (Palette.query palette : string)]
  in
  paste "rel\nnum";
  paste "a\r\nb\rc\td";
  paste "a\x00b\x1bc\x7fd\xc2\x85e";
  paste "caf\xc3\xa9 \xff";
  paste "";
  [%expect
    {|
    "rel num"
    "a b c d"
    abcde
    "caf\195\169 \239\191\189"
    ""
    |}];
  (* A control character typed in violation of the key contract is dropped too. *)
  print_s
    [%sexp
      (Palette.query (events (create ()) [ Insert (Uchar.of_scalar_exn 0x07) ]) : string)];
  [%expect {| "" |}];
  (* A pasted query filters like a typed one. *)
  show (events (create ()) [ Paste "rel\nnum" ]);
  [%expect
    {|
    query: "rel num"
    > view.toggle-relative-numbers
    |}]
;;

let%expect_test "accept returns a request for the invoking target" =
  let palette = type_ (create ()) "rln" in
  print_s [%sexp (Palette.accept palette ~context:(Some normal) : int Palette.Accept.t)];
  [%expect
    {|
    (Execute
     ((token 1) (id view.toggle-relative-numbers)
      (action (View Toggle_relative_numbers))))
    |}]
;;

(* A fake adapter: tokens are view numbers, and [views] is the mode of each view that
   still exists. Accepting asks it for the invoking view's current context. *)
let accept_in views palette =
  let context =
    List.Assoc.find views (Palette.token palette) ~equal:Int.equal
    |> Option.map ~f:(fun mode : Catalog.Context.t -> { mode })
  in
  print_s [%sexp (Palette.accept palette ~context : int Palette.Accept.t)]
;;

let%expect_test "accept refuses a target that has gone, never using another" =
  let palette = Palette.create Catalog.default normal ~token:1 |> Fn.flip type_ "save" in
  accept_in [ 1, Ches_core.Mode.Normal; 2, Normal ] palette;
  [%expect
    {|
    (Execute ((token 1) (id file.save) (action Save)))
    |}];
  accept_in [ 2, Normal ] palette;
  [%expect {| (Target_gone 1) |}]
;;

let%expect_test "accept rechecks availability in the target's current context" =
  let palette = type_ (create ()) "save" in
  accept_in [ 1, Insert ] palette;
  [%expect {| (Unavailable (token 1) (id file.save)) |}];
  let catalog =
    Catalog.create
      [ Catalog.Entry.create
          ~id:"test.insert-only"
          ~title:"Insert only"
          ~available:(fun context -> Ches_core.Mode.equal context.mode Insert)
          (Editor Undo)
      ; Catalog.Entry.create ~id:"test.normal" ~title:"Normal" (Editor Redo)
      ]
    |> Or_error.ok_exn
  in
  (* The list reflects the context the palette was opened in. *)
  let palette = create ~catalog ~context:{ mode = Insert } () in
  show palette;
  [%expect
    {|
    query: ""
    > test.insert-only
    |}];
  accept_in [ 1, Insert ] palette;
  accept_in [ 1, Normal ] palette;
  [%expect
    {|
    (Execute ((token 1) (id test.insert-only) (action Undo)))
    (Unavailable (token 1) (id test.insert-only))
    |}]
;;
