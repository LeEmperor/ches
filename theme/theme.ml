open! Core

module Role = struct
  type t =
    | Backdrop | Background | Foreground | Surface | Muted | Border | Current_line
    | Normal_accent | Insert_accent | Special | Warning | Error
    | Block_cursor | Block_copy | Smear
    | Syntax_keyword | Syntax_string | Syntax_number | Syntax_comment
    | Syntax_type | Syntax_function | Syntax_module | Syntax_constant
    | Selection_foreground | Selection_background
    | Search_foreground | Search_background
    | Search_current_foreground | Search_current_background
    | Diff_added | Diff_removed | Diff_hunk
  [@@deriving sexp_of, equal, enumerate]
end

type rgb = int * int * int [@@deriving sexp_of, equal]

module Kind = struct
  type t = Dark | Light [@@deriving sexp_of, equal]
end

type t =
  { id : string
  ; title : string
  ; kind : Kind.t
  ; colors : (Role.t * rgb) list
  }
[@@deriving sexp_of, equal]

let id t = t.id
let title t = t.title
let kind t = t.kind
let color t role = List.Assoc.find_exn t.colors role ~equal:Role.equal

let validate_rgb (r, g, b) =
  if List.exists [ r; g; b ] ~f:(fun c -> c < 0 || c > 255)
  then invalid_arg "Theme: RGB channel outside 0..255"
;;

let of_base16 ~id ~title ~(kind : Kind.t) ~palette =
  if String.is_empty id
     || not (String.for_all id ~f:(fun c ->
       Char.is_lowercase c || Char.is_digit c || Char.equal c '-'))
  then invalid_arg "Theme: expected nonempty lowercase stable ID";
  if Array.length palette <> 16 then invalid_arg "Theme: expected 16 Base16 colors";
  Array.iter palette ~f:validate_rgb;
  let slot : Role.t -> int = function
    | Backdrop | Background | Selection_foreground | Search_foreground
    | Search_current_foreground -> 0
    | Surface | Current_line -> 1
    | Border -> 2
    | Muted | Syntax_comment -> 3
    | Foreground | Block_copy -> 5
    | Smear -> 6
    | Error | Diff_removed -> 8
    | Syntax_number | Syntax_constant -> 9
    | Warning | Selection_background | Syntax_type -> 10
    | Insert_accent | Search_current_background | Syntax_string | Diff_added -> 11
    | Syntax_module -> 12
    | Normal_accent | Block_cursor | Search_background | Syntax_function -> 13
    | Special | Syntax_keyword | Diff_hunk -> 14
  in
  { id; title; kind; colors = List.map Role.all ~f:(fun role -> role, palette.(slot role)) }
;;

let rgb n = (n lsr 16) land 255, (n lsr 8) land 255, n land 255

(* Compact Base16 data. Each row is an original palette: neutral ramp followed
   by eight deliberate accent choices. Light ramps run from paper to ink. *)
