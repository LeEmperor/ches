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

let%expect_test "frame cells sit on the backdrop; tile interiors keep their ground" =
  let bg role = Attr.bg (Theme.Role.color role) in
  let on role style =
    List.exists (Theme.attrs ~font:(fun _ -> []) style) ~f:(Attr.equal (bg role))
  in
  List.iter
    [ Ches_screen.Style.Border
    ; Border_focused
    ; Title
    ; Title_special
    ; Hint
    ; Ches_screen.Style.document ()
    ; Gutter
    ; Status
    ]
    ~f:(fun style ->
      printf "%s backdrop=%b\n" (Ches_screen.Style.to_string_hum style) (on Backdrop style));
  [%expect {|
    Border backdrop=true
    Border_focused backdrop=true
    Title backdrop=true
    Title_special backdrop=true
    Hint backdrop=true
    Text backdrop=false
    Gutter backdrop=false
    Status backdrop=false
    |}]
;;
