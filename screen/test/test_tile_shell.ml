open! Core
open Ches_screen

let rect x y width height : Geometry.Rect.t = { x; y; width; height }

let show_rect ({ x; y; width; height } : Geometry.Rect.t) =
  sprintf "%d,%d %dx%d" x y width height
;;

let show_layout name policy (r : Geometry.Rect.t) =
  let l = Tile_shell.layout policy r in
  printf
    "%-7s %-9s %-6s pad %d title %-10s footer %-10s content %s\n"
    name
    (sprintf "%dx%d" r.width r.height)
    (if l.framed then "framed" else "bare")
    l.padding
    (show_rect l.title)
    (show_rect l.footer)
    (show_rect l.content)
;;

let text rows =
  List.iter rows ~f:(fun row ->
    print_endline (String.concat (List.map row ~f:(fun (s : Span.t) -> s.text)) ^ "|"))
;;

let styled rows =
  List.iter rows ~f:(fun row ->
    print_endline
      (String.concat
         ~sep:" "
         (List.map row ~f:(fun (s : Span.t) ->
            sprintf "%s[%s]" (Style.to_string_hum s.style) s.text))))
;;

let content ?footer ?(title = "View") body : Tile_shell.Content.t =
  { title; footer; body = List.map body ~f:(fun s -> Tile_text.row Status s ~width:100) }
;;

let render ?(focused = false) policy r c =
  Tile_shell.render (Tile_shell.layout policy r) ~focused c
;;

let%expect_test "frame, then padding, then the frame itself give way, at offset origins" =
  List.iter
    [ rect 7 4 40 10
    ; rect 7 4 16 3 (* the smallest minor allocation: framed with padding *)
    ; rect 7 4 15 3
    ; rect 7 4 13 3
    ; rect 7 4 40 2
    ; rect 7 4 40 1
    ; rect 7 4 0 0
    ; rect 7 4 (-3) (-2)
    ]
    ~f:(show_layout "minor" Tile_shell.Policy.minor);
  List.iter
    [ rect 0 0 28 40
    ; rect 0 0 80 6 (* the default stacked status stays bare *)
    ; rect 0 0 12 7
    ; rect 0 0 10 7
    ; rect 0 0 9 7
    ; rect 0 0 28 2
    ]
    ~f:(show_layout "status" Tile_shell.Policy.status);
  [%expect
    {|
    minor   40x10     framed pad 1 title 8,4 38x1   footer 8,13 38x1  content 9,5 36x8
    minor   16x3      framed pad 1 title 8,4 14x1   footer 8,6 14x1   content 9,5 12x1
    minor   15x3      framed pad 0 title 8,4 13x1   footer 8,6 13x1   content 8,5 13x1
    minor   13x3      bare   pad 0 title 7,4 13x1   footer 7,6 13x1   content 7,5 13x1
    minor   40x2      bare   pad 0 title 7,4 40x1   footer 7,5 40x1   content 7,5 40x0
    minor   40x1      bare   pad 0 title 7,4 40x1   footer 7,5 40x0   content 7,5 40x0
    minor   0x0       bare   pad 0 title 7,4 0x0    footer 7,4 0x0    content 7,4 0x0
    minor   -3x-2     bare   pad 0 title 7,4 0x0    footer 7,4 0x0    content 7,4 0x0
    status  28x40     framed pad 1 title 1,0 26x1   footer 1,39 26x1  content 2,1 24x38
    status  80x6      bare   pad 0 title 0,0 80x0   footer 0,6 80x0   content 0,0 80x6
    status  12x7      framed pad 1 title 1,0 10x1   footer 1,6 10x1   content 2,1 8x5
    status  10x7      framed pad 0 title 1,0 8x1    footer 1,6 8x1    content 1,1 8x5
    status  9x7       bare   pad 0 title 0,0 9x0    footer 0,7 9x0    content 0,0 9x7
    status  28x2      bare   pad 0 title 0,0 28x0   footer 0,2 28x0   content 0,0 28x2
    |}]
;;

