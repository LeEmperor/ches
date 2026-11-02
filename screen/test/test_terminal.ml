open! Core
open Ches_screen
module M = Ches_terminal.Model
module U = Ui_state

let width = 80
let height = 24
let run t inputs = Helpers.run ~width ~height t inputs
let open_terminal t = run t (Helpers.keys " /")
let key ?(modifiers = M.no_modifiers) code : U.Input.t = Terminal_key { M.code; modifiers }
let ctrl c = key ~modifiers:{ M.no_modifiers with ctrl = true } (Char (Uchar.of_char c))
let hide t = run t ([ ctrl ' ' ] @ Helpers.keys " /")
let take = U.take_terminal_requests
let requests_equal a b =
  if not (List.equal M.equal_request a b) then
    raise_s [%message "terminal requests differ" (a : M.request list) (b : M.request list)]
let style : M.style =
  { fg = Indexed 2; bg = Rgb (10, 20, 30); bold = true; italic = true
  ; underline = true; reverse = true }

let at ms = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms (Float.of_int ms))
let timed ?(modifiers = M.no_modifiers) ms c : U.Input.t =
  Terminal_key_at { key = { code = Char (Uchar.of_char c); modifiers }; at = at ms }
let tick ms : U.Input.t = Terminal_tick (at ms)
let j_request = M.Key { code = Char (Uchar.of_char 'j'); modifiers = M.no_modifiers }

let%test_unit "timed jk consumes both only before 150ms; timeout and mismatches keep order" =
  let fresh () = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run (fresh ()) [ timed 0 'j'; tick 149 ] in
  assert (U.terminal_key_pending t);
  requests_equal (snd (take t)) [];
  let t = run t [ timed 149 'k' ] in
  assert (Option.is_some (U.terminal_inspection t));
  assert (not (U.terminal_key_pending t));
  requests_equal (snd (take t)) [];
  let t = run (fresh ()) [ timed 0 'j'; tick 150; tick 300 ] in
  requests_equal (snd (take t)) [ j_request ];
  let t = run (fresh ()) [ timed 0 'j'; timed 150 'k' ] in
  assert (Option.is_none (U.terminal_inspection t));
  requests_equal (snd (take t)) [ j_request; M.Key { code = Char (Uchar.of_char 'k'); modifiers = M.no_modifiers } ];
  let t = run (fresh ()) [ timed 0 'j'; timed 10 'j'; timed 20 'x' ] in
  requests_equal (snd (take t)) [ j_request; j_request; M.Key { code = Char (Uchar.of_char 'x'); modifiers = M.no_modifiers } ];
  let modifiers = { M.no_modifiers with alt = true } in
  let t = run (fresh ()) [ timed 0 'j'; timed ~modifiers 10 'k' ] in
  requests_equal (snd (take t)) [ j_request; M.Key { code = Char (Uchar.of_char 'k'); modifiers } ]
;;

let%test_unit "deferred j flushes before Ctrl-Space, paste, resize and hidden lifecycle" =
  let fresh () = open_terminal (Helpers.ui "x") |> take |> fst in
  let pending () = run (fresh ()) [ timed 0 'j' ] in
  let t = run (pending ()) [ ctrl ' ' ] in
  assert (Option.is_some (U.terminal_inspection t));
  requests_equal (snd (take t)) [ j_request ];
  let t = run (pending ()) [ Paste_start; timed 10 'j'; timed 20 'k'; Paste_end; tick 300 ] in
  assert (Option.is_none (U.terminal_inspection t));
  requests_equal (snd (take t)) [ j_request; Paste "jk" ];
  let t = Helpers.run ~width:60 ~height:16 (pending ()) [ Resize ] in
  let layout = U.terminal_layout t ~width:60 ~height:16 |> Option.value_exn in
  requests_equal (snd (take t)) [ j_request; Resize { rows = layout.content.height; cols = layout.content.width } ];
  let t = Helpers.run ~width:10 ~height:3 (pending ()) [ Resize ] in
  assert (not (U.terminal_key_pending t));
  let t, requests = take t in
  requests_equal requests [ j_request ];
  let t = open_terminal t |> take |> fst |> fun t -> run t [ tick 300 ] in
  requests_equal (snd (take t)) []
;;

let%test_unit "preferred terminal size survives clamping hide and hidden adjustments" =
  let big t inputs = Helpers.run ~width:1200 ~height:600 t inputs in
  let open_big t = big t (Helpers.keys " /") in
  let size t =
    let l = U.terminal_layout t ~width:1200 ~height:600 |> Option.value_exn in
    l.outer.width, l.outer.height in
  let t = open_big (Helpers.ui "x") |> take |> fst in
  [%test_eq: int * int] (size t) (132, 40);
  let t = big t ([ ctrl ' ' ] @ Helpers.keys "3+") in
  [%test_eq: int * int] (size t) (162, 46);
  let t, requests = take t in
  let l = U.terminal_layout t ~width:1200 ~height:600 |> Option.value_exn in
  requests_equal requests [ Resize { rows = l.content.height; cols = l.content.width } ];
  let t = Helpers.run ~width:40 ~height:12 t [ Resize ] in
  let t = big t [ Resize ] in
  [%test_eq: int * int] (size t) (162, 46);
  let t = big t (Helpers.keys " /") |> take |> fst in
  let t = big t (Helpers.keys "2 t-") in
  requests_equal (snd (take t)) [];
  let t = open_big t in
  [%test_eq: int * int] (size t) (142, 42);
  let t = big t ([ ctrl ' ' ] @ Helpers.keys "999+") in
  [%test_eq: int * int] (size t) (1000, 500);
  let t = big t (Helpers.keys "999-") in
  [%test_eq: int * int] (size t) (20, 6);
  let t = big t (Helpers.keys " tr") in
  [%test_eq: int * int] (size t) (132, 40)
;;
let snapshot ?exited () : M.snapshot =
  { rows = [| [| { M.text = "界"; width = 2; style }
               ; { M.text = ""; width = 0; style }
               ; { M.text = "á"; width = 1; style } |] |]
    ; cursor_row = 0; cursor_col = 2; cursor_visible = true; exited }

