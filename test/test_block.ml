open! Core
open Ches_core

let of_string_exn s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;

(* The block with corners at zero-based (line, code-point column) positions, then each
   row (last line first) as its selected bytes and the cells cut off at either edge. *)
let show ?(to_line_end = false) s ~anchor:(anchor_line, anchor_col) ~active:(active_line, active_col) =
  let text = of_string_exn s in
  let at line col = Text_buffer.offset_of_column text ~line col in
  let block =
    Block.of_corners
      text
      ~cell_width:Cell_width.f
      ~anchor:(at anchor_line anchor_col)
      ~active:(at active_line active_col)
      ~to_line_end
  in
  print_s [%sexp (block : Block.t)];
  List.iter (Block.rows text ~cell_width:Cell_width.f block) ~f:(fun row ->
    printf
      "%d: %S%s%s\n"
      row.line
      (Text_buffer.slice text ~pos:row.start ~len:(row.stop - row.start))
      (if row.before > 0 then sprintf " before=%d" row.before else "")
      (if row.after > 0 then sprintf " after=%d" row.after else ""))
;;

let%expect_test "every arrangement of two corners gives the same block" =
  let s = "abcdefgh\nabcdefgh\nabcdefgh" in
  List.iter
    [ (0, 2), (2, 5); (2, 5), (0, 2); (0, 5), (2, 2); (2, 2), (0, 5) ]
    ~f:(fun (anchor, active) -> show s ~anchor ~active);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 2) (right (6)))
    2: "cdef"
    1: "cdef"
    0: "cdef"
    ((first_line 0) (last_line 2) (left 2) (right (6)))
    2: "cdef"
    1: "cdef"
    0: "cdef"
    ((first_line 0) (last_line 2) (left 2) (right (6)))
    2: "cdef"
    1: "cdef"
    0: "cdef"
    ((first_line 0) (last_line 2) (left 2) (right (6)))
    2: "cdef"
    1: "cdef"
    0: "cdef"
    |}];
  (* One line, one column. *)
  show s ~anchor:(1, 3) ~active:(1, 3);
  [%expect
    {|
    ((first_line 1) (last_line 1) (left 3) (right (4)))
    1: "d"
    |}]
;;

let%expect_test "short and empty lines have an empty range at their end" =
  show "abcdefgh\nab\nabcdefgh" ~anchor:(0, 3) ~active:(2, 5);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 3) (right (6)))
    2: "def"
    1: ""
    0: "def"
    |}];
  (* A line ending inside the block: only its remaining characters. *)
  show "abcdefgh\nabcd\nabcdefgh" ~anchor:(0, 2) ~active:(2, 5);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 2) (right (6)))
    2: "cdef"
    1: "cd"
    0: "cdef"
    |}];
  (* A corner on an empty line, or on a line break (Visual mode), is one cell. *)
  show "abcdefgh\n\nabcdefgh" ~anchor:(0, 5) ~active:(1, 0);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 0) (right (6)))
    1: ""
    0: "abcdef"
    |}];
  show "abcdefgh\nab\nabcdefgh" ~anchor:(0, 5) ~active:(1, 2);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 2) (right (6)))
    1: ""
    0: "cdef"
    |}]
;;

let%expect_test "after $ the block reaches every line's end" =
  show ~to_line_end:true "abcdefgh\nab\nabcd\n\nx" ~anchor:(0, 1) ~active:(4, 0);
  [%expect
    {|
    ((first_line 0) (last_line 4) (left 0) (right ()))
    4: "x"
    3: ""
    2: "abcd"
    1: "ab"
    0: "abcdefgh"
    |}];
  show ~to_line_end:true "abcdefgh\nab\nabcd" ~anchor:(0, 1) ~active:(2, 3);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 1) (right ()))
    2: "bcd"
    1: "b"
    0: "bcdefgh"
    |}]
;;

