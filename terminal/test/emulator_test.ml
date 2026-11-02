open! Core
open Ches_terminal
module E = Ches_terminal_emulator.Emulator

let check (condition : bool) (message : string) : unit =
  if not condition then failwith message
;;

let feed (t : E.t) (s : string) : unit = ignore (E.feed t s : string)
let snap (t : E.t) : Model.snapshot = E.snapshot t ~exited:None
let text (s : Model.snapshot) (row : int) : string =
  Array.map s.rows.(row) ~f:(fun (c : Model.cell) -> c.text) |> String.concat_array
;;
let key ?(modifiers : Model.modifiers = Model.no_modifiers) (t : E.t) (code : Model.key_code) : string =
  E.key t { code; modifiers }
;;

let () =
  let t : E.t = E.create ~rows:4 ~cols:12 in
  feed t "hello\r\nworld";
  let before : Model.snapshot = snap t in
  check (String.is_prefix (text before 0) ~prefix:"hello") "plain output";
  check (before.cursor_row = 1 && before.cursor_col = 5) "cursor position";
  feed t "\027[1;2H\027[31;48;2;10;20;30;1;3;4;7mX\027[0m";
  let cell : Model.cell = (snap t).rows.(0).(1) in
  check (String.equal cell.text "X") "cursor addressing";
  check (Model.equal_color cell.style.fg (Indexed 1)) "indexed foreground";
  check (Model.equal_color cell.style.bg (Rgb (10,20,30))) "RGB background";
  check (cell.style.bold && cell.style.italic && cell.style.underline && cell.style.reverse) "SGR styles";
  check (String.equal before.rows.(0).(1).text "e") "snapshot ownership";
  feed t "\027[2J\027[H";
  check (String.equal (text (snap t) 0) "            ") "erase display";
  feed t "\027[?25l";
  check (not (snap t).cursor_visible) "hide cursor";
  feed t "\027[?25h";
  check (snap t).cursor_visible "show cursor";
  feed t "normal\027[?1049hALT";
  check (String.is_substring (text (snap t) 0) ~substring:"ALT") "alternate screen";
  feed t "\027[?1049l";
  check (String.is_prefix (text (snap t) 0) ~prefix:"normal") "alternate screen restoration";
  feed t "\027[2J\027[H\xe7";
  feed t "\x95\x8ce\xcc";
  feed t "\x81";
  let unicode : Model.snapshot = snap t in
  check (String.equal unicode.rows.(0).(0).text "界") "split UTF-8";
  check (unicode.rows.(0).(0).width = 2) "wide character width";
  check (unicode.rows.(0).(1).width = 0 && String.is_empty unicode.rows.(0).(1).text) "wide continuation";
  check (String.equal unicode.rows.(0).(2).text "é") "combining characters";
  feed t "\027[2J\027[Habcd\027[1;2H\027[P";
  check (String.is_prefix (text (snap t) 0) ~prefix:"acd") "delete character";
  feed t "\027[1;2H\027[@Z";
  check (String.is_prefix (text (snap t) 0) ~prefix:"aZcd") "insert character";
  feed t "\027[2J\027[H1\r\n2\r\n3\r\n4\r\n5";
  check (String.is_prefix (text (snap t) 0) ~prefix:"2") "scrolling";
  check (String.equal (key t Up) "\027[A") "normal cursor key";
  feed t "\027[?1h";
  check (String.equal (key t Up) "\027OA") "application cursor key";
  check (String.equal (key t Right ~modifiers:{ shift=true; alt=false; ctrl=true }) "\027[1;6C") "modified special key";
  check (String.equal (key t (Char (Uchar.of_char 'c')) ~modifiers:{ Model.no_modifiers with ctrl=true }) "\003") "control character";
  check (String.equal (key t (Char (Uchar.of_char 'C')) ~modifiers:{ Model.no_modifiers with ctrl=true }) "\003") "Notty uppercase Ctrl-C";
  check (String.equal (key t (Char (Uchar.of_char '@')) ~modifiers:{ Model.no_modifiers with ctrl=true }) "\000") "Ctrl-@ is NUL";
  check (String.equal (key t Backspace ~modifiers:{ Model.no_modifiers with ctrl=true }) "\008") "Notty Ctrl-H";
  check (String.equal (key t (Char (Uchar.of_char 'x')) ~modifiers:{ Model.no_modifiers with alt=true }) "\027x") "alt character";
  check (String.equal (key t (Char (Uchar.of_scalar_exn 0x754c))) "界") "Unicode key";
  check (String.equal (key t (Char (Uchar.of_scalar_exn 0x754c)) ~modifiers:{ Model.no_modifiers with alt=true }) "\027界") "Alt Unicode key";
  check (String.equal (key t (Function 5)) "\027[15~") "function key";
  check (String.equal (key t (Function 13)) "\027[1;2P") "shifted function key";
  check (String.equal (key t Tab ~modifiers:{ Model.no_modifiers with shift=true }) "\027[Z") "backtab";
  check (String.equal (key t Enter) "\r") "normal enter";
  feed t "\027[20h";
  check (String.equal (key t Enter) "\r\n") "newline-mode enter";
  feed t "\027[20l";
  check (String.equal (E.paste t "a\r\nb\nc\rd") "a\rb\rc\rd") "normal paste newline normalization";
  feed t "\027[?2004h";
  check (String.equal (E.paste t "a\nb") "\027[200~a\nb\027[201~") "bracketed paste";
  check (String.equal (E.paste t "a\r\nb\rc") "\027[200~a\nb\nc\027[201~") "bracketed CRLF normalization";
  feed t "\027[?2004l";
  check (String.equal (E.paste t "x") "x") "disable bracketed paste";
  let reply : string = E.feed t "\027[6n" in
  check (String.is_prefix reply ~prefix:"\027[") "device status response";
  E.resize t ~rows:7 ~cols:20;
  let resized : Model.snapshot = snap t in
  check (Array.length resized.rows = 7 && Array.length resized.rows.(0) = 20) "resize";
  (* Force collections while snapshotting large arrays: verifies FFI roots and
     old-to-young field stores, not just terminal escape parsing. *)
  E.resize t ~rows:100 ~cols:200;
  for _ = 1 to 8 do
    let s : Model.snapshot = snap t in
    Gc.full_major ();
    check (Array.length s.rows.(99) = 200) "snapshot GC integrity"
  done;
  E.close t;
  E.close t;
  print_endline "terminal emulator tests passed"
;;