let%test_unit "Tile Term footer defaults quiet in every mode and opts into binding hints" =
  let s = Some (snapshot ()) in
  let inspection = Terminal_tile.inspect s in
  let visual, _ = Terminal_tile.perform inspection ~rows:4 (Visual Characterwise) in
  let block = Terminal_tile.toggle_block inspection ~rows:4 in
  List.iter [ None, "INSERT"; Some inspection, "NORMAL"; Some visual, "VISUAL"
            ; Some block, "VISUAL BLOCK" ] ~f:(fun (inspection, mode) ->
    let render ?hotkey_hints () =
      Terminal_tile.render ?hotkey_hints ?inspection s ~failure:None ~width:200 ~rows:4 in
    let quiet = render () and shown = render ~hotkey_hints:true () in
    [%test_eq: string] (Option.value_exn quiet.footer).text mode;
    assert (String.is_prefix (Option.value_exn shown.footer).text ~prefix:(mode ^ " | "));
    assert (String.is_substring (Option.value_exn shown.footer).text
      ~substring:(if String.equal mode "INSERT" then "Ctrl-Space/jk" else "y/yy: yank"));
    [%test_eq: string] quiet.title "Tile Term 1";
    [%test_eq: string list list]
      (List.map quiet.body ~f:(List.map ~f:(fun s -> s.Span.text)))
      (List.map shown.body ~f:(List.map ~f:(fun s -> s.Span.text))))
;;

let%test_unit "quiet Tile Term footer retains exit startup failure and input rejection status" =
  List.iter
    [ Some (snapshot ~exited:"exit 7" ()), None, "Exited: exit 7", true
    ; None, Some "forkpty failed", "Failed: forkpty failed", true
    ; Some (snapshot ()), Some "queue full", "Input rejected: queue full", false ]
    ~f:(fun (snapshot, failure, status, restartable) ->
      let render hotkey_hints = Terminal_tile.render ~hotkey_hints snapshot ~failure ~width:200 ~rows:4 in
      let quiet = render false and shown = render true in
      [%test_eq: string] (Option.value_exn quiet.footer).text (status ^ " | INSERT");
      assert (String.is_prefix (Option.value_exn shown.footer).text ~prefix:status);
      [%test_eq: bool]
        (String.is_substring (Option.value_exn shown.footer).text ~substring:"r: restart") restartable)
;;

let%test_unit "Space v ? controls Tile Term frame hints without changing layout or PTY dimensions" =
  let initial = Helpers.ui "document" in
  let quiet = open_terminal initial |> take |> fst in
  let enabled = run initial (Helpers.keys " v?") in
  assert (U.hotkey_hints enabled);
  let shown = open_terminal enabled |> take |> fst in
  let layout t = U.terminal_layout t ~width ~height |> Option.value_exn in
  assert (Tile_shell.Layout.equal (layout quiet) (layout shown));
  let footer t =
    let frame = Frame.render t ~width ~height in
    List.nth_exn frame.rows (layout t).footer.y
    |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  assert (not (String.is_substring (footer quiet) ~substring:"Ctrl-Space"));
  assert (String.is_substring (footer shown) ~substring:"Ctrl-Space");
  let hidden = hide shown |> fun t -> run t (Helpers.keys " v?") |> open_terminal in
  assert (not (U.hotkey_hints hidden));
  [%test_eq: string] (footer hidden) (footer quiet);
  requests_equal (snd (take hidden)) []
;;

let%test_unit "exit flushes original generation; stale events and ticks cannot write into restart" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let generation = U.terminal_generation t in
  let t = run t [ timed 0 'j'; Terminal_update { generation; event = Snapshot (snapshot ~exited:"done" ()) } ] in
  assert (not (U.terminal_key_pending t));
  let t, requests = take t in
  requests_equal requests [ j_request ];
  let t = run t (Helpers.keys "r") in
  assert (U.terminal_generation t = generation + 1);
  let t, _ = take t in
  let t = run t [ tick 1000; Terminal_update { generation; event = Failed "old" } ] in
  requests_equal (snd (take t)) [];
  assert (Option.is_none (U.terminal_inspection t));
  assert (Option.is_none (U.terminal_failure t));
  let t = run t [ timed 2000 'j'; Terminal_update { generation; event = Snapshot (snapshot ~exited:"old" ()) }; timed 2010 'k' ] in
  assert (Option.is_some (U.terminal_inspection t));
  requests_equal (snd (take t)) []
;;

let%test_unit "size changes preserve frozen inspection and live snapshot; reset never restarts" =
  let big t inputs = Helpers.run ~width:240 ~height:80 t inputs in
  let t = big (Helpers.ui "x") (Helpers.keys " /") |> take |> fst in
  let original = snapshot () in
  let t = big t [ Terminal (Snapshot original); ctrl ' ' ] in
  let frozen = U.terminal_inspection t |> Option.value_exn |> Terminal_tile.inspection_text in
  let t = big t (Helpers.keys "v+=-") in
  let text = U.terminal_inspection t |> Option.value_exn |> Terminal_tile.inspection_text in
  assert (Ches_tile.Text_view.cursor frozen = Ches_tile.Text_view.cursor text);
  assert (Option.is_some (Ches_tile.Text_view.selection text));
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some original));
  let generation = U.terminal_generation t in
  let t = big t [ Terminal (Snapshot (snapshot ~exited:"done" ())) ] |> take |> fst in
  let t = big t (Helpers.keys " tr") in
  assert (U.terminal_generation t = generation);
  assert (Option.is_some (U.terminal_inspection t));
  requests_equal (snd (take t)) []
;;

let%test_unit "palette sizing while hidden retains preferred size without starting a shell" =
  let big t inputs = Helpers.run ~width:240 ~height:80 t inputs in
  let t = big (Helpers.ui "x") (Helpers.keys " ccgrow tile term<CR>") in
  assert (not (U.terminal_visible t));
  requests_equal (snd (take t)) [];
  let t = big t (Helpers.keys " /") in
  let l = U.terminal_layout t ~width:240 ~height:80 |> Option.value_exn in
  [%test_eq: int * int] (l.outer.width, l.outer.height) (142, 42);
  let t = big t ([ ctrl ' ' ] @ Helpers.keys " /") |> take |> fst in
  let t = big t (Helpers.keys " ccshrink tile term<CR> ccreset tile term size<CR>") in
  requests_equal (snd (take t)) [];
  let t = big t (Helpers.keys " /") in
  let l = U.terminal_layout t ~width:240 ~height:80 |> Option.value_exn in
  [%test_eq: int * int] (l.outer.width, l.outer.height) (132, 40)
