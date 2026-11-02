open! Core
open Ches_screen
module M = Ches_terminal.Model
module U = Ui_state

let width = 80
let height = 24
let run t inputs = Helpers.run ~width ~height t inputs
let open_terminal t = run t (Helpers.keys " tt")
let key ?(modifiers = M.no_modifiers) code : U.Input.t = Terminal_key { M.code; modifiers }
let ctrl c = key ~modifiers:{ M.no_modifiers with ctrl = true } (Char (Uchar.of_char c))
let hide t = run t [ ctrl '\\'; ctrl 'n' ]
let take = U.take_terminal_requests
let requests_equal a b =
  if not (List.equal M.equal_request a b) then
    raise_s [%message "terminal requests differ" (a : M.request list) (b : M.request list)]
let style : M.style =
  { fg = Indexed 2; bg = Rgb (10, 20, 30); bold = true; italic = true
  ; underline = true; reverse = true }
let snapshot ?exited () : M.snapshot =
  { rows = [| [| { M.text = "界"; width = 2; style }
               ; { M.text = ""; width = 0; style }
               ; { M.text = "á"; width = 1; style } |] |]
  ; cursor_row = 0; cursor_col = 2; cursor_visible = true; exited }

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

let%test_unit "full fidelity keys bypass editor; prefix misses are forwarded in order" =
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
  let t = run t [ key Enter; ctrl '\\'; ctrl 'r' ] in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "explicit restart missing"
;;

let%test_unit "Notty uppercase control letters operate hide and restart prefixes" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let t = run t [ ctrl '\\'; ctrl 'N' ] in
  assert (not (U.terminal_visible t));
  let t = open_terminal t in
  let t = run t [ Terminal (Snapshot (snapshot ~exited:"done" ())); ctrl '\\'; ctrl 'R' ] in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "uppercase restart missing"
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
  let t = run t [ Terminal (Failed "forkpty failed"); ctrl '\\'; ctrl 'R' ] in
  let _, requests = take t in
  match requests with [ Start _ ] -> () | _ -> failwith "failed startup cannot restart"
;;

let%test_unit "old generation snapshots and failures cannot replace a restarted shell" =
  let t = open_terminal (Helpers.ui "x") |> take |> fst in
  let old_generation = U.terminal_generation t in
  let update generation event : U.Input.t = Terminal_update { generation; event } in
  let t = run t [ update old_generation (Snapshot (snapshot ~exited:"done" ()))
                ; ctrl '\\'; ctrl 'R' ] |> take |> fst in
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
  assert (Option.is_none (Frame.render t ~width ~height).cursor)
;;

let%test_unit "directory input supplies cwd; unfit open stays lazy" =
  let root = Helpers.scratch_dir "ches-terminal-cwd-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let t = U.show_directory (Helpers.ui "x") ~width ~height root |> Or_error.ok_exn in
    let t = Helpers.run ~width:10 ~height:3 t (Helpers.keys " tt") in
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

let%test_unit "palette exposes toggle terminal with default shortcut" =
  let t = run (Helpers.ui "x") (Helpers.keys " cctoggle terminal<CR>") in
  assert (U.terminal_capturing t);
  assert (Option.is_none (U.palette t));
  let entry = Ches_palette.Catalog.find Ches_palette.Catalog.default
      (Ches_palette.Catalog.Id.of_string "terminal.toggle") |> Option.value_exn in
  let sequences = Ches_palette.Shortcut.sequences
      (Ches_input.Bindings.to_list Ches_input.Bindings.default)
      (Ches_palette.Catalog.Entry.action entry) in
  [%test_eq: string list] (List.map sequences ~f:Ches_palette.Shortcut.to_string_hum) [ "Space t t" ]
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