let%expect_test "a corner on a TAB covers the TAB; other edges may cut one" =
  (* Anchor on a leading TAB, cursor below at column 7: block 0-7. *)
  show "\tab\n0123456789ab" ~anchor:(0, 0) ~active:(1, 7);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 0) (right (8)))
    1: "01234567"
    0: "\t"
    |}];
  (* Blocks 2-4 and 6-9 over a TAB at 0-7. *)
  show "0123456789ab\n\tabc\n0123456789ab" ~anchor:(0, 2) ~active:(2, 4);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 2) (right (5)))
    2: "234"
    1: "\t" before=2 after=3
    0: "234"
    |}];
  show "0123456789ab\n\tabc\n0123456789ab" ~anchor:(0, 6) ~active:(2, 9);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 6) (right (10)))
    2: "6789"
    1: "\tab" before=6
    0: "6789"
    |}];
  (* A block starting at column 8 leaves the TAB out. *)
  show "0123456789ab\n\tabc\n0123456789ab" ~anchor:(0, 8) ~active:(2, 8);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 8) (right (9)))
    2: "8"
    1: "a"
    0: "8"
    |}]
;;

let%expect_test "wide glyphs cut by an edge, and zero-width marks" =
  show "abcdef\na界bcd\nabcdef" ~anchor:(0, 2) ~active:(2, 3);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 2) (right (4)))
    2: "cd"
    1: "\231\149\140b" before=1
    0: "cd"
    |}];
  show "abcdef\na界bcd\nabcdef" ~anchor:(0, 0) ~active:(2, 1);
  [%expect
    {|
    ((first_line 0) (last_line 2) (left 0) (right (2)))
    2: "ab"
    1: "a\231\149\140" after=1
    0: "ab"
    |}];
  (* A corner on the wide glyph covers both its cells. *)
  show "abcdef\na界bcd" ~anchor:(1, 1) ~active:(0, 1);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 1) (right (3)))
    1: "\231\149\140"
    0: "bc"
    |}];
  (* Combining marks stay with their base character, on either side of an edge. *)
  show "abcdef\nae\204\129be\204\129d" ~anchor:(0, 1) ~active:(1, 4);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 1) (right (4)))
    1: "e\204\129be\204\129"
    0: "bcd"
    |}];
  show "abcdef\nae\204\129bcd" ~anchor:(0, 2) ~active:(1, 4);
  [%expect
    {|
    ((first_line 0) (last_line 1) (left 2) (right (4)))
    1: "bc"
    0: "cd"
    |}]
;;

let%test_unit "rows tile each line's selected cells at code-point boundaries" =
  let gen_line =
    Quickcheck.Generator.(
      list (of_list [ "a"; "日"; "\t"; "e\204\129"; " " ]) |> map ~f:String.concat)
  in
  let gen_text = Quickcheck.Generator.(list_non_empty gen_line |> map ~f:(String.concat ~sep:"\n")) in
  Quickcheck.test
    Quickcheck.Generator.(tuple4 gen_text small_non_negative_int small_non_negative_int bool)
    ~sexp_of:[%sexp_of: string * int * int * bool]
    ~f:(fun (s, a, b, to_line_end) ->
      let text = of_string_exn s in
      let offset n =
        let rec loop at n = if n = 0 then at else match Text_buffer.next_boundary text at with None -> at | Some at -> loop at (n - 1) in
        loop 0 n
      in
      let block =
        Block.of_corners text ~cell_width:Cell_width.f ~anchor:(offset a) ~active:(offset b) ~to_line_end
      in
      let rows = Block.rows text ~cell_width:Cell_width.f block in
      [%test_result: int list]
        (List.map rows ~f:(fun row -> row.line))
        ~expect:(List.rev (List.range block.first_line (block.last_line + 1)));
      List.iter rows ~f:(fun row ->
        let line_start = Text_buffer.line_start text row.line in
        let line_end = Text_buffer.line_end text row.line in
        assert (line_start <= row.start && row.start <= row.stop && row.stop <= line_end);
        assert (Text_buffer.is_boundary text row.start && Text_buffer.is_boundary text row.stop);
        let glyphs = Cell_layout.glyphs ~width:Cell_width.f (Text_buffer.line_text text row.line) in
        let left, stop = Block.columns block glyphs in
        let cells =
          Array.sum (module Int) glyphs ~f:(fun g ->
            let pos = line_start + g.pos in
            if pos >= row.start && pos < row.stop then g.width else 0)
        in
        (* The selected glyphs cover exactly the block's cells within the line, plus
           whatever they stick out by. *)
        let within = Int.max 0 (Int.min stop (Cell_layout.total_width glyphs) - left) in
        [%test_result: int] (cells - row.before - row.after) ~expect:within))