;;

let%test_unit "lazy session; exact content geometry; hide preserves shell and snapshot" =
  let t = Helpers.ui ~path:"/tmp/project/file.ml" "document" in
  let t, requests = take t in
  requests_equal requests [];
  let t = open_terminal t in
  assert (U.terminal_capturing t);
  let layout = U.terminal_layout t ~width ~height |> Option.value_exn in
  let t, requests = take t in
  requests_equal requests [ Start { cwd = "/tmp/project"
    ; rows = layout.content.height; cols = layout.content.width } ];
  let s = snapshot () in
  let t = run t [ Terminal (Snapshot s) ] |> hide in
  assert (not (U.terminal_capturing t));
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some s));
  let t, requests = take t in
  requests_equal requests [];
  let t = open_terminal t in
  let _, requests = take t in
  requests_equal requests []
;;

let%test_unit "full fidelity keys bypass editor including Escape and Ctrl-backslash" =
  let t = open_terminal (Helpers.ui "unchanged") |> take |> fst in
  let events = [ key Escape; ctrl 'c'; key Tab; key Up
    ; key ~modifiers:{ M.no_modifiers with alt = true; shift = true } (Function 4)
    ; key (Char (Uchar.of_scalar_exn 0x1f642)); ctrl '\\'; key Left ] in
  let t = run t events in
  assert (U.terminal_capturing t);
  let _, requests = take t in
  requests_equal requests (List.map events ~f:(function Terminal_key k -> M.Key k | _ -> assert false));
  [%test_eq: string] (Ches_core.Editor.text (Ches_app.Controller.editor (U.controller t))
    |> Ches_core.Text_buffer.to_string) "unchanged"
;;

let%test_unit "restore supporting focus; background output does not focus; other float leaves capture" =
  let t = run (Helpers.ui "x") (Helpers.keys " vo") in
  let prior = U.focused_view t ~width ~height in
  assert (Ches_tile.View_id.equal prior Problems_tile.id);
  let t = open_terminal t |> hide in
  assert (Ches_tile.View_id.equal (U.focused_view t ~width ~height) prior);
  let t = run t [ Terminal (Snapshot (snapshot ())) ] in
  assert (not (U.terminal_capturing t));
  assert (Ches_tile.View_id.equal (U.focused_view t ~width ~height) prior);
  let t = open_terminal t in
  let t = U.open_line_picker t ~width ~height in
  assert (not (U.terminal_capturing t));
  assert (not (U.terminal_visible t));
  assert (Option.is_some (U.line_picker t))
;;

let%test_unit "resize uses content; too small hides without stop and does not reopen on growth" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = Helpers.run ~width:60 ~height:16 t [ Resize ] in
  let layout = U.terminal_layout t ~width:60 ~height:16 |> Option.value_exn in
  let t, requests = take t in
  requests_equal requests [ Resize { rows = layout.content.height; cols = layout.content.width } ];
  let t = Helpers.run ~width:10 ~height:3 t [ Resize ] in
  assert (not (U.terminal_capturing t));
  let t, requests = take t in
  requests_equal requests [];
  let t = run t [ Resize ] in
  assert (not (U.terminal_visible t));
  let t = open_terminal t in
  let layout = U.terminal_layout t ~width ~height |> Option.value_exn in
  let _, requests = take t in
  requests_equal requests [ Resize { rows = layout.content.height; cols = layout.content.width } ]
;;

let%test_unit "paste ignores hide shortcut; loss of owner drains safely through end" =
  let t = open_terminal (Helpers.ui "document") |> take |> fst in
  let t = run t [ Paste_start; ctrl '\\'; ctrl 'n'; key Tab; key Enter
    ; key (Char (Uchar.of_scalar_exn 0x1b)); key (Char (Uchar.of_scalar_exn 0x9b))
    ; key (Char (Uchar.of_scalar_exn 0x754c)); Paste_end ] in
  assert (U.terminal_capturing t);
  assert (not (U.pasting t));
  let t, requests = take t in
  requests_equal requests [ Paste "\t\n界" ];
  let t = run t [ Paste_start; key (Char (Uchar.of_char 'i')) ] in
  let t = Helpers.run ~width:10 ~height:3 t [ Resize ] in
  assert (not (U.terminal_visible t));
  assert (U.terminal_capturing t);
  let t = run t [ key (Char (Uchar.of_char 'x')); Paste_end ] in
  assert (not (U.terminal_capturing t));
  let _, requests = take t in
  requests_equal requests []
;;

let%test_unit "exit retains screen; only explicit restart starts again" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let s = snapshot ~exited:"exit 0" () in
  let t = run t [ Terminal (Snapshot s) ] |> hide |> open_terminal in
  let t, requests = take t in
  requests_equal requests [];
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some s));
  let t = run t [ key Enter; key (Char (Uchar.of_char 'r')) ] in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "explicit restart missing"
;;

let%test_unit "Ctrl-Space variants enter Normal and Space slash hides" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t ([ ctrl '@' ] @ Helpers.keys " /") in
  assert (not (U.terminal_visible t));
  let t = open_terminal t in
  let t = run t [ key (Char (Uchar.of_scalar_exn 0)) ] in
  assert (Option.is_some (U.terminal_inspection t));
  let t = run t (Helpers.keys "i") in
  assert (Option.is_none (U.terminal_inspection t));
  let t = run t ([ U.Input.Terminal (Snapshot (snapshot ~exited:"done" ())) ] @ Helpers.keys "r") in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "restart missing"
;;

let%test_unit "rejected input leaves a live shell interactive; startup failures remain restartable" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t [ Terminal (Snapshot (snapshot ())); Terminal (Failed "input queue full") ] in
  assert (Option.is_some (Frame.render t ~width ~height).cursor);
  let t = run t [ key Enter ] in
  let t, requests = take t in
  requests_equal requests [ Key { code = Enter; modifiers = M.no_modifiers } ];
  let t = run t [ Terminal (Snapshot (snapshot ())) ] in
  assert (Option.is_none (U.terminal_failure t));
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t ([ U.Input.Terminal (Failed "forkpty failed") ] @ Helpers.keys "r") in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "failed startup cannot restart"
;;

