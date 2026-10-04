open! Core
open Bonsai_term
open Ches_ui

let same_attrs a b = Attr.equal (Attr.many a) (Attr.many b)

let%expect_test "the default fonts bold the title, badge, markers, and errors only" =
  List.iter
    [ Ches_screen.Style.Text
    ; Title
    ; Mode Normal
    ; Mode (Visual `Blockwise)
    ; Dirty
    ; Pending
    ; Warning
    ; Error
    ; Smear
    ]
    ~f:(fun style ->
      print_s [%sexp (style : Ches_screen.Style.t), (Theme.Font.default style : Theme.Font.t list)]);
  [%expect
    {|
    (Text ())
    (Title (Bold))
    ((Mode Normal) (Bold))
    ((Mode (Visual Blockwise)) (Bold))
    (Dirty (Bold))
    (Pending (Bold))
    (Warning ())
    (Error (Bold))
    (Smear ())
    |}]
;;

let%expect_test "a font function replaces the default fonts and keeps the colors" =
  let font : Ches_screen.Style.t -> Theme.Font.t list = function
    | Special | Special_cursor_line -> [ Italic ]
    | Search_match_current -> [ Bold; Underline ]
    | _ -> []
  in
  let plain = Theme.attrs ~font:(fun _ -> []) in
  print_s
    [%sexp
      { special_italic =
          (same_attrs (Theme.attrs ~font Special) (plain Special @ [ Attr.italic ]) : bool)
      ; match_bold_underlined =
          (same_attrs
             (Theme.attrs ~font Search_match_current)
             (plain Search_match_current @ [ Attr.bold; Attr.underline ])
           : bool)
      ; title_no_longer_bold = (same_attrs (Theme.attrs ~font Title) (plain Title) : bool)
      ; default_title_bold =
          (same_attrs (Theme.attrs Title) (plain Title @ [ Attr.bold ]) : bool)
      }];
  [%expect
    {|
    ((special_italic true) (match_bold_underlined true)
     (title_no_longer_bold true) (default_title_bold true))
    |}]
;;
