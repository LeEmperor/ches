open! Core
open Ches_screen
open Helpers

let field ?(priority = 99) ?(style = Style.Status) id text : Status_field.t =
  { id
  ; spans = Span.of_text text ~style ~special:Status_special
  ; priority
  ; fit = Whole
  ; side = Right
  }
;;

(* Deliberately scrambled; row-specific fitting and placement are not vertical policy. *)
let fields =
  [ field Position "84:12"
  ; field ~priority:1 ~style:Error Message "Write failed"
  ; field ~style:Dirty Dirty "[+]"
  ; field ~style:Pending Pending "2d"
  ; field Filename "/project/src/geometry.ml"
  ; field ~style:(Mode Normal) Mode " NORMAL "
  ]
;;

let show ?(styled = false) fields ~width ~height =
  let tile = Status.vertical ~rect:{ x = 7; y = 4; width; height } fields in
  printf "%d,%d %dx%d\n" tile.rect.x tile.rect.y tile.rect.width tile.rect.height;
  List.iter tile.rows ~f:(fun spans ->
    if styled
    then print_endline (String.concat ~sep:" " (List.map spans ~f:(fun span ->
      sprintf "%s[%s]" (Style.to_string_hum span.style) span.text)))
    else printf "%s|\n" (String.concat (List.map spans ~f:(fun span -> span.text))))
;;

let without id fields = List.filter fields ~f:(fun (field : Status_field.t) ->
  not (Status_field.Id.equal field.id id))

let%expect_test "full vertical ordering, joined filename/dirty, and blank rows" =
  show fields ~width:28 ~height:7;
  [%expect {|
    7,4 28x7
    NORMAL                      |
    /project/src/geometry.ml [+]|
    84:12                       |
    2d                          |
    Write failed                |
                                |
                                |
    |}]
;;

let%expect_test "height selects essential fields, then preserves presentation order" =
  List.iter [ 1; 2; 3; 4; 5 ] ~f:(fun height -> show fields ~width:16 ~height);
  [%expect {|
    7,4 16x1
    NORMAL          |
    7,4 16x2
    NORMAL          |
    Write failed    |
    7,4 16x3
    NORMAL          |
    2d              |
    Write failed    |
    7,4 16x4
    NORMAL          |
    <geometry.ml [+]|
    2d              |
    Write failed    |
    7,4 16x5
    NORMAL          |
    <geometry.ml [+]|
    84:12           |
    2d              |
    Write failed    |
    |}]
;;

let%expect_test "conditional fields and routine feedback yield to editing context" =
  let routine =
    field ~priority:6 ~style:Info Message "Saved" :: without Message fields
    |> without Dirty
  in
  show routine ~width:20 ~height:3;
  show (without Pending routine) ~width:20 ~height:4;
  show (Status.fields (ui "hello")) ~width:20 ~height:5;
  show (Status.fields (ui ~path:"" "hello") |> without Filename) ~width:20 ~height:5;
  show [ field ~style:Dirty Dirty "[+]" ] ~width:6 ~height:2;
  [%expect {|
    7,4 20x3
    NORMAL              |
    <ect/src/geometry.ml|
    2d                  |
    7,4 20x4
    NORMAL              |
    <ect/src/geometry.ml|
    84:12               |
    Saved               |
    7,4 20x5
    NORMAL              |
    f.txt               |
    1:1                 |
                        |
                        |
    7,4 20x5
    NORMAL              |
    1:1                 |
                        |
                        |
                        |
    7,4 6x2
    [+]   |
          |
    |}]
;;