let%test_unit "old generation snapshots and failures cannot replace a restarted shell" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let old_generation = U.terminal_generation t in
  let update generation event : U.Input.t = Terminal_update { generation; event } in
  let t = run t ([ update old_generation (Snapshot (snapshot ~exited:"done" ())) ]
                 @ Helpers.keys "r") |> take |> fst in
  let generation = U.terminal_generation t in
  assert (generation = old_generation + 1);
  let t = run t [ update old_generation (Snapshot (snapshot ()))
                ; update old_generation (Snapshot (snapshot ~exited:"done" ()))
                ; update old_generation (Failed "old failure") ] in
  assert (Option.is_none (U.terminal_snapshot t));
  assert (Option.is_none (U.terminal_failure t));
  let t = run t [ update generation (Snapshot (snapshot ())); key Enter ] in
  assert (Option.is_some (U.terminal_snapshot t));
  let _, requests = take t in
  requests_equal requests [ Key { code = Enter; modifiers = M.no_modifiers } ]
;;

let%test_unit "pasted control-M preserves CRLF for backend normalization; exit invalidates paste" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t [ Paste_start; key (Char (Uchar.of_char 'a')); ctrl 'M'; key Enter
                ; key (Char (Uchar.of_char 'b')); Paste_end ] in
  let t, requests = take t in
  requests_equal requests [ Paste "a\r\nb" ];
  let t = run t [ Paste_start; key (Char (Uchar.of_char 'x'))
                ; Terminal (Snapshot (snapshot ~exited:"done" ())); Paste_end ] in
  let _, requests = take t in
  requests_equal requests []
;;

let%test_unit "styled wide and combining cells use float compositor and child cursor" =
  let t = open_terminal (Helpers.ui "document") in
  let t = run t [ Terminal (Snapshot (snapshot ())) ] in
  let frame = Frame.render t ~width ~height in
  let layout = U.terminal_layout t ~width ~height |> Option.value_exn in
  let row = List.nth_exn frame.rows layout.content.y in
  assert (List.exists row ~f:(fun span ->
    Style.equal span.Span.style (Terminal style) && String.is_substring span.text ~substring:"界á"));
  let cursor = Option.value_exn frame.cursor in
  [%test_eq: int * int] (cursor.x, cursor.y) (layout.content.x + 2, layout.content.y);
  List.iter frame.rows ~f:(fun row -> [%test_eq: int] (Span.total_width row) width);
  let t = run t [ Terminal (Snapshot (snapshot ~exited:"done" ())) ] in
  assert (Option.is_some (Frame.render t ~width ~height).cursor);
  assert (Option.is_some (U.terminal_inspection t))
;;

let%test_unit "directory input supplies cwd; unfit open stays lazy" =
  let root = Helpers.scratch_dir "ches-terminal-cwd-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let t = U.show_directory (Helpers.ui "x") ~width ~height root |> Or_error.ok_exn in
    let t = Helpers.run ~width:10 ~height:3 t (Helpers.keys " /") in
    assert (not (U.terminal_capturing t));
    let t, requests = take t in
    requests_equal requests [];
    let t = open_terminal t in
    let t, requests = take t in
    (match requests with
     | [ Start { cwd; _ } ] -> [%test_eq: string] cwd root
     | _ -> failwith "directory terminal did not start");
    let t = hide t in
    assert (Option.is_some (Ches_app.Session.input_directory (U.session t)));
    Ches_app.Session.dispose (U.session t))
;;

let%test_unit "palette exposes Toggle Tile Term with default shortcut" =
  let t = run (Helpers.ui "x") (Helpers.keys " cctoggle tile term<CR>") in
  assert (U.terminal_capturing t);
  assert (Option.is_none (U.palette t));
  let entry = Ches_palette.Catalog.find Ches_palette.Catalog.default
      (Ches_palette.Catalog.Id.of_string "terminal.toggle") |> Option.value_exn in
  let sequences = Ches_palette.Shortcut.sequences
      (Ches_input.Bindings.to_list Ches_input.Bindings.default)
      (Ches_palette.Catalog.Entry.action entry) in
  [%test_eq: string list] (List.map sequences ~f:Ches_palette.Shortcut.to_string_hum) [ "Space /" ]
;;

let%test_unit "old Space tt binding no longer opens a terminal" =
  let t = run (Helpers.ui "document") (Helpers.keys " tt") in
  assert (not (U.terminal_visible t));
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "paste overflow is dropped as a whole and collection ends cleanly" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t [ Paste_start ] in
  let input = key (Char (Uchar.of_scalar_exn 0x1f642)) in
  let t = ref t in
  for _ = 1 to (1024 * 1024 / 4) + 1 do
    t := run !t [ input ]
  done;
  assert (U.pasting !t);
  let t = run !t [ ctrl '\\'; ctrl 'n'; Paste_end ] in
  assert (not (U.pasting t));
  assert (U.terminal_capturing t);
  let _, requests = take t in
  requests_equal requests []
;;

module T = Ches_tile.Text_view
let inspection t = U.terminal_inspection t |> Option.value_exn
let text_view t = Terminal_tile.inspection_text (inspection t)
let cursor_byte t = T.cursor (text_view t)
let normal t = run t [ ctrl ' ' ]
let type_ t s = run t (Helpers.keys s)
let editor t = Ches_app.Controller.editor (U.controller t)
let check_copy t ~kind expected =
  let t, clipboard = U.take_clipboard t in
  [%test_eq: string option] clipboard (Some expected);
  let register = Ches_core.Editor.unnamed_register (editor t) |> Option.value_exn in
  assert (Ches_core.Register.equal register (Text { text = expected; kind }));
  t
;;

let screen lines : M.snapshot =
  let rows = Array.of_list_map lines ~f:(fun line ->
    let glyphs = Cell_map.glyphs line |> Array.filter ~f:(fun g -> g.width > 0) in
    Array.mapi glyphs ~f:(fun i glyph ->
      let stop = if i + 1 < Array.length glyphs then glyphs.(i + 1).pos else String.length line in
      let text = String.sub line ~pos:glyph.pos ~len:(stop - glyph.pos) in
      let c : M.cell = { text; width = glyph.width; style } in
      if glyph.width = 2 then [ c; { c with text = ""; width = 0 } ] else [ c ])
    |> Array.to_list |> List.concat |> Array.of_list) in
  { rows; cursor_row = 0; cursor_col = 0; cursor_visible = true; exited = None }