let curated =
  [ "abyss", "Abyss", Kind.Dark,
    [0x08121c;0x102232;0x253b4d;0x688499;0x93adbf;0xc5dce8;0xe0edf4;0xf4faff;0xf07888;0xe9a36b;0xe5cc84;0x92cda8;0x76d5d0;0x78b7ee;0xb3a0e5;0xb88e77]
  ; "moss", "Moss", Dark,
    [0x121a14;0x1e2a20;0x354b38;0x789479;0x9eb39a;0xd3dfc7;0xe5eddb;0xf5f8ec;0xd98776;0xd4a16a;0xd8c97d;0x9cbd78;0x77b5a1;0x86aabe;0xb39bbd;0xb39978]
  ; "orchid", "Orchid", Dark,
    [0x201426;0x302039;0x4c3656;0x96799f;0xbca2c4;0xe4cee9;0xf0e0f4;0xfcf3ff;0xf18cae;0xe8ad89;0xe5d08b;0xa9d39b;0x8bd1c8;0xa5b8f2;0xd29cf0;0xc394ad]
  ; "copper", "Copper", Dark,
    [0x211711;0x30231a;0x50392b;0x9b7b62;0xbfa48b;0xe5d3b8;0xf2e4ce;0xfff4e3;0xe48473;0xefad73;0xe4c888;0xb4c08b;0x88beb3;0x92b4cf;0xc5a0c3;0xc19265]
  ; "inkwell", "Inkwell", Dark,
    [0x131627;0x20253a;0x353e58;0x7b87aa;0xa1aecb;0xd1d9ed;0xe6ebf7;0xf8faff;0xf18c9e;0xe6ae88;0xe7d49c;0xa7d0b0;0x86d0d1;0x8caaf1;0xbca3ed;0xba9d9a]
  ; "desert-night", "Desert Night", Dark,
    [0x211d1a;0x302a24;0x4d4337;0x988a74;0xb9ac94;0xe3d8ba;0xf0e7cf;0xfff7e3;0xe08c78;0xe6b17d;0xe8cc8d;0xb7c28c;0x8bc3b5;0x95b7ce;0xc6a0bc;0xbd9474]
  ; "tidepool", "Tidepool", Dark,
    [0x0c2020;0x173132;0x2c4c4a;0x6e9a96;0x9cbdb7;0xcde5d9;0xe2f2e7;0xf4fff6;0xea9087;0xe6b085;0xe0d399;0xa7d2a0;0x73d7c4;0x83badf;0xb4a9dd;0xbc9a7d]
  ; "plum-smoke", "Plum Smoke", Dark,
    [0x211b24;0x302936;0x493e51;0x92839c;0xb5a6bd;0xded2e5;0xeee4f2;0xfcf4ff;0xe594ac;0xdbad91;0xd8cc9e;0xaacaab;0x91c8c8;0x9eb8de;0xc7a6dc;0xbca095]
  ; "signal", "Signal", Dark,
    [0x111518;0x20282d;0x39464e;0x7b929e;0xa4b9c4;0xdbe8ee;0xedf6fa;0xffffff;0xff6978;0xffab62;0xffdc70;0x9ce57d;0x6be3cc;0x6ebaff;0xc09bff;0xc69678]
  ; "deep-olive", "Deep Olive", Dark,
    [0x1a1c12;0x292d1d;0x444a30;0x899267;0xaeb58b;0xdde1ba;0xecf0d0;0xfaffdf;0xdb8d78;0xd6ab72;0xd5cd76;0xa8c777;0x85b9a2;0x94aeca;0xbda0c5;0xb49b6b]
  ; "cobalt-room", "Cobalt Room", Dark,
    [0x101b38;0x192b4c;0x2c466a;0x728fb6;0x9db7d8;0xd0e0f5;0xe4edfb;0xf5f9ff;0xf18a9f;0xf0ad7c;0xeed58a;0x9ed8af;0x7ed8db;0x79b1ff;0xb3a3f4;0xb99c9c]
  ; "rosewood", "Rosewood", Dark,
    [0x251619;0x362126;0x57363f;0xa47b86;0xc29ca5;0xe9cdd0;0xf6e1e0;0xfff1eb;0xf08b92;0xe8ab88;0xe4cb94;0xb5cd9a;0x95c8bc;0xa0b9d6;0xcca4d4;0xc19586]
  ; "volcanic", "Volcanic", Dark,
    [0x181719;0x292529;0x463d44;0x98838e;0xbda3af;0xe4cdd5;0xf1e0e6;0xfff3f4;0xff776b;0xf4a162;0xf2cf78;0xb6d28a;0x8dd2c4;0x9bbce6;0xd1a1e8;0xc28d75]
  ; "aurora-field", "Aurora Field", Dark,
    [0x10211b;0x1b332b;0x314e42;0x739a88;0x9dc3ad;0xcce7d6;0xe0f4e6;0xf2fff4;0xf192ac;0xebae85;0xe6d68e;0x91dfaa;0x74e2d0;0x92bdf4;0xc9a0f0;0xb99e82]
  ; "mulberry", "Mulberry", Dark,
    [0x291422;0x3a2031;0x5b354e;0xa17592;0xc69ab6;0xeacbe0;0xf6dfed;0xfff1f9;0xf18dbb;0xe6aa94;0xe2ce9a;0xb4d39e;0x93d2c6;0xa3bcef;0xd5a0ed;0xc299a5]
  ; "storm-slate", "Storm Slate", Dark,
    [0x1b242c;0x29353f;0x41535e;0x8299a6;0xa6bac4;0xd4e1e5;0xe5eff1;0xf6fcfc;0xe79898;0xe1b28a;0xdccd9c;0xa7c8a4;0x8cc7c6;0x95b7d7;0xb9abce;0xb79f8b]
  ; "saffron-night", "Saffron Night", Dark,
    [0x241e0e;0x352d18;0x554829;0xa18c58;0xc2ad78;0xe8d8a6;0xf5e8bf;0xfff5d9;0xe99171;0xf0b263;0xf1d36f;0xb7ca83;0x90c7b4;0x9eb7d8;0xc7a5d4;0xbd985f]
  ; "electric-violet", "Electric Violet", Dark,
    [0x17112c;0x261b43;0x423160;0x8b77b1;0xb19cd4;0xddcef3;0xeee2ff;0xfcf5ff;0xff87b0;0xffb28b;0xf5d98e;0xb6e09a;0x85e0dc;0x96b7ff;0xce9aff;0xc69aa8]
  ; "paper", "Paper", Light,
    [0xf8f6ef;0xeeeae0;0xd7d2c5;0x827d70;0x615e56;0x343630;0x242720;0x171b15;0xa93845;0xa45d21;0x826c18;0x47733b;0x287b78;0x356a9c;0x7758a0;0x875d42]
  ; "porcelain", "Porcelain", Light,
    [0xf5f9fc;0xe7eff5;0xcbdbe7;0x748b9b;0x526b7b;0x293f50;0x1c3040;0x102130;0xb64058;0xa76228;0x826b1a;0x3b7851;0x187c86;0x2e68a8;0x7953a5;0x8b604a]
  ; "linen", "Linen", Light,
    [0xf7efdf;0xebe0cb;0xd3c3a8;0x92836c;0x6e604e;0x40392f;0x30291f;0x211c14;0xa8463c;0xa4672c;0x877020;0x58743a;0x387b70;0x476d93;0x825c91;0x8d6541]
  ; "mint-paper", "Mint Paper", Light,
    [0xeff8ef;0xdfeee1;0xbfd7c4;0x759780;0x51765d;0x2c4938;0x1c3627;0x10261a;0xb13f55;0xa36530;0x807322;0x347541;0x217f75;0x376aa2;0x79569c;0x8b654c]
  ; "lavender-page", "Lavender Page", Light,
    [0xf8f2fc;0xede2f4;0xd6c6e2;0x9781a6;0x725d82;0x44324f;0x33223f;0x241430;0xb23b62;0xa96135;0x87701f;0x4b784c;0x2a7c82;0x4266a8;0x8051ae;0x92604f]
  ; "peach-page", "Peach Page", Light,
    [0xfff2e9;0xf4e2d5;0xe1c6b4;0xa58670;0x80634f;0x503b2e;0x3c291e;0x2b1b12;0xb13d42;0xae6027;0x89701b;0x58783d;0x2c7d78;0x436c9d;0x8657a0;0x96603e]
  ; "blueprint-day", "Blueprint Day", Light,
    [0xedf4ff;0xdce9fa;0xb9cfea;0x718cb2;0x4b6890;0x263f64;0x172d4e;0x0b1c37;0xb33655;0xa45c29;0x856b15;0x3c744c;0x167986;0x235fae;0x7450a5;0x865c48]
  ; "sandstone", "Sandstone", Light,
    [0xf3e8d2;0xe5d7ba;0xcbb994;0x97815b;0x735f3f;0x493b27;0x372b1a;0x271e10;0xa83d32;0xa66120;0x826816;0x597136;0x37756a;0x42658b;0x7a548a;0x8b5a32]
  ; "sea-glass", "Sea Glass", Light,
    [0xedf9f7;0xdaeeeb;0xb9d7d3;0x719991;0x4c786f;0x284c45;0x19392f;0x0c281f;0xb13f59;0xa26532;0x81721f;0x3d794a;0x167e7c;0x356c9d;0x795b9c;0x8c6549]
  ; "rose-quartz", "Rose Quartz", Light,
    [0xfcf1f4;0xf1dfe6;0xdec0cf;0xa47e93;0x805b71;0x503449;0x3c2335;0x2a1524;0xb33862;0xa75f36;0x857020;0x4e784c;0x2d7c7b;0x4768a0;0x8250a2;0x93604f]
  ; "chalkboard", "Chalkboard", Dark,
    [0x17201d;0x26332d;0x3d5147;0x819b8b;0xacc2b0;0xdfe9d5;0xeef5e4;0xfcffef;0xe99b94;0xe7bc8e;0xe6d79d;0xb6d5a0;0x99d5c9;0xa0bfe2;0xc5b0df;0xbea488]
  ; "terminal-amber", "Terminal Amber", Dark,
    [0x170f00;0x2b1c00;0x4c3305;0x997126;0xc29139;0xe7b958;0xf4ce7a;0xffe4a6;0xf5ad42;0xe8a746;0xffd16a;0xd4a954;0xe6b960;0xf5c56c;0xdbad61;0xc49646]
  ; "terminal-green", "Terminal Green", Dark,
    [0x061307;0x102712;0x214a25;0x4d8b51;0x72b574;0x9fdb98;0xbbedad;0xddffd0;0x9fdb98;0x84c682;0xc0eeae;0xa5df9b;0x8fd58a;0xb0e8a5;0x9bd894;0x79be78]
  ; "graphite", "Graphite", Dark,
    [0x141414;0x242424;0x404040;0x808080;0xababab;0xd4d4d4;0xe8e8e8;0xffffff;0xbdbdbd;0xc8c8c8;0xe0e0e0;0xc4c4c4;0xb8b8b8;0xeeeeee;0xd0d0d0;0xa8a8a8]
  ; "newsprint", "Newsprint", Light,
    [0xf5f5f5;0xe7e7e7;0xcdcdcd;0x858585;0x606060;0x333333;0x222222;0x111111;0x444444;0x505050;0x585858;0x484848;0x5b5b5b;0x292929;0x3d3d3d;0x626262]
  ; "silver-night", "Silver Night", Dark,
    [0x080808;0x181818;0x383838;0x777777;0xaaaaaa;0xe2e2e2;0xf2f2f2;0xffffff;0xd8d8d8;0xbebebe;0xeeeeee;0xcacaca;0xb4b4b4;0xf4f4f4;0xd0d0d0;0xa0a0a0]
  ; "ivory-ink", "Ivory Ink", Light,
    [0xffffff;0xf0f0f0;0xd5d5d5;0x888888;0x555555;0x181818;0x0c0c0c;0x000000;0x303030;0x444444;0x484848;0x383838;0x525252;0x202020;0x282828;0x606060]
  ; "ochre-study", "Ochre Study", Dark,
    [0x201b13;0x312b1d;0x50462e;0x99875a;0xc0ac7c;0xe8d7a9;0xf4e6c3;0xfff6df;0xd7ad73;0xe5b979;0xf1d394;0xc7bb83;0xbcba91;0xe3cb9a;0xd2b58b;0xb99b6b]
  ]
