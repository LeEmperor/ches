open! Core
open Bonsai_term
open Ches_ui

let same_attrs a b = Attr.equal (Attr.many a) (Attr.many b)

let%test_unit "every composed plain document style retains the previous terminal attributes" =
  let open Ches_screen in
  List.iter [ false; true ] ~f:(fun current_line ->
    List.iter [ false; true ] ~f:(fun special ->
      List.iter (None :: List.map Style.Overlay.all ~f:Option.some) ~f:(fun overlay ->
        let (fg, bg) : Theme.Role.t * Theme.Role.t =
          match overlay with
          | None ->
            (if special then Special else Foreground),
            (if current_line then Current_line else Background)
          | Some Search_match -> Background, Normal_accent
          | Some Search_current -> Background, Insert_accent
          | Some Selection -> Background, Warning
          | Some Insert_cursor -> Background, Block_cursor
          | Some Insert_point -> Background, Block_copy
        in
        let style = Style.document ~current_line ~special ?overlay () in
        assert
          (same_attrs
             (Theme.attrs style)
             [ Attr.fg (Theme.Role.color fg); Attr.bg (Theme.Role.color bg) ]);
        assert (List.is_empty (Theme.Font.default style)))))
;;

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
      print_s [%sexp (style : Ches_screen.Style.t), (Theme.Font.default style : Theme.Font.t list)]);
  [%expect
    {|
    ((Document
      ((syntax Plain) (current_line false) (special false) (overlay ())))
     ())
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