;;

let%expect_test "contents: register rows and width" =
  let contents ?(to_line_end = false) s ~anchor:(anchor_line, anchor_col) ~active:(active_line, active_col) =
    let text = of_string_exn s in
    let at line col = Text_buffer.offset_of_column text ~line col in
    let block =
      Block.of_corners
        text
        ~cell_width:Cell_width.f
        ~anchor:(at anchor_line anchor_col)
        ~active:(at active_line active_col)
        ~to_line_end
    in
    print_s [%sexp (Block.contents text ~cell_width:Cell_width.f block : string list * int)]
  in
  (* Too short for the block: spaces; ending at its first column: empty; inside it:
     unpadded. *)
  contents "abcdefgh\nab\nabc\nabcd" ~anchor:(0, 3) ~active:(3, 5);
  contents ~to_line_end:true "abcdefgh\n\nabcd" ~anchor:(0, 2) ~active:(2, 2);
  [%expect {|
    ((de "  " "" d) 2)
    ((cdefgh "      " cd) 6)
    |}];
  (* Cut TABs and wide glyphs give spaces for their cells inside the block; a whole
     TAB stays a TAB. *)
  contents "0123456789ab\n\tabc" ~anchor:(0, 2) ~active:(1, 0);
  contents "0123456789ab\n\tabc" ~anchor:(0, 6) ~active:(1, 2);
  contents "0123456789ab\n\tabc" ~anchor:(0, 3) ~active:(1, 1);
  contents "abcdef\na界bcd" ~anchor:(0, 2) ~active:(1, 3);
  contents "x\u{0301}y\n界\u{0301}z" ~anchor:(0, 0) ~active:(1, 0);
  [%expect {|
    ((01234567 "\t") 8)
    ((6789 "  ab") 4)
    ((345678 "     a") 6)
    ((cde " bc") 3)
    (("x\204\129y" "\231\149\140\204\129") 2)
    |}]
;;

let%expect_test "insertion at a display column" =
  let insertion s ~line ~col =
    let text = of_string_exn s in
    print_s
      [%sexp (Block.insertion text ~cell_width:Cell_width.f ~line ~col : Block.Insertion.t)]
  in
  (* Inside a line, at its end, and past it. *)
  insertion "abc" ~line:0 ~col:1;
  insertion "abc" ~line:0 ~col:3;
  insertion "x\nabc" ~line:1 ~col:5;
  [%expect {|
    ((pos 1) (remove 0) (pad_before 0) (pad_after 0) (at_end false))
    ((pos 3) (remove 0) (pad_before 0) (pad_after 0) (at_end true))
    ((pos 5) (remove 0) (pad_before 2) (pad_after 0) (at_end true))
    |}];
  (* A TAB is split; a wide glyph is not; a TAB's own edges need no split. *)
  insertion "\tabc" ~line:0 ~col:4;
  insertion "\tabc" ~line:0 ~col:8;
  insertion "a界b" ~line:0 ~col:2;
  [%expect {|
    ((pos 0) (remove 1) (pad_before 4) (pad_after 4) (at_end false))
    ((pos 1) (remove 0) (pad_before 0) (pad_after 0) (at_end false))
    ((pos 1) (remove 0) (pad_before 1) (pad_after 0) (at_end false))
    |}];
  (* After the zero-width marks on the code point before the column. *)
  insertion "e\u{0301}x" ~line:0 ~col:1;
  [%expect {| ((pos 3) (remove 0) (pad_before 0) (pad_after 0) (at_end false)) |}]
;;
