open! Core
open Ches_tile

(* Wide CJK and emoji, a zero-width combining acute, and narrow everything else: the
   cases the screen's real width table distinguishes. *)
let cell_width u =
  match Uchar.to_scalar u with
  | 0x0301 -> 0
  | c when c >= 0x1100 -> 2
  | _ -> 1
;;

let keys s =
  List.map (Key_notation.keys s) ~f:(function
    | Key key -> key
    | Paste _ -> assert false)
;;

(* Type [s] into [t] the way the host does: pending keys accumulate until they make an
   action. Prints each effect. *)
let type_ ?(width = 10) ?(rows = 3) t s =
  let t, pending =
    List.fold (keys s) ~init:(t, []) ~f:(fun (t, pending) key ->
      let keys = pending @ [ key ] in
      match (Text_view.interpret t keys : _ Content_key.t) with
      | Prefix -> t, keys
      | Unbound -> t, []
      | Action action ->
        let t, effect = Text_view.perform t ~width ~rows action in
        Option.iter effect ~f:(fun effect ->
          match (effect : Text_view.Effect.t) with
          | Copy register ->
            print_s
              [%message
                (Text_view.Effect.describe_copy register)
                  ~clipboard:(Ches_core.Register.to_string register : string)]
          | Notice text -> print_endline ("notice: " ^ text));
        t, [])
  in
  assert (List.is_empty pending);
  t
;;

(* The visible rows, with [[...]] around the selected glyphs, [$] for a selected line
   break, and [#] before the cursor's glyph (or on an empty row). *)
let show ?(width = 10) ?(rows = 3) t =
  let t = Text_view.fit t ~width ~rows in
  let selection = Text_view.selection t in
  let cursor_row, cursor_col = Text_view.cursor_cell t ~width in
  let selected offset =
    Option.exists selection ~f:(fun (start, stop) -> start <= offset && offset < stop)
  in
  List.iteri (Text_view.rows t ~width) ~f:(fun i (row : Text_view.Row.t) ->
    if i >= Text_view.top t && i < Text_view.top t + rows
    then (
      let cells =
        Array.to_list row.glyphs
        |> List.map ~f:(fun (g : Ches_core.Cell_layout.Glyph.t) ->
          let text = if selected (row.line_start + g.pos) then "[" ^ g.text ^ "]" else g.text in
          if i = cursor_row && g.col - row.first_col = cursor_col && g.width > 0
          then "#" ^ text
          else text)
      in
      let empty = if Array.is_empty row.glyphs && i = cursor_row then "#" else "" in
      let break = if Option.exists row.break ~f:selected then "$" else "" in
      printf "%2d |%s%s%s|\n" i (String.concat cells) empty break));
  printf "top %d cursor %d\n" (Text_view.top t) (Text_view.cursor t)
;;

let create text = Text_view.create ~cell_width text

let%expect_test "movement reaches rows beyond the viewport and keeps the cursor visible" =
  let t = create "alpha beta gamma delta epsilon zeta eta theta iota kappa" in
  show t;
  [%expect
    {|
     0 |#alpha beta|
     1 | gamma del|
     2 |ta epsilon|
    top 0 cursor 0
    |}];
  let t = type_ t "jjjj" in
  show t;
  [%expect
    {|
     2 |ta epsilon|
     3 | zeta eta |
     4 |#theta iota|
    top 2 cursor 40
    |}];
  let t = type_ t "G$" in
  show t;
  [%expect
    {|
     3 | zeta eta |
     4 |theta iota|
     5 | kapp#a|
    top 3 cursor 55
    |}];
  let t = type_ t "<C-u>" in
  show t;
  [%expect
    {|
     2 |ta epsilon|
     3 | zeta eta |
     4 |theta# iota|
    top 2 cursor 45
    |}];
  (* [gg], then words across a wrap; [b] returns to word starts. *)
  let t = type_ t "ggwww" in
  show t;
  [%expect
    {|
     0 |alpha beta|
     1 | gamma #del|
     2 |ta epsilon|
    top 0 cursor 17
    |}];
  ignore (type_ t "bb" |> fun t -> show t; t : Text_view.t);
  [%expect
    {|
     0 |alpha #beta|
     1 | gamma del|
     2 |ta epsilon|
    top 0 cursor 6
    |}]
;;

let%expect_test "rows and the cursor follow display cells: wide, combining, TAB" =
  (* "e" + combining acute is one cell; 界 and 🙂 are two each; the TAB fills to 8. *)
  let t = create "e\xcc\x81x界🙂\tz\nnext" in
  show ~width:6 t;
  [%expect
    {|
     0 |#éx界🙂|
     1 |  z|
     2 |next|
    top 0 cursor 0
    |}];
  (* [l] skips the combining mark; [j] keeps the display column across rows. *)
  let t = type_ ~width:6 t "lllj" in
  show ~width:6 t;
  [%expect
    {|
     0 |éx界🙂|
     1 |  #z|
     2 |next|
    top 0 cursor 12
    |}];
  (* [v] selects inclusively; copying gives the source bytes, combining mark and TAB
     included, without the wrap. *)
  let t = type_ ~width:6 t "0vjj" in
  show ~width:6 t;
  [%expect
    {|
     0 |[e][́][x][界][🙂]|
     1 |[  ][z]$|
     2 |#[n]ext|
    top 0 cursor 14
    |}];
  let t = type_ ~width:6 t "vggvly" in
  [%expect {| ("Copied 3 characters" (clipboard "e\204\129x")) |}];
  print_s [%sexp (Text_view.cursor t : int), (Text_view.visual t : Text_view.Kind.t option)];
  [%expect {| (0 ()) |}]
;;

let%expect_test "linewise selection, line copies, empty lines, and Visual switching" =
  let t = create "one\n\nthree four" in
  let t = type_ t "jv" in
  show t;
  [%expect
    {|
     0 |one|
     1 |#$|
     2 |three four|
    top 0 cursor 4
    |}];
  (* A characterwise end on an empty line includes its break. *)
  let t = type_ t "y" in
  [%expect {| ("Copied 1 character" (clipboard "\n")) |}];
  let t = type_ t "Vj" in
  show t;
  [%expect
    {|
     0 |one|
     1 |$|
     2 |#[t][h][r][e][e][ ][f][o][u][r]|
    top 0 cursor 5
    |}];
  (* [v] switches kind, [o] swaps ends, [V] twice ends Visual. *)
  let t = type_ t "vo" in
  print_s [%sexp (Text_view.selection t : (int * int) option), (Text_view.cursor t : int)];
  [%expect {| (((4 6)) 4) |}];
  let t = type_ t "VV" in
  print_s [%sexp (Text_view.visual t : Text_view.Kind.t option)];
  [%expect {| () |}];
  let t = type_ t "kVjy" in
  [%expect {|
    ("Copied 2 lines" (clipboard  "one\
                                 \n\
                                 \n"))
    |}];
  (* The last line has no break; a linewise copy still ends with one. *)
  let t = type_ t "GVy" in
  [%expect
    {| ("Copied 1 line" (clipboard "three four\n")) |}];
  let (_ : Text_view.t) = type_ t "kYyy" in
  [%expect
    {|
    ("Copied 1 line" (clipboard "\n"))
    ("Copied 1 line" (clipboard "\n"))
    |}]
;;

let%expect_test "edits are rejected; Escape ends Visual first" =
  let t = create "text" in
  let t = type_ t "xdpiu<C-r>" in
  [%expect
    {|
    notice: read-only; edits unavailable
    notice: read-only; edits unavailable
    notice: read-only; edits unavailable
    notice: read-only; edits unavailable
    notice: read-only; edits unavailable
    notice: read-only; edits unavailable
    |}];
  print_s [%sexp (Text_view.escape t : Text_view.Action.t option)];
  let t = type_ t "v" in
  print_s [%sexp (Text_view.escape t : Text_view.Action.t option)];
  (* In Visual, [o] swaps rather than being rejected. *)
  let (_ : Text_view.t) = type_ t "lod" in
  [%expect
    {|
    ()
    (Exit_visual)
    notice: read-only; edits unavailable
    |}];
  print_s
    [%sexp
      (List.map [ "yy"; "Y"; "y"; "x"; "j" ] ~f:(fun s -> Text_view.interpret_item (keys s))
       : [ `Copy | `Edit ] Content_key.t list)];
  [%expect {| ((Action Copy) (Action Copy) Prefix (Action Edit) Unbound) |}]
;;

let%expect_test "an updated snapshot never retargets a selection silently" =
  let t = create "first line\nsecond line" |> fun t -> type_ t "jwvl" in
  print_s [%sexp (Text_view.selection t : (int * int) option)];
  [%expect {| ((18 20)) |}];
  let same, result = Text_view.update t "first line\nsecond line" in
  print_s [%sexp (result : [ `Same | `Changed of bool ]), (Text_view.selection same : (int * int) option)];
  [%expect {| (Same ((18 20))) |}];
  (* Changed text ends Visual and keeps the line and display column. *)
  let t, result = Text_view.update t "first line\nsecond row, longer" in
  print_s
    [%sexp
      (result : [ `Same | `Changed of bool ])
    , (Text_view.selection t : (int * int) option)
    , (Text_view.cursor t : int)];
  [%expect {| ((Changed true) () 19) |}];
  (* A line that no longer exists clamps to the last; nothing was selected. *)
  let t, result = Text_view.update t "only" in
  print_s [%sexp (result : [ `Same | `Changed of bool ]), (Text_view.cursor t : int)];
  [%expect {| ((Changed false) 3) |}]
;;