;;

(* Original presets are exact role tables, not approximations through Base16.
   The new roles intentionally reproduce their former overlay/diff colors. *)
let legacy_roles : Role.t list =
  [ Backdrop; Background; Foreground; Surface; Muted; Border; Current_line
  ; Normal_accent; Insert_accent; Special; Warning; Error; Block_cursor; Block_copy
  ; Smear; Syntax_keyword; Syntax_string; Syntax_number; Syntax_comment; Syntax_type
  ; Syntax_function; Syntax_module; Syntax_constant ]
;;

let legacy id title values =
  let colors = List.zip_exn legacy_roles (List.map values ~f:rgb) in
  let get role = List.Assoc.find_exn colors role ~equal:Role.equal in
  let aliases : (Role.t * Role.t) list =
    [ Selection_foreground, Background; Selection_background, Warning
    ; Search_foreground, Background; Search_background, Normal_accent
    ; Search_current_foreground, Background; Search_current_background, Insert_accent
    ; Diff_added, Insert_accent; Diff_removed, Error; Diff_hunk, Special ]
  in
  { id; title; kind = Dark
  ; colors = colors @ List.map aliases ~f:(fun (role, source) -> role, get source) }
;;

let midnight = legacy "midnight" "Midnight"
  [0x0b0b0c;0x111113;0xd0d0d0;0x1c1c1f;0x5a5a60;0x3a3a40;0x1d1d21;0x7aa2f7;0x9ece6a;0xbb9af7;0xe0af68;0xf7768e;0x7aa2f7;0xd0d0d0;0xf5f5f5;0xbb9af7;0x9ece6a;0xff9e64;0x7a8994;0x7dcfff;0x7aa2f7;0x73daca;0xe0af68]
