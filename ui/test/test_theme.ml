open! Core
open Bonsai_term
open Ches_ui

let same_attrs a b = Attr.equal (Attr.many a) (Attr.many b)

let default_color role =
  let r, g, b = Ches_theme.Theme.color Ches_theme.Theme.default role in
  Attr.Color.rgb ~r ~g ~b

let%test_unit "terminal colors preserve all indexed entries and exact RGB" =
  let module M = Ches_terminal.Model in
  let samples =
    List.init 256 ~f:(fun n -> M.Indexed n, Attr.Color.xterm_256 n)
    @ [ M.Rgb (0, 127, 255), Attr.Color.rgb ~r:0 ~g:127 ~b:255
      ; M.Rgb (231, 19, 88), Attr.Color.rgb ~r:231 ~g:19 ~b:88 ] in
  List.iter samples ~f:(fun (color, expected) ->
    let style : M.style =
      { fg = color; bg = color; bold = false; italic = false
      ; underline = false; reverse = false } in
    assert (same_attrs (Theme.attrs (Ches_screen.Style.Terminal style))
      [ Attr.fg expected; Attr.bg expected ]))
;;

let%test_unit "terminal defaults follow theme; reverse and SGR survive custom editor fonts" =
  let module M = Ches_terminal.Model in
  List.iter Ches_theme.Theme.all ~f:(fun theme ->
    let color role =
      let r, g, b = Ches_theme.Theme.color theme role in Attr.Color.rgb ~r ~g ~b in
    List.iter [ false; true ] ~f:(fun bold ->
      List.iter [ false; true ] ~f:(fun italic ->
        List.iter [ false; true ] ~f:(fun underline ->
          List.iter [ false; true ] ~f:(fun reverse ->
            let style : M.style =
              { fg = Default; bg = Default; bold; italic; underline; reverse } in
            let expected =
              [ Attr.fg (color Foreground); Attr.bg (color Background) ]
              @ (if reverse then [ Attr.invert ] else [])
              @ (if bold then [ Attr.bold ] else [])
              @ (if italic then [ Attr.italic ] else [])
              @ (if underline then [ Attr.underline ] else []) in
            List.iter [ Theme.Font.default; (fun _ -> []); (fun _ -> [ Bold; Italic; Underline ]) ]
              ~f:(fun font ->
                assert (same_attrs
                  (Theme.attrs ~theme ~font (Ches_screen.Style.Terminal style)) expected)))))))
;;

let%test_unit "terminal foreground and background remain independent under reverse" =
  let module M = Ches_terminal.Model in
  List.iter Ches_theme.Theme.all ~f:(fun theme ->
    let role role =
      let r, g, b = Ches_theme.Theme.color theme role in Attr.Color.rgb ~r ~g ~b in
    let fg_cases =
      [ M.Default, role Foreground
      ; Indexed 17, Attr.Color.xterm_256 17
      ; Rgb (12, 34, 56), Attr.Color.rgb ~r:12 ~g:34 ~b:56 ] in
    let bg_cases =
      [ M.Default, role Background
      ; Indexed 231, Attr.Color.xterm_256 231
      ; Rgb (210, 98, 76), Attr.Color.rgb ~r:210 ~g:98 ~b:76 ] in
    List.iter fg_cases ~f:(fun (fg, foreground) ->
      List.iter bg_cases ~f:(fun (bg, background) ->
        List.iter [ false; true ] ~f:(fun reverse ->
          let style : M.style =
            { fg; bg; bold = false; italic = false; underline = false; reverse } in
          let font _ = failwith "terminal style reached editor-only font callback" in
          assert (same_attrs (Theme.attrs ~theme ~font (Ches_screen.Style.Terminal style))
            ([ Attr.fg foreground; Attr.bg background ]
             @ if reverse then [ Attr.invert ] else []))))))
;;