;;

let inspecting lines =
  let t = open_terminal (Helpers.ui "unchanged document") |> take |> fst in
  run t [ Terminal (Snapshot (screen lines)) ] |> normal
;;

let%test_unit "full fidelity terminal events drive read-only motions and pending Escape" =
  let t = inspecting [ "one two"; "three!!"; "lastrow" ] in
  (* Exercise the real frontend event path rather than generic Key compatibility. *)
  let chars s = String.to_list s |> List.map ~f:(fun c -> key (Char (Uchar.of_char c))) in
  let at t keys expected =
    let t = run t (chars keys) in
    [%test_eq: int] (cursor_byte t) expected; t in
  let t = at t "l" 1 |> fun t -> at t "h" 0 in
  let t = at t "w" 4 |> fun t -> at t "b" 0 in
  let t = at t "$" 6 |> fun t -> at t "0" 0 in
  let t = at t "j" 8 |> fun t -> at t "k" 0 in
  let t = at t "G" 16 |> fun t -> at t "gg" 0 in
  let t = at t "2j" 16 |> fun t -> at t "gg" 0 in
  let t = run t [ key Down; key Right; key Home; key Up ] in
  [%test_eq: int] (cursor_byte t) 0;
  let t = run t (chars "g" @ [ key Escape ] @ chars "g") in
  [%test_eq: int] (cursor_byte t) 0;
  (* The second g is still pending; Escape cancels it and the next motion works. *)
  let t = run t ([ key Escape ] @ chars "j") in
  [%test_eq: int] (cursor_byte t) 8;
  let t = run t (chars "vlg" @ [ key Escape ]) in
  assert (Option.is_none (T.visual (text_view t)));
  let t = run t (chars "xdpu~") in
  [%test_eq: string] (Ches_core.Text_buffer.to_string (Ches_core.Editor.text (editor t))) "unchanged document";
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "Unicode inclusive multiline selection highlights and shares yank destinations" =
  let t = inspecting [ "界áz"; "xy!!" ] in
  let t = type_ t "vlj" in
  [%test_eq: (int * int) option] (T.selection (text_view t)) (Some (0, 11));
  let frame = Frame.render t ~width ~height in
  let selected = List.concat_map frame.rows ~f:(fun row ->
    List.filter_map row ~f:(fun span ->
      Option.some_if (Style.equal span.Span.style (Style.document ~overlay:Selection ())) span.text)) in
  [%test_eq: string] (String.concat selected) "界ázxy!";
  (* The unselected final cell keeps the shell's original attributes. *)
  assert (List.exists (List.concat frame.rows) ~f:(fun span ->
    Style.equal span.Span.style (Terminal style) && String.equal span.text "!"));
  assert (Option.is_some frame.cursor);
  let t = type_ t "y" |> fun t -> check_copy t ~kind:Characterwise "界áz\nxy!" in
  assert (Option.is_none (T.visual (text_view t)));
  [%test_eq: int] (cursor_byte t) 0;
  let t = type_ t "Vjy" |> fun t -> check_copy t ~kind:Linewise "界áz\nxy!!\n" in
  let t = type_ t "yy" |> fun t -> check_copy t ~kind:Linewise "界áz\n" in
  let t = type_ t "lvly" |> fun t -> check_copy t ~kind:Characterwise "áz" in
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "inspection freezes output and selections; Insert resumes newest screen; reopen is Insert" =
  let original = screen [ "original"; "row two!" ] in
  let latest = screen [ "updated!"; "new row!" ] in
  let t = open_terminal (Helpers.ui "document") |> take |> fst in
  let t = run t [ Terminal (Snapshot original) ] |> normal |> fun t -> type_ t "vll" in
  let before = Frame.render t ~width ~height in
  let t = run t [ Terminal (Snapshot latest) ] in
  [%test_eq: string] (T.text (text_view t)) "original\nrow two!";
  assert (Option.is_some (T.visual (text_view t)));
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some latest));
  [%test_eq: string] (Frame.to_string (Frame.render t ~width ~height)) (Frame.to_string before);
  let t = type_ t "y" |> fun t -> check_copy t ~kind:Characterwise "ori" in
  let t = type_ t "a" in
  assert (Option.is_none (U.terminal_inspection t));
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"updated!");
  let t = normal t |> fun t -> type_ t "vll /" in
  assert (not (U.terminal_visible t));
  let t = open_terminal t in
  assert (Option.is_none (U.terminal_inspection t));
  let t = run t [ key Escape; ctrl '\\' ] in
  let _, requests = take t in
  requests_equal requests [ Key { code = Escape; modifiers = M.no_modifiers }
                          ; Key { code = Char (Uchar.of_char '\\'); modifiers = { M.no_modifiers with ctrl = true } } ]
;;

let%test_unit "Normal and Visual pastes are drained without execution or mode changes" =
  List.iter [ ""; "vll"; "<C-v>ll" ] ~f:(fun selection ->
    let t = inspecting [ "screen" ] |> fun t -> type_ t selection in
    let visual = T.visual (text_view t) in
    let block = Terminal_tile.block_selection (inspection t) in
    let t = run t ([ U.Input.Paste_start; ctrl ' '; key Escape ] @ Helpers.keys "i /ryy" @ [ U.Input.Paste_end ]) in
    assert (U.terminal_visible t);
    assert (Option.equal T.Kind.equal (T.visual (text_view t)) visual);
    assert (Option.equal Terminal_tile.equal_block_selection
      (Terminal_tile.block_selection (inspection t)) block);
    [%test_eq: string] (T.text (text_view t)) "screen";
    let t, copied = U.take_clipboard t in
    assert (Option.is_none copied);
    assert (not (U.pasting t));
    let _, requests = take t in requests_equal requests [])
;;