let%expect_test "labels sit in the borders, cut by cells; focus changes only the frame style" =
  let c =
    content
      ~title:"Wide 界🙂 title that will not fit"
      ~footer:(Tile_shell.Label.hint "j/k move | e details")
      [ "first row, longer than the content area"; "界🙂 é" ]
  in
  text (render Tile_shell.Policy.minor (rect 0 0 24 5) c);
  styled (render ~focused:true Tile_shell.Policy.minor (rect 0 0 24 4) c);
  (* Notices and pending prefixes keep their semantic styles; a border too narrow for
     any text stays unbroken. *)
  let notice = Tile_shell.Label.footer ~notice:(Some "read-only") ~pending:None ~default:"-" in
  let pending = Tile_shell.Label.footer ~notice:None ~pending:(Some "g") ~default:"-" in
  styled [ List.last_exn (render Tile_shell.Policy.minor (rect 0 0 24 3) { c with footer = Some notice }) ];
  styled [ List.last_exn (render Tile_shell.Policy.minor (rect 0 0 24 3) { c with footer = Some pending }) ];
  text (render Tile_shell.Policy.minor (rect 0 0 16 3) { c with title = "" });
  text (render Tile_shell.Policy.minor (rect 0 0 5 3) c);
  [%expect
    {|
    ╭─ Wide 界🙂 title th> ╮|
    │ first row, longer th │|
    │ 界🙂 é               │|
    │                      │|
    ╰─ j/k move | e detai> ╯|
    Border_focused[╭─] Title[ Wide 界🙂 title th] Title_special[>] Title[ ] Border_focused[╮]
    Border_focused[│] Status[ first row, longer th ] Border_focused[│]
    Border_focused[│] Status[ 界🙂 é               ] Border_focused[│]
    Border_focused[╰─] Hint[ j/k move | e detai] Title_special[>] Hint[ ] Border_focused[╯]
    Border[╰─] Warning[ read-only ] Border[──────────╯]
    Border[╰─] Pending[ Pending: g ] Border[─────────╯]
    ╭──────────────╮|
    │ first row, l │|
    ╰─ j/k move |> ╯|
    Wide>|
    first|
    j/k >|
    |}]
;;

let%expect_test "every size renders exact rows, with body text at the content origin" =
  let marker = "@" in
  List.iter [ Tile_shell.Policy.minor; Tile_shell.Policy.status ] ~f:(fun policy ->
    List.iter (List.range 0 40) ~f:(fun width ->
      List.iter (List.range 0 12) ~f:(fun height ->
        let r = rect 3 2 width height in
        let layout = Tile_shell.layout policy r in
        let inside (c : Geometry.Rect.t) =
          assert (c.width >= 0 && c.height >= 0);
          assert (c.x >= r.x && c.y >= r.y);
          assert (c.x + c.width <= r.x + width && c.y + c.height <= r.y + height)
        in
        List.iter [ layout.title; layout.footer; layout.content ] ~f:inside;
        let rows =
          Tile_shell.render layout ~focused:true
            (content ~title:"界🙂\tlabel" ~footer:(Tile_shell.Label.hint "é\027")
               [ marker ^ "界🙂\t\027 text" ])
        in
        assert (List.length rows = height);
        List.iter rows ~f:(fun row ->
          assert (Span.total_width row = width);
          List.iter row ~f:(fun span ->
            assert (Cell_map.total_width (Cell_map.glyphs span.text) = span.width);
            assert (not (String.exists span.text ~f:(fun c -> Char.to_int c < 32)))));
        (* The body's first cell lands exactly at the content origin. *)
        if layout.content.width > 0 && layout.content.height > 0
        then (
          let row =
            List.nth_exn rows (layout.content.y - r.y)
            |> List.map ~f:(fun (s : Span.t) -> s.text)
            |> String.concat
          in
          let column =
            String.substr_index_exn row ~pattern:marker
            |> String.prefix row
            |> Cell_map.glyphs
            |> Cell_map.total_width
          in
          assert (column = layout.content.x - r.x)))));
  print_endline "rows exact; body at content origin";
  [%expect {| rows exact; body at content origin |}]
;;