let%expect_test "narrow rows preserve dirty and error styling, and recognizable mode initials" =
  List.iter [ 8; 5; 4; 3; 2; 1 ] ~f:(fun width -> show ~styled:true fields ~width ~height:5);
  [%expect {|
    7,4 8x5
    (Mode Normal)[NORMAL] Status[  ]
    Status_special[<] Status[.ml ] Dirty[[+]]
    Status[84:12   ]
    Pending[2d] Status[      ]
    Error[Write f>]
    7,4 5x5
    (Mode Normal)[NORMA]
    Status_special[<] Status[ ] Dirty[[+]]
    Status[84:12]
    Pending[2d] Status[   ]
    Error[Writ>]
    7,4 4x5
    (Mode Normal)[NORM]
    Dirty[[+]] Status[ ]
    Status[84:] Status_special[>]
    Pending[2d] Status[  ]
    Error[Wri>]
    7,4 3x5
    (Mode Normal)[NOR]
    Dirty[[+]]
    Status[84] Status_special[>]
    Pending[2d] Status[ ]
    Error[Wr>]
    7,4 2x5
    (Mode Normal)[NO]
    Dirty[[>]
    Status[8] Status_special[>]
    Pending[2d]
    Error[W>]
    7,4 1x5
    (Mode Normal)[N]
    Dirty[>]
    Status_special[>]
    Pending[>]
    Error[>]
    |}]
;;

let%expect_test "Unicode paths and message clipping respect cells, not bytes" =
  let fields =
    [ field ~style:(Mode Insert) Mode " INSERT "
    ; field Filename "目录/中é.ml"
    ; field ~priority:6 ~style:Info Message "中éXYZ"
    ]
  in
  List.iter [ 8; 5; 3; 2; 1 ] ~f:(fun width -> show fields ~width ~height:3);
  [%expect {|
    7,4 8x3
    INSERT  |
    </中é.ml|
    中éXYZ  |
    7,4 5x3
    INSER|
    <é.ml|
    中éX>|
    7,4 3x3
    INS|
    <ml|
    中>|
    7,4 2x3
    IN|
    <l|
     >|
    7,4 1x3
    I|
    <|
    >|
    |}]
;;

let%expect_test "current UI fields include insert mode, dirty state, pending command and error" =
  let t = run (ui "hello") (keys "iX<Esc> q ") in
  let current = Status.fields t in
  assert (List.exists current ~f:(fun field ->
    Status_field.Id.equal field.id Message && field.priority = 1));
  assert (List.exists current ~f:(fun field -> Status_field.Id.equal field.id Pending));
  show ~styled:true (Status.fields t) ~width:32 ~height:5;
  let insert = run (ui "hello") (keys "iX") in
  show (Status.fields insert) ~width:16 ~height:4;
  [%expect {|
    7,4 32x5
    (Mode Normal)[NORMAL] Status[                          ]
    Status[f.txt ] Dirty[[+]] Status[                       ]
    Status[1:1                             ]
    Pending[Space] Status[                           ]
    Error[Unsaved changes: save them or f>]
    7,4 16x4
    INSERT          |
    f.txt [+]       |
    1:2             |
                    |
    |}]
;;

let%expect_test "empty and negative allocations normalize safely without losing their origin" =
  List.iter [ 0, 3; 12, 0; 0, 0; -2, -3 ] ~f:(fun (width, height) ->
    show fields ~width ~height);
  show [] ~width:4 ~height:2;
  [%expect {|
    7,4 0x3
    |
    |
    |
    7,4 12x0
    7,4 0x0
    7,4 0x0
    7,4 4x2
        |
        |
    |}]
;;

let%expect_test "every vertical row has its allocation's Unicode display width" =
  let unicode =
    [ field Filename "目录/\t中é\027.ml"
    ; field ~style:Dirty Dirty "[+]"
    ; field ~style:(Mode Normal) Mode " NORMAL "
    ; field ~priority:1 ~style:Error Message "\027中é\001 failed"
    ; field ~style:Pending Pending "界\t"
    ; field Position "1000:1000"
    ]
  in
  List.iter [ fields; unicode; []; without Filename unicode ] ~f:(fun fields ->
    List.iter [ -1; 0; 1; 2; 3; 4; 5; 8; 16; 28 ] ~f:(fun width ->
      List.iter [ -1; 0; 1; 2; 3; 4; 5; 8 ] ~f:(fun height ->
        let tile = Status.vertical ~rect:{ x = 7; y = 4; width; height } fields in
        assert (tile.rect.x = 7 && tile.rect.y = 4);
        assert (List.length tile.rows = Int.max 0 height);
        List.iter tile.rows ~f:(fun spans ->
          assert (Span.total_width spans = Int.max 0 width);
          let text = String.concat (List.map spans ~f:(fun span -> span.text)) in
          assert (Cell_map.total_width (Cell_map.glyphs text) = Int.max 0 width);
          assert (not (String.exists text ~f:(fun c -> Char.to_int c < 32 || Char.to_int c = 127)))))));
  print_endline "dimensions, origin, cell widths, and control escaping passed";
  [%expect {| dimensions, origin, cell widths, and control escaping passed |}]
;;
