open! Core
open Ches_theme

let channels (r, g, b) = [ r; g; b ]

let%test_unit "registry is total, valid, distinct, and normalized" =
  assert (List.length Theme.all = 44);
  assert (String.equal (Theme.id Theme.default) "crimson");
  assert (not (List.contains_dup (List.map Theme.all ~f:Theme.id) ~compare:String.compare));
  List.iter Theme.all ~f:(fun theme ->
    assert (not (String.is_empty (Theme.title theme)));
    assert (Option.equal Theme.equal (Theme.find (String.uppercase (Theme.id theme))) (Some theme));
    List.iter Theme.Role.all ~f:(fun role ->
      List.iter (channels (Theme.color theme role)) ~f:(fun n -> assert (n >= 0 && n <= 255))));
  assert (Option.equal Theme.equal (Theme.find "  Mint_Paper  ") (Theme.find "mint-paper"));
  assert (Option.is_none (Theme.find "unknown"));
  (* Distinct palettes need not have distinct colors for every semantic role. *)
  let palettes = List.map Theme.all ~f:(fun t ->
    List.concat_map Theme.Role.all ~f:(fun role -> channels (Theme.color t role))) in
  assert (not (List.contains_dup palettes ~compare:(List.compare Int.compare)))
;;

let%test_unit "light, dark, and intentional neutral monochrome palettes" =
  let brightness rgb = List.sum (module Int) (channels rgb) ~f:Fn.id in
  List.iter Theme.all ~f:(fun theme ->
    let bg = brightness (Theme.color theme Background) in
    let fg = brightness (Theme.color theme Foreground) in
    match Theme.kind theme with
    | Dark -> assert (bg < fg)
    | Light -> assert (bg > fg));
  List.iter [ "graphite"; "newsprint"; "silver-night"; "ivory-ink" ] ~f:(fun id ->
    let theme = Option.value_exn (Theme.find id) in
    List.iter Theme.Role.all ~f:(fun role ->
      let r, g, b = Theme.color theme role in
      assert (r = g && g = b)))
;;

let%test_unit "Vim black canvas and Solarized variants retain their identities" =
  List.iter
    [ "vim-classic", "Vim Classic", Theme.Kind.Dark
    ; "solarized-light", "Solarized Light", Light
    ; "linen-solar", "Linen Solar", Light
    ; "sandstone-solar", "Sandstone Solar", Light ]
    ~f:(fun (id, title, kind) ->
      let theme = Option.value_exn (Theme.find id) in
      assert (String.equal (Theme.title theme) title);
      assert (Theme.Kind.equal (Theme.kind theme) kind));
  assert (List.count Theme.all ~f:(fun t -> Theme.Kind.equal (Theme.kind t) Dark) = 29);
  assert (List.count Theme.all ~f:(fun t -> Theme.Kind.equal (Theme.kind t) Light) = 15);
  let vim = Option.value_exn (Theme.find "vim-classic") in
  List.iter [ Theme.Role.Background; Backdrop; Current_line ] ~f:(fun role ->
    assert (Poly.equal (Theme.color vim role) (0, 0, 0)));
  List.iter [ "solarized-light"; "linen-solar"; "sandstone-solar" ] ~f:(fun id ->
    let theme = Option.value_exn (Theme.find id) in
    List.iter
      [ Theme.Role.Selection_foreground, Theme.Role.Selection_background
      ; Search_foreground, Search_background
      ; Search_current_foreground, Search_current_background ]
      ~f:(fun (fg, bg) -> assert (not (Poly.equal (Theme.color theme fg) (Theme.color theme bg)))))
;;

let%test_unit "original Linen and Sandstone palettes remain unchanged" =
  List.iter
    [ "linen", "Linen",
      [0xf7efdf;0xebe0cb;0xd3c3a8;0x92836c;0x6e604e;0x40392f;0x30291f;0x211c14;0xa8463c;0xa4672c;0x877020;0x58743a;0x387b70;0x476d93;0x825c91;0x8d6541]
    ; "sandstone", "Sandstone",
      [0xf3e8d2;0xe5d7ba;0xcbb994;0x97815b;0x735f3f;0x493b27;0x372b1a;0x271e10;0xa83d32;0xa66120;0x826816;0x597136;0x37756a;0x42658b;0x7a548a;0x8b5a32] ]
    ~f:(fun (id, title, values) ->
      let palette = Array.of_list_map values ~f:(fun n ->
        (n lsr 16) land 255, (n lsr 8) land 255, n land 255) in
      let expected = Theme.of_base16 ~id ~title ~kind:Light ~palette in
      assert (Theme.equal (Option.value_exn (Theme.find id)) expected))
;;