let%test_unit "all Ctrl-Space encodings reset Visual and pending input without shell requests" =
  List.iter [ ctrl ' '; ctrl '@'; key (Char (Uchar.of_scalar_exn 0)); ctrl '\000' ] ~f:(fun enter_normal ->
    let t = inspecting [ "abcdef" ] |> fun t -> type_ t "<C-v>lg" in
    let t = run t [ enter_normal ] in
    assert (Option.is_none (T.visual (text_view t)));
    assert (Option.is_none (Terminal_tile.block_selection (inspection t)));
    let t = type_ t "g" in
    [%test_eq: int] (cursor_byte t) 1;
    let _, requests = take t in requests_equal requests [])
;;

let%test_unit "inspection starts on leading cell of wide glyph and empty screens stay usable" =
  let s = { (snapshot ()) with cursor_col = 1 } in
  let t = open_terminal (Helpers.ui "document") |> take |> fst in
  let t = run t [ Terminal (Snapshot s) ] |> normal in
  [%test_eq: int] (cursor_byte t) 0;
  let t = type_ t "vy" |> fun t -> check_copy t ~kind:Characterwise "界" in
  let t = type_ t "i" in
  let t = run t [ Terminal (Snapshot (screen [])) ] |> normal in
  let t = type_ t "ggG0$vyy" in
  assert (Option.is_some (Frame.render t ~width ~height).cursor);
  let t = type_ t " /" in
  assert (not (U.terminal_visible t));
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "frozen grid survives resize without reflow or selection loss and keeps cursor visible" =
  let line = String.init 70 ~f:(fun n -> Char.of_int_exn (Char.to_int 'a' + n % 26)) in
  let t = inspecting [ line; line; line; line; line; line ] |> fun t -> type_ t "G$vkk" in
  let selected = T.selection (text_view t) in
  let t = Helpers.run ~width:30 ~height:10 t [ Resize ] in
  [%test_eq: (int * int) option] (T.selection (text_view t)) selected;
  let frame = Frame.render t ~width:30 ~height:10 in
  let cursor = Option.value_exn frame.cursor in
  let layout = U.terminal_layout t ~width:30 ~height:10 |> Option.value_exn in
  assert (cursor.x >= layout.content.x && cursor.x < layout.content.x + layout.content.width);
  assert (cursor.y >= layout.content.y && cursor.y < layout.content.y + layout.content.height);
  List.iter frame.rows ~f:(fun row -> [%test_eq: int] (Span.total_width row) 30);
  let t = Helpers.run ~width:width ~height:height t [ Resize ] in
  [%test_eq: (int * int) option] (T.selection (text_view t)) selected;
  let t = type_ t "<Esc>ggyy" |> fun t -> check_copy t ~kind:Linewise (line ^ "\n") in
  let t, _ = take t in
  let t = type_ t "i" in
  assert (Option.is_none (U.terminal_inspection t));
  let _, requests = take t in requests_equal requests []
;;

let check_block_copy t ~rows ~width =
  let t, clipboard = U.take_clipboard t in
  [%test_eq: string option] clipboard (Some (String.concat ~sep:"\n" rows));
  let register = Ches_core.Editor.unnamed_register (editor t) |> Option.value_exn in
  assert (Ches_core.Register.equal register (Block { rows; width }));
  assert (Option.is_none (Terminal_tile.block_selection (inspection t)));
  assert (Option.is_none (T.visual (text_view t)));
  t
;;

let%test_unit "terminal block selection copies wide glyphs and combining marks atomically" =
  let t = inspecting [ "abcd"; "界áx"; "🙂!yz" ] in
  (* Both left-hand wide glyphs straddle the nominal rectangle's left edge.
     They must remain whole, in both highlighting and copied bytes. *)
  let t = type_ t "l<C-v>ljj" in
  let b = Terminal_tile.block_selection (inspection t) |> Option.value_exn in
  [%test_eq: int * int * int * int] (b.first_row, b.last_row, b.left, b.right) (0, 2, 1, 3);
  let frame = Frame.render t ~width ~height in
  let highlighted = List.concat_map frame.rows ~f:(fun row ->
    List.filter_map row ~f:(fun span ->
      Option.some_if (Style.equal span.Span.style (Style.document ~overlay:Selection ())) span.text)) in
  [%test_eq: string] (String.concat highlighted) "bc界á🙂!";
  assert (String.is_substring (Frame.to_string frame) ~substring:"VISUAL BLOCK");
  List.iter [ "d"; "x"; "yz" ] ~f:(fun unselected ->
    assert (List.exists (List.concat frame.rows) ~f:(fun span ->
      Style.equal span.Span.style (Terminal style) && String.equal span.text unselected)));
  let t = type_ t "y" |> fun t -> check_block_copy t ~rows:[ "bc"; "界á"; "🙂!" ] ~width:3 in
  [%test_eq: int] (cursor_byte t) 1;
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "block mode preserves endpoints when switching kind, swapping and cancelling" =
  let start () = inspecting [ "abcd"; "efgh" ] |> fun t -> type_ t "l<C-v>lj" in
  let t = start () in
  let b = Terminal_tile.block_selection (inspection t) in
  let t = type_ t "o" in
  [%test_eq: int] (cursor_byte t) 1;
  assert (Option.equal Terminal_tile.equal_block_selection (Terminal_tile.block_selection (inspection t)) b);
  let t = type_ t "oy" |> fun t -> check_block_copy t ~rows:[ "bc"; "fg" ] ~width:2 in
  let t = type_ t "<C-v><C-v>" in
  assert (Option.is_none (T.visual (text_view t)));
  assert (Option.is_none (Terminal_tile.block_selection (inspection t)));
  let t = start () |> fun t -> type_ t "vy" |> fun t -> check_copy t ~kind:Characterwise "bcd\nefg" in
  assert (Option.is_none (Terminal_tile.block_selection (inspection t)));
  let t = start () |> fun t -> type_ t "Vy" |> fun t -> check_copy t ~kind:Linewise "abcd\nefgh\n" in
  let t = type_ t "vlj<C-v>Y" |> fun t -> check_block_copy t ~rows:[ "bc"; "fg" ] ~width:2 in
  let t = type_ t "<C-v>jg<Esc>" in
  assert (Option.is_none (T.visual (text_view t)));
  assert (Option.is_none (Terminal_tile.block_selection (inspection t)));
  let _, requests = take t in requests_equal requests []