let crimson = legacy "crimson" "Crimson"
  [0x0c0a0a;0x131010;0xe0d2d2;0x201a1b;0x665558;0x443639;0x211a1b;0xe85d75;0x9ece6a;0xc9a0ff;0xffb86c;0xff3355;0xe85d75;0xe0d2d2;0xd11f3c;0xff4f5e;0xf2a07b;0xff9e64;0x8c6f75;0xf76e9e;0xff7b54;0xd98aa0;0xffcb6b]
let ember = legacy "ember" "Ember"
  [0x141412;0x1d2021;0xebdbb2;0x282828;0x665c54;0x504945;0x282828;0x83a598;0xb8bb26;0xd3869b;0xfabd2f;0xfb4934;0x83a598;0xebdbb2;0xfabd2f;0xfb4934;0xb8bb26;0xd3869b;0x928374;0xfabd2f;0x8ec07c;0x83a598;0xfe8019]
let glacier = legacy "glacier" "Glacier"
  [0x090c10;0x0f1419;0xc8d3e0;0x171e26;0x4e5a68;0x2e3a48;0x171e26;0x5cc8ff;0x7fe0c0;0xf08fc0;0xe6c384;0xff6b7f;0x5cc8ff;0xc8d3e0;0xbfe8ff;0x82aaff;0xa3e4d7;0xc3a6ff;0x63778a;0x89ddff;0x5cc8ff;0x6bd8c8;0xb4c6ff]

