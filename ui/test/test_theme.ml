open! Core
open Bonsai_term
open Ches_ui

let same_attrs a b = Attr.equal (Attr.many a) (Attr.many b)

let%expect_test "the default fonts bold the title, badge, markers, and errors only" =
  List.iter
    [ Ches_screen.Style.document ()
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
       printf "%s %s\n" (Ches_screen.Style.to_string_hum style)
         (Sexp.to_string ([%sexp (Theme.Font.default style : Theme.Font.t list)])));
  [%expect
    {|
    Text ()
    Title (Bold)
    (Mode Normal) (Bold)
    (Mode (Visual Blockwise)) (Bold)
    Dirty (Bold)
    Pending (Bold)
    Warning ()
    Error (Bold)
    Smear ()
    |}]
;;

let%expect_test "a font function replaces the default fonts and keeps the colors" =
  let font : Ches_screen.Style.t -> Theme.Font.t list = function
    | Document { overlay = Some Search_current; _ } -> [ Bold; Underline ]
    | Document { special = true; _ } -> [ Italic ]
    | _ -> []
  in
  let plain = Theme.attrs ~font:(fun _ -> []) in
  let special = Ches_screen.Style.document ~special:true () in
  let current = Ches_screen.Style.document ~overlay:Search_current () in
  print_s
    [%sexp
      { special_italic =
           (same_attrs (Theme.attrs ~font special) (plain special @ [ Attr.italic ]) : bool)
      ; match_bold_underlined =
          (same_attrs
              (Theme.attrs ~font current)
              (plain current @ [ Attr.bold; Attr.underline ])
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

let%expect_test "open chrome moves frame cells onto the backdrop, nothing else" =
  let differs style =
    not (same_attrs (Theme.attrs style) (Theme.attrs ~chrome:Open style))
  in
  List.iter
    [ Ches_screen.Style.Border
    ; Border_focused
    ; Title
    ; Title_special
    ; Hint
    ; Separator
    ; Backdrop
    ; Ches_screen.Style.document ()
    ; Status
    ; Gutter
    ]
    ~f:(fun style ->
      printf "%s %b\n" (Ches_screen.Style.to_string_hum style) (differs style));
  print_s
    [%sexp
      (same_attrs
         (Theme.attrs ~chrome:Open Border)
         [ Attr.fg (Theme.Role.color Border); Attr.bg (Theme.Role.color Backdrop) ]
       : bool)];
  [%expect {|
    Border true
    Border_focused true
    Title true
    Title_special true
    Hint true
    Separator false
    Backdrop false
    Text false
    Status false
    Gutter false
    true
    |}]
;;