;;

let%test_unit "block selection freezes with background updates and resize; its register pastes as a block" =
  let t = open_terminal (Helpers.ui "first\nsecond") |> take |> fst in
  let t = run t [ Terminal (Snapshot (screen [ "abcd"; "efgh" ])) ] |> normal in
  (* Use full-fidelity frontend events for entering block and moving. *)
  let t = run t [ ctrl 'v'; key Right; key Down ] in
  let b = Terminal_tile.block_selection (inspection t) in
  let before = Frame.to_string (Frame.render t ~width ~height) in
  let t = run t [ Terminal (Snapshot (screen [ "new!"; "data" ])) ] in
  [%test_eq: string] (Frame.to_string (Frame.render t ~width ~height)) before;
  let t = Helpers.run ~width:30 ~height:10 t [ Resize ] in
  assert (Option.equal Terminal_tile.equal_block_selection (Terminal_tile.block_selection (inspection t)) b);
  let frame = Frame.render t ~width:30 ~height:10 in
  assert (Option.is_some frame.cursor);
  List.iter frame.rows ~f:(fun row -> [%test_eq: int] (Span.total_width row) 30);
  let t = run t [ Resize ] |> fun t -> type_ t "y" in
  let t = check_block_copy t ~rows:[ "ab"; "ef" ] ~width:2 in
  let t = type_ t " /ggP" in
  [%test_eq: string] (Ches_core.Text_buffer.to_string (Ches_core.Editor.text (editor t))) "abfirst\nefsecond";
  let t = open_terminal t in
  assert (Option.is_none (U.terminal_inspection t));
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"new!");
  let t, _ = take t in
  let t = normal t |> fun t -> type_ t "<C-v>llxdpu~" in
  [%test_eq: string] (Ches_core.Text_buffer.to_string (Ches_core.Editor.text (editor t))) "abfirst\nefsecond";
  let _, requests = take t in requests_equal requests []
;;

let select t n = type_ t (Int.to_string n ^ " /")
let routed = U.take_terminal_session_requests
let session_update terminal generation event : U.Input.t =
  Terminal_session_update { terminal; generation; event }
let routed_equal actual expected =
  if not (List.equal (fun (a, x) (b, y) -> a = b && M.equal_request x y) actual expected) then
    raise_s [%message "routed terminal requests differ"
      (actual : (int * M.request) list) (expected : (int * M.request) list)]
;;

let%test_unit "numbered selectors are lazy, toggle once, and reopen the most recent session" =
  let t = Helpers.ui "document" in
  [%test_eq: int] (U.terminal_number t) 1;
  let t = select t 3 in
  assert (U.terminal_visible t);
  [%test_eq: int] (U.terminal_number t) 3;
  [%test_eq: int list] (U.terminal_numbers t) [1; 3];
  let t, requests = routed t in
  (match requests with [3, Start _] -> () | _ -> failwith "count must select once");
  let t = normal t |> fun t -> select t 4 in
  let t, requests = routed t in
  (match requests with [4, Start _] -> () | _ -> failwith "four must have its own shell");
  assert (U.terminal_visible t);
  assert (Option.is_none (U.terminal_inspection t));
  let t = normal t |> fun t -> select t 4 in
  assert (not (U.terminal_visible t));
  let t = open_terminal t in
  [%test_eq: int] (U.terminal_number t) 4;
  let t = normal t |> fun t -> select t 98765 in
  [%test_eq: int list] (U.terminal_numbers t) [1; 3; 4; 98765];
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height))
    ~substring:"Tile Term 98765");
  let t = normal t |> fun t -> select t 3 in
  routed_equal (snd (routed t) |> List.filter ~f:(fun (n, _) -> n <> 98765)) [];
  assert (Option.is_none (U.terminal_inspection t))
;;

let%test_unit "background snapshots exits and stale generations remain session local" =
  let t = select (Helpers.ui "document") 3 |> routed |> fst in
  let generation3 = U.terminal_generation t in
  let t = run t [session_update 3 generation3 (Snapshot (screen ["shell three"]))] in
  let t = normal t |> fun t -> type_ t "vll" |> fun t -> select t 4 |> routed |> fst in
  let generation4 = U.terminal_generation t in
  assert (generation3 = generation4);
  let four = screen ["shell four"] in
  let t = run t [session_update 4 generation4 (Snapshot four)] |> normal in
  let before = Frame.to_string (Frame.render t ~width ~height) in
  let dead3 = { (screen ["three done"]) with exited = Some "exit 3" } in
  let t = run t [session_update 3 generation3 (Snapshot dead3)
                ; session_update 999 1 (Failed "unknown")] in
  [%test_eq: string] (Frame.to_string (Frame.render t ~width ~height)) before;
  [%test_eq: int list] (U.terminal_numbers t) [1; 3; 4];
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some four));
  let t = select t 3 in
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some dead3));
  assert (Option.is_some (U.terminal_inspection t));
  let t = type_ t "r" |> routed |> fst in
  [%test_eq: int] (U.terminal_generation t) (generation3 + 1);
  let t = normal t |> fun t -> select t 4 in
  let t = run t [session_update 3 generation3 (Failed "old failure")
                ; session_update 3 generation3 (Snapshot dead3)] in
  let t = normal t |> fun t -> select t 3 in
  assert (Option.is_none (U.terminal_snapshot t));
  assert (Option.is_none (U.terminal_failure t));
  assert (Option.is_none (U.terminal_inspection t));
  let t = run t [session_update 3 (generation3 + 1) (Failed "new failure")] in
  assert (Option.is_some (U.terminal_inspection t));
  let t = select t 4 in
  assert (Option.is_none (U.terminal_failure t));
  assert (Option.equal M.equal_snapshot (U.terminal_snapshot t) (Some four));
  [%test_eq: int] (U.terminal_generation t) generation4
;;