(* Base16 supplies a complete table; semantic overrides can then separate roles
   that share a slot without changing the public adapter or other presets. *)
let with_overrides t (overrides : (Role.t * int) list) =
  { t with colors = List.map t.colors ~f:(fun (role, original) ->
      role, match List.Assoc.find overrides role ~equal:Role.equal with
      | Some packed -> rgb packed
      | None -> original) }
;;

(* Nostalgic Vim-inspired neon, not an exact Vim colorscheme port. Document,
   backdrop, and current line all stay true black, without a gray cursor band. *)
let vim_classic =
  of_base16 ~id:"vim-classic" ~title:"Vim Classic" ~kind:Dark
    ~palette:(Array.of_list_map
      [0x000000;0x101010;0x404040;0x707070;0xb0b0b0;0xd3d3d3;0xffffff;0xffffff;0xff6060;0xff80ff;0xffff00;0x00ff00;0x80a0ff;0x00ffff;0xffff00;0xffa500]
      ~f:rgb)
  |> fun t -> with_overrides t
    [ Current_line, 0x000000; Syntax_comment, 0x8080ff
    ; Syntax_string, 0xff80ff; Syntax_type, 0x00ff00; Special, 0xffa500
    ; Selection_background, 0x000080; Selection_foreground, 0xffffff
    ; Search_background, 0xffff00; Search_current_background, 0x00ffff ]