let%test_unit "Base16 validates input and snapshots mutable source arrays" =
  let make palette = Theme.of_base16 ~id:"test" ~title:"Test" ~kind:Dark ~palette in
  let invalid palette =
    assert (try ignore (make palette : Theme.t); false with Invalid_argument _ -> true)
  in
  invalid [||];
  invalid (Array.create ~len:15 (0, 0, 0));
  invalid (Array.create ~len:17 (0, 0, 0));
  List.iter [ (-1, 0, 0); (0, 256, 0); (0, 0, -1) ] ~f:(fun rgb ->
    invalid (Array.create ~len:16 rgb));
  let palette = Array.init 16 ~f:(fun i -> i, i + 1, i + 2) in
  let theme = make palette in
  assert (Poly.equal (Theme.color theme Background) (0, 1, 2));
  assert (Poly.equal (Theme.color theme Foreground) (5, 6, 7));
  assert (Poly.equal (Theme.color theme Syntax_keyword) (14, 15, 16));
  assert (Poly.equal (Theme.color theme Diff_added) (11, 12, 13));
  Array.fill palette ~pos:0 ~len:16 (255, 255, 255);
  assert (Poly.equal (Theme.color theme Background) (0, 1, 2));
  List.iter [ ""; "Bad ID"; "UPPER" ] ~f:(fun id ->
    assert (try
      ignore (Theme.of_base16 ~id ~title:"Test" ~kind:Dark ~palette : Theme.t);
      false
    with Invalid_argument _ -> true))
;;

let%test_unit "legacy overlay and diff aliases preserve original meaning" =
  let aliases : (Theme.Role.t * Theme.Role.t) list =
    [ Selection_foreground, Background; Selection_background, Warning
    ; Search_foreground, Background; Search_background, Normal_accent
    ; Search_current_foreground, Background; Search_current_background, Insert_accent
    ; Diff_added, Insert_accent; Diff_removed, Error; Diff_hunk, Special ]
  in
  List.iter [ "midnight"; "crimson"; "ember"; "glacier" ] ~f:(fun id ->
    let t = Option.value_exn (Theme.find id) in
    List.iter aliases ~f:(fun (a, b) -> assert (Poly.equal (Theme.color t a) (Theme.color t b))))
;;

let%test_unit "all 23 original role colors remain byte-for-byte compatible" =
  let roles : Theme.Role.t list =
    [ Backdrop; Background; Foreground; Surface; Muted; Border; Current_line
    ; Normal_accent; Insert_accent; Special; Warning; Error; Block_cursor; Block_copy
    ; Smear; Syntax_keyword; Syntax_string; Syntax_number; Syntax_comment; Syntax_type
    ; Syntax_function; Syntax_module; Syntax_constant ]
  in
  (* Snapshots of the original UI mapper, before extraction into the library. *)
  let snapshots =
    [ "midnight", [0x0b0b0c;0x111113;0xd0d0d0;0x1c1c1f;0x5a5a60;0x3a3a40;0x1d1d21;0x7aa2f7;0x9ece6a;0xbb9af7;0xe0af68;0xf7768e;0x7aa2f7;0xd0d0d0;0xf5f5f5;0xbb9af7;0x9ece6a;0xff9e64;0x7a8994;0x7dcfff;0x7aa2f7;0x73daca;0xe0af68]
    ; "crimson", [0x0c0a0a;0x131010;0xe0d2d2;0x201a1b;0x665558;0x443639;0x211a1b;0xe85d75;0x9ece6a;0xc9a0ff;0xffb86c;0xff3355;0xe85d75;0xe0d2d2;0xd11f3c;0xff4f5e;0xf2a07b;0xff9e64;0x8c6f75;0xf76e9e;0xff7b54;0xd98aa0;0xffcb6b]
    ; "ember", [0x141412;0x1d2021;0xebdbb2;0x282828;0x665c54;0x504945;0x282828;0x83a598;0xb8bb26;0xd3869b;0xfabd2f;0xfb4934;0x83a598;0xebdbb2;0xfabd2f;0xfb4934;0xb8bb26;0xd3869b;0x928374;0xfabd2f;0x8ec07c;0x83a598;0xfe8019]
    ; "glacier", [0x090c10;0x0f1419;0xc8d3e0;0x171e26;0x4e5a68;0x2e3a48;0x171e26;0x5cc8ff;0x7fe0c0;0xf08fc0;0xe6c384;0xff6b7f;0x5cc8ff;0xc8d3e0;0xbfe8ff;0x82aaff;0xa3e4d7;0xc3a6ff;0x63778a;0x89ddff;0x5cc8ff;0x6bd8c8;0xb4c6ff] ]
  in
  List.iter snapshots ~f:(fun (id, expected) ->
    let theme = Option.value_exn (Theme.find id) in
    List.iter2_exn roles expected ~f:(fun role packed ->
      let r, g, b = Theme.color theme role in
      assert (((r lsl 16) lor (g lsl 8) lor b) = packed)))
;;