let%test_unit "requests retain enqueue owner through switches and paste lifecycle" =
  let t = select (Helpers.ui "document") 3 |> routed |> fst in
  let t = run t [timed 0 'j'; ctrl ' '] |> fun t -> select t 4 in
  let t, requests = routed t in
  (match requests with
   | [3, request; 4, Start _] -> requests_equal [request] [j_request]
   | _ -> failwith "outgoing j was not routed before new shell start");
  let t = run t [Paste_start; timed 20 'a'
                ; session_update 3 1 (Snapshot (snapshot ~exited:"done" ()))
                ; Paste_end] in
  let t, requests = routed t in
  routed_equal requests [4, Paste "a"];
  let t = run t [timed 30 'j'; tick 180; tick 500] |> normal |> fun t -> select t 3 in
  let t, requests = routed t in
  routed_equal requests [4, j_request];
  let t = type_ t "r" |> routed |> fst in
  let t = run t [Paste_start; timed 600 'x'] in
  let t = Helpers.run ~width:10 ~height:3 t [Resize] in
  let t = run t [Paste_end] |> fun t -> select t 4 in
  let t, requests = routed t in
  routed_equal requests [];
  assert (U.terminal_visible t);
  assert (not (U.pasting t))
;;

let%test_unit "numbered sessions keep independent preferred sizes and hidden sizing targets selected ID" =
  let big t s = Helpers.run ~width:240 ~height:80 t (Helpers.keys s) in
  let normal t = Helpers.run ~width:240 ~height:80 t [ctrl ' '] in
  let size t =
    let l = U.terminal_layout t ~width:240 ~height:80 |> Option.value_exn in
    l.outer.width, l.outer.height in
  let t = big (Helpers.ui "document") "3 /" |> routed |> fst in
  let t = big (normal t) "3+" in
  [%test_eq: int * int] (size t) (162, 46);
  let t = big t "v4 /" in
  [%test_eq: int * int] (size t) (132, 40);
  assert (Option.is_none (U.terminal_inspection t));
  let t = big (normal t) " /2 t-" |> routed |> fst in
  assert (not (U.terminal_visible t));
  let t = big t " /" in
  [%test_eq: int * int] (size t) (112, 36);
  let t = big (normal t) "3 /" in
  [%test_eq: int * int] (size t) (162, 46);
  let t = big (normal t) " tr4 /" in
  [%test_eq: int * int] (size t) (112, 36)
;;

let%test_unit "toggle count scales to selector, explicit selectors never repeat" =
  let module V = Ches_input.View_command in
  assert (Option.equal V.equal (V.scale Toggle_terminal ~count:4) (Some (Select_terminal 4)));
  assert (Option.is_none (V.scale (Select_terminal 3) ~count:4));
  let t = type_ (Helpers.ui "document") (Int.to_string (Ches_core.Command.max_count + 1)) in
  assert (not (U.terminal_visible t));
  routed_equal (snd (routed t)) []
;;

let%test_unit "each session captures its first cwd and restart retains it after editor context changes" =
  let root = Helpers.scratch_dir "ches-numbered-terminal-cwd-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let t = select (Helpers.ui ~path:"/tmp/project/file.ml" "document") 3 in
    let t, requests = routed t in
    (match requests with
     | [3, Start {cwd; _}] -> [%test_eq: string] cwd "/tmp/project"
     | _ -> failwith "session 3 initial cwd missing");
    let t = hide t in
    let t = U.show_directory t ~width ~height root |> Or_error.ok_exn in
    let t = select t 4 in
    let t, requests = routed t in
    (match requests with
     | [4, Start {cwd; _}] -> [%test_eq: string] cwd root
     | _ -> failwith "session 4 initial cwd missing");
    let t = run t [session_update 3 1 (Snapshot (snapshot ~exited:"done" ()))] in
    let t = normal t |> fun t -> select t 3 |> fun t -> type_ t "r" in
    let _, requests = routed t in
    (match requests with
     | [3, Start {cwd; _}] -> [%test_eq: string] cwd "/tmp/project"
     | _ -> failwith "restart lost captured cwd");
    Ches_app.Session.dispose (U.session t))
;;

let%test_unit "inactive events cannot flush current pending j and resizes target the selected session" =
  let t = select (Helpers.ui "document") 3 |> routed |> fst in
  let t = normal t |> fun t -> select t 4 |> routed |> fst in
  let t = run t [timed 0 'j'; session_update 3 1 (Failed "inactive failure"); timed 10 'k'] in
  assert (Option.is_some (U.terminal_inspection t));
  routed_equal (snd (routed t)) [];
  let t = Helpers.run ~width:60 ~height:16 t [Resize] in
  let l = U.terminal_layout t ~width:60 ~height:16 |> Option.value_exn in
  let t, requests = routed t in
  routed_equal requests [4, Resize {rows = l.content.height; cols = l.content.width}];
  let t = Helpers.run ~width:60 ~height:16 t (Helpers.keys "3 /") in
  assert (Option.is_some (U.terminal_failure t));
  assert (Option.is_some (U.terminal_inspection t));
  routed_equal (snd (routed t)) []
;;

let%test_unit "explicit invalid IDs do not launch; arbitrary positive integer IDs allocate no range" =
  let module I = Ches_input in
  let bindings = I.Bindings.create
      [ [I.Key.char 'x'], View (Select_terminal 0)
      ; [I.Key.char 'y'], View (Select_terminal (-1))
      ; [I.Key.char 'z'], View (Select_terminal Int.max_value)
      ; [I.Key.char ' '; I.Key.char '/'], View Toggle_terminal ] |> Or_error.ok_exn in
  let keymap_config = { I.Keymap.Config.default with normal = bindings } in
  let text = Ches_core.Text_buffer.of_string "document"
      |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
      |> Result.ok_or_failwith in
  let editor = Ches_core.Editor.create ~path:"/tmp/file.ml" ~cell_width:Cell_map.width text in
  let t = U.create ~tiles_visible:false (Ches_app.Controller.create ~keymap_config editor) in
  let t = type_ t "xy" in
  assert (not (U.terminal_visible t));
  [%test_eq: int] (U.terminal_number t) 1;
  [%test_eq: int list] (U.terminal_numbers t) [1];
  routed_equal (snd (routed t)) [];
  let t = type_ t "z" in
  [%test_eq: int] (U.terminal_number t) Int.max_value;
  [%test_eq: int list] (U.terminal_numbers t) [1; Int.max_value];
  (match snd (routed t) with
   | [n, Start _] -> assert (n = Int.max_value)
   | _ -> failwith "arbitrary positive ID must start exactly one shell")
;;