;;

(* Solarized tones with adapted semantic mapping, not exact Vim plugin parity.
   The warm-paper variants retain green keywords, cyan strings, blue functions,
   and magenta numbers, independently of the Base16 slot aliases. *)
let solar_preset ~id ~title ~values ~green ~cyan ~magenta ~selection =
  of_base16 ~id ~title ~kind:Light ~palette:(Array.of_list_map values ~f:rgb)
  |> fun t -> with_overrides t
    [ Syntax_keyword, green; Syntax_string, cyan
    ; Syntax_number, magenta; Syntax_constant, magenta
    ; Special, List.nth_exn values 9
    ; Selection_background, selection; Selection_foreground, List.hd_exn values
    ; Search_background, List.nth_exn values 10
    ; Search_foreground, List.nth_exn values 7
    ; Search_current_background, cyan
    ; Search_current_foreground, List.nth_exn values 7 ]
;;

let solarized_light =
  solar_preset ~id:"solarized-light" ~title:"Solarized Light"
    ~values:[0xfdf6e3;0xeee8d5;0x93a1a1;0x839496;0x586e75;0x657b83;0x073642;0x002b36;0xdc322f;0xcb4b16;0xb58900;0x859900;0x2aa198;0x268bd2;0x6c71c4;0xd33682]
    ~green:0x859900 ~cyan:0x2aa198 ~magenta:0xd33682 ~selection:0x073642
;;

let linen_solar =
  solar_preset ~id:"linen-solar" ~title:"Linen Solar"
    ~values:[0xfcf5e9;0xeee5d5;0xc7bba6;0x7b8b89;0x52666b;0x425b63;0x27434c;0x17313a;0xc43b38;0xb95720;0xb18a16;0x6f8500;0x168b83;0x207aba;0x7063b5;0xbc3176]
    ~green:0x6f8500 ~cyan:0x168b83 ~magenta:0xbc3176 ~selection:0x28556a
;;

let sandstone_solar =
  solar_preset ~id:"sandstone-solar" ~title:"Sandstone Solar"
    ~values:[0xf5e6c4;0xe8d6ad;0xc4ad80;0x827c65;0x595b4b;0x394b4d;0x253a3d;0x142b30;0xba332b;0xb34a13;0xa17b00;0x657900;0x087f78;0x196eaa;0x6555a6;0xaf296d]
    ~green:0x657900 ~cyan:0x087f78 ~magenta:0xaf296d ~selection:0x234e5b
;;

let all =
  [ midnight; crimson; ember; glacier
  ; vim_classic; solarized_light; linen_solar; sandstone_solar ]
  @ List.map curated ~f:(fun (id, title, kind, values) ->
    of_base16 ~id ~title ~kind ~palette:(Array.of_list_map values ~f:rgb))
;;

let () =
  let ids = List.map all ~f:id in
  if List.contains_dup ids ~compare:String.compare
  then invalid_arg "Theme: duplicate registry ID";
  List.iter all ~f:(fun t -> List.iter Role.all ~f:(fun role -> validate_rgb (color t role)))
;;

let default = crimson
let normalize s =
  String.lowercase (String.strip s)
  |> String.map ~f:(function ' ' | '_' -> '-' | c -> c)
;;
let find name =
  let name = normalize name in
  List.find all ~f:(fun t -> String.equal t.id name)
;;