let%test_unit "explicit palettes map syntax, overlays and diffs through semantic roles" =
  let module Palette = Ches_theme.Theme in
  List.iter Palette.all ~f:(fun theme ->
    let color role =
      let r, g, b = Palette.color theme role in
      Attr.Color.rgb ~r ~g ~b
    in
    let check style fg bg =
      assert (same_attrs (Theme.attrs ~theme ~font:(fun _ -> []) style)
        [ Attr.fg (color fg); Attr.bg (color bg) ])
    in
    let open Ches_screen in
    List.iter Style.Syntax.all ~f:(fun syntax ->
      List.iter [ false; true ] ~f:(fun current_line ->
        List.iter [ false; true ] ~f:(fun special ->
          let document ?overlay () = Style.document ~syntax ~current_line ~special ?overlay () in
          check (document ())
            (if special then Special else Theme.syntax_role syntax)
            (if current_line then Current_line else Background);
          List.iter
            [ Style.Overlay.Selection, Palette.Role.Selection_foreground, Palette.Role.Selection_background
            ; Search_match, Search_foreground, Search_background
            ; Search_current, Search_current_foreground, Search_current_background
            ; Insert_cursor, Background, Block_cursor
            ; Insert_point, Background, Block_copy ]
            ~f:(fun (overlay, fg, bg) -> check (document ~overlay ()) fg bg))));
    check Diff_added Diff_added Surface;
    check Diff_removed Diff_removed Surface;
    check Diff_hunk Diff_hunk Surface;
    check Border Border Backdrop;
    check Status Foreground Surface;
    assert (same_attrs (Theme.attrs ~theme Title)
      [ Attr.fg (color Foreground); Attr.bg (color Backdrop); Attr.bold ]));
  (* Interleaved calls must never change the implicit default. *)
  let before = Theme.attrs (Ches_screen.Style.document ()) in
  List.iter Palette.all ~f:(fun theme ->
    ignore (Theme.attrs ~theme (Ches_screen.Style.document ()) : Attr.t list));
  assert (same_attrs before (Theme.attrs (Ches_screen.Style.document ())))
;;

let%test_unit "syntax foreground yields to specials and every interaction overlay" =
  let open Ches_screen in
  List.iter Style.Syntax.all ~f:(fun syntax ->
    List.iter [ false; true ] ~f:(fun current_line ->
      List.iter [ false; true ] ~f:(fun special ->
        List.iter (None :: List.map Style.Overlay.all ~f:Option.some) ~f:(fun overlay ->
          let attrs = Theme.attrs (Style.document ~syntax ~current_line ~special ?overlay ()) in
          (match overlay, special with
           | None, false ->
             assert (same_attrs attrs
               [ Attr.fg (default_color (Theme.syntax_role syntax))
               ; Attr.bg (default_color (if current_line then Current_line else Background))
               ])
           | _ ->
             assert (same_attrs attrs
               (Theme.attrs (Style.document ~current_line ~special ?overlay ()))))))))
;;

let%test_unit "palette distinguishes each major syntax family without adding fonts" =
  let open Ches_screen in
  List.iter
    [ Style.Syntax.Keyword; String; Number; Comment; Type; Function; Module; Constant ]
    ~f:(fun syntax ->
      let style = Style.document ~syntax () in
      assert (not (same_attrs (Theme.attrs style) (Theme.attrs (Style.document ()))));
      assert (List.is_empty (Theme.Font.default style)))
;;

let%test_unit "every preset gives each syntax family its own color, apart from text" =
  let syntax : Theme.Role.t list =
    [ Syntax_keyword
    ; Syntax_string
    ; Syntax_number
    ; Syntax_comment
    ; Syntax_type
    ; Syntax_function
    ; Syntax_module
    ; Syntax_constant
    ]
  in
  List.iter Theme.Preset.all ~f:(fun preset ->
    let fg role = Attr.fg (Theme.Role.color ~preset role) in
    let roles : Theme.Role.t list = Foreground :: syntax in
    List.iteri roles ~f:(fun i a ->
      List.iteri roles ~f:(fun j b ->
        if i < j && Attr.equal (fg a) (fg b)
        then
          raise_s
            [%message
              "colors collide"
                (preset : Theme.Preset.t)
                (a : Theme.Role.t)
                (b : Theme.Role.t)])))
;;

let%test_unit "Crimson composed plain document styles retain the previous terminal attributes" =
  let theme = Option.value_exn (Ches_theme.Theme.find "crimson") in
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
             (Theme.attrs ~theme style)
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

let%expect_test "Crimson frame cells sit on the backdrop; tile interiors keep their ground" =
  let theme = Option.value_exn (Ches_theme.Theme.find "crimson") in
  let bg role = Attr.bg (Theme.Role.color role) in
  let on role style =
    List.exists (Theme.attrs ~theme ~font:(fun _ -> []) style) ~f:(Attr.equal (bg role))
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
