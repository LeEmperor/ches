open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers

let width = 100
let height = 24
let run ui s = Helpers.run ~width ~height ui (keys s)
let dir ui = Session.directory_buffer (Ui_state.session ui) |> Option.value_exn
let presentation ui = Session.directory_presentation (Ui_state.session ui) |> Option.value_exn
let focused ui = Ui_state.focused_view ui ~width ~height
let editor ui = Controller.editor (Ui_state.controller ui)
let files ui = List.map (Session.buffers (Ui_state.session ui)) ~f:(fun (_, c) ->
  Filename.basename (Option.value_exn (Editor.path (Controller.editor c))))

let fixture f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-side-test-" in
  let names = [ "a.txt"; "b.txt"; "bad.txt" ] @ List.init 40 ~f:(fun i -> sprintf "z%02d.txt" i) in
  List.iter names ~f:(fun name -> Out_channel.write_all (Filename.concat root name)
    ~data:(if String.equal name "bad.txt" then "\000" else "one\ntwo\nthree\n"));
  Core_unix.mkdir (Filename.concat root "child");
  Exn.protect ~f:(fun () -> f root) ~finally:(fun () ->
    List.iter names ~f:(fun name -> Core_unix.unlink (Filename.concat root name));
    Core_unix.rmdir (Filename.concat root "child"); Core_unix.rmdir root)
;;

let create root = Ui_state.create ~tiles_visible:false
  (Startup.open_path ~cell_width:Cell_map.width root |> Or_error.ok_exn)
let assert_frame ui ~width ~height =
  let frame = Frame.render ui ~width ~height in
  assert (List.length frame.rows = Int.max 0 height);
  List.iter frame.rows ~f:(fun row ->
    assert (Span.total_width row = Int.max 0 width);
    List.iter row ~f:(fun span -> assert (Cell_map.total_width (Cell_map.glyphs span.Span.text) = span.width)));
  Option.iter frame.cursor ~f:(fun c -> assert (c.x >= 0 && c.x < width && c.y >= 0 && c.y < height))
;;

let%test_unit "side allocation is contained, nonoverlapping, clamped and restores preference" =
  let id = Ui_state.directory_id in
  List.iter (List.range 0 85) ~f:(fun width -> List.iter (List.range 0 20) ~f:(fun height ->
    List.iter [ -10; 16; 32; 500 ] ~f:(fun preferred ->
      let allocation = { Geometry.Rect.x = 7; y = 11; width; height } in
      let w = Workspace.allocate ~side:(id, preferred) ~minors:[ History_tile.id; Problems_tile.id ]
        { Workspace.Prefs.default with status_visible = true } ~allocation in
      let panes = w.document :: Option.to_list w.status @ w.minors in
      List.iter panes ~f:(fun p ->
        assert (p.rect.x >= 7 && p.rect.y >= 11 && p.rect.width >= 0 && p.rect.height >= 0);
        assert (p.rect.x + p.rect.width <= 7 + width && p.rect.y + p.rect.height <= 11 + height));
      List.iteri panes ~f:(fun i a -> List.iter (List.drop panes (i + 1)) ~f:(fun b ->
        assert (a.rect.x + a.rect.width <= b.rect.x || b.rect.x + b.rect.width <= a.rect.x
          || a.rect.y + a.rect.height <= b.rect.y || b.rect.y + b.rect.height <= a.rect.y)));
      match Workspace.minor w id with
      | None -> assert (width < 33 || height < 4)
      | Some p -> assert (p.rect.width = Int.clamp_exn preferred ~min:16 ~max:(width - 17)))));
  let allocate width = Workspace.allocate ~side:(id, 40) Workspace.Prefs.default
    ~allocation:{ Geometry.Rect.x = 0; y = 0; width; height = 12 } in
  assert ((Workspace.minor (allocate 100) id |> Option.value_exn).rect.width = 40);
  assert (Option.is_none (Workspace.minor (allocate 32) id));
  assert ((Workspace.minor (allocate 100) id |> Option.value_exn).rect.width = 40)
;;

let%test_unit "side opens keep browser and target group; tabs and editor input stay in editor" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR>" in
    let p = presentation ui in
    assert (Poly.equal p.placement Side && Group_id.equal p.target_group (Session.group_id (Ui_state.session ui)));
    assert (List.equal String.equal (files ui) [ "a.txt" ]);
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    assert (Option.is_none (Session.input_directory (Ui_state.session ui)));
    assert (Option.is_some (Ui_state.side_layout ui ~width ~height));
    let rendered = Frame.to_string (Frame.render ui ~width ~height) in
    assert (String.is_substring rendered ~substring:"Directory");
    assert (String.is_substring rendered ~substring:"0 marked");
    assert (String.is_substring rendered ~substring:"@ches[");
    assert (String.is_substring rendered ~substring:"one");
    let frame = Frame.render ui ~width ~height in
    List.iter frame.rows ~f:(fun row ->
      let plain = String.concat (List.map row ~f:(fun span -> span.Span.text)) in
      let glyphs = Cell_map.glyphs plain in
      assert (Array.exists glyphs ~f:(fun glyph -> glyph.col = 32 && String.equal glyph.text " ")));
    let ui = run ui "iX<Esc> dfj<CR>" in
    assert (List.equal String.equal (files ui) [ "a.txt"; "b.txt" ]);
    assert (Buffer_id.equal p.buffer (presentation ui).buffer && Group_id.equal p.target_group (presentation ui).target_group);
    let ui = run ui " bpiY<Esc>" in
    assert (String.is_prefix (Text_buffer.to_string (Editor.text (editor ui))) ~prefix:"YX");
    let ui = run ui " o" in
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.directory_id);
    assert (String.equal (Directory_buffer.selected (dir ui) |> Option.value_exn).name "a.txt");
    let ui = run ui "<Tab>" in
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    assert_frame ui ~width ~height;
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "side Insert Tab edits text; Normal Tab returns focus" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR> df" in
    let before = Editor.text (editor ui) |> Text_buffer.to_string in
    let ui = run ui "A<Tab>" in
    assert (Mode.equal (Editor.mode (editor ui)) Insert);
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.directory_id);
    assert (not (String.equal before (Text_buffer.to_string (Editor.text (editor ui)))));
    let ui = run ui "<Esc>u<Tab>" in
    assert (String.equal before (Text_buffer.to_string (Editor.text (Controller.editor (dir ui).controller))));
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "placement and hiding retain controller, selection, scroll and marks" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui "<CR> o25j mmVj" in
    let d = dir ui in
    let selection = Editor.selection (editor ui) in
    let top = (Ui_state.scroll ui).top in
    assert (top > 0);
    let ui = run ui " ds dm ds" in
    assert (Buffer_id.equal d.id (dir ui).id);
    assert (Set.equal d.marks (dir ui).marks);
    assert (Poly.equal selection (Editor.selection (editor ui)));
    assert ((Ui_state.scroll ui).top > 0);
    let frame = Frame.render ui ~width ~height in
    let cursor = Option.value_exn frame.cursor in
    let x, y, _ = Ui_state.minor_cursor ui ~width ~height |> Option.value_exn in
    assert (cursor.x = x && cursor.y = y);
    let ui = run ui "<Esc> cc<Esc>" in
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.directory_id);
    (* Reestablish the same selection after testing palette focus restoration. *)
    let ui = run ui "Vk" in
    let selection = Editor.selection (editor ui) in
    let cursor = Editor.cursor (editor ui) in
    let scroll = Ui_state.scroll ui in
    let ui = run ui " dh ds" in
    assert (Poly.equal selection (Editor.selection (editor ui)));
    assert (Set.equal d.marks (dir ui).marks);
    assert (Editor.cursor (editor ui) = cursor);
    assert (Scroll.equal scroll (Ui_state.scroll ui));
    assert_frame ui ~width ~height;
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "side visual and marked batches share ordering, partial failures and clearing" =
  fixture (fun root ->
    List.iter [ "Vj"; "vj"; "<C-v>j" ] ~f:(fun selection ->
      let ui = create root |> fun ui -> run ui (" ds mm" ^ selection ^ "<CR>") in
      assert (List.equal String.equal (files ui) [ "a.txt"; "b.txt" ]);
      assert (Set.length (dir ui).marks = 1);
      assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    let ui = run ui " dfggV3j ms<Esc> mo" in
      assert (Set.length (dir ui).marks = 2);
      assert (List.equal String.equal (List.map (Directory_buffer.marked_entries (dir ui)) ~f:(fun e -> e.name)) [ "bad.txt"; "child" ]);
      assert (String.equal (Filename.basename (Option.value_exn (Editor.path (editor ui)))) "a.txt");
      assert (Option.exists (Ui_state.message ui) ~f:(fun m -> String.equal m.text "Batch open: 2 opened, 1 failed, 1 skipped"));
      assert_frame ui ~width ~height;
      Session.dispose (Ui_state.session ui)))
;;

let%test_unit "side navigation uses cached buffers and explicit return target" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR> df3j mm<CR>" in
    assert (String.equal (dir ui).path (Filename.concat root "child"));
    let ui = run ui "-" in
    assert (String.equal (Directory_buffer.selected (dir ui) |> Option.value_exn).name "child");
    assert (Set.length (dir ui).marks = 1);
    let ui = run ui " o" in
    assert (Option.is_some (Ui_state.side_layout ui ~width ~height));
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "zen and tiny resize suppress side safely, preserve state and restore requested width" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR> df mm d+ d+" in
    assert ((Ui_state.side_layout ui ~width ~height |> Option.value_exn).outer.width = 40);
    let id = (dir ui).id in
    let ui = run ui " vz" in
    assert (Option.is_none (Ui_state.side_layout ui ~width ~height));
    assert (Option.is_none (Session.input_directory (Ui_state.session ui)));
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    let ui = run ui " vz df" in
    assert (Set.length (dir ui).marks = 1 && Buffer_id.equal id (dir ui).id);
    let ui = Helpers.run ~width:8 ~height:2 ui [ Resize ] in
    assert (Option.is_none (Session.input_directory (Ui_state.session ui)));
    List.iter (List.range 0 65) ~f:(fun w -> List.iter (List.range 0 15) ~f:(fun h ->
      let resized = Helpers.run ~width:w ~height:h ui [ Resize ] in
      assert_frame resized ~width:w ~height:h));
    let ui = Helpers.run ~width ~height ui [ Resize ] in
    assert ((Ui_state.side_layout ui ~width ~height |> Option.value_exn).outer.width = 40);
    assert (Ches_tile.View_id.equal (focused ui) Ui_state.document_id);
    let ui = run ui " df dh" in
    assert (Option.is_none (Session.directory_presentation (Ui_state.session ui)));
    let ui = run ui " ds" in
    assert (Set.length (dir ui).marks = 1 && Buffer_id.equal id (dir ui).id);
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "side modal prefix, search, yank, paste ownership, palette and last-file fallback" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR> df/b.txt<CR> mmVy" in
    assert (Set.length (dir ui).marks = 1);
    let before = Text_buffer.to_string (Editor.text (editor ui)) in
    let ui = Helpers.run ~width ~height ui [ Paste_start ] in
    let ui = run ui "no" in
    let ui = Helpers.run ~width ~height ui [ Paste_end ] in
    assert (String.equal before (Text_buffer.to_string (Editor.text (editor ui))));
    let ui = run ui "<Tab>P" in
    assert (String.is_prefix (Text_buffer.to_string (Editor.text (editor ui))) ~prefix:"@ches[");
    let ui = run ui "u ccShow directory in main area<CR>" in
    assert (Poly.equal (presentation ui).placement Major);
    let ui = run ui " ccShow directory in sidebar<CR>" in
    assert (Poly.equal (presentation ui).placement Side);
    let ui = run ui " df bC" in
    assert (List.is_empty (files ui));
    assert (Option.is_some (Session.input_directory (Ui_state.session ui)));
    assert (Option.is_none (Ui_state.side_layout ui ~width ~height));
    assert_frame ui ~width:0 ~height:0;
    assert_frame ui ~width:8 ~height:2;
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "interrupted editor paste cannot cross a side-directory focus round trip" =
  fixture (fun root ->
    let ui = create root |> fun ui -> run ui " ds<CR>i" in
    let before = Text_buffer.to_string (Editor.text (editor ui)) in
    let id = Session.active_id (Ui_state.session ui) |> Option.value_exn in
    let ui = Helpers.run ~width ~height ui [ Paste_start ] in
    let ui = Ui_state.show_directory ui ~width ~height root |> Or_error.ok_exn in
    let ui = Ui_state.activate_buffer ui ~width ~height id |> Or_error.ok_exn in
    let ui = Helpers.run ~width ~height ui (keys "LEAK" @ [ Paste_end ]) in
    assert (String.equal before (Text_buffer.to_string (Editor.text (editor ui))));
    assert (Option.is_some (Ui_state.side_layout ui ~width ~height));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "side opening preserves each file cursor, scroll, edits and independent undo" =
  fixture (fun root ->
    let a = Filename.concat root "a.txt" in
    Out_channel.write_all a ~data:(String.concat ~sep:"\n" (List.init 70 ~f:Int.to_string));
    let ui = Ui_state.create ~tiles_visible:false (Startup.open_path ~cell_width:Cell_map.width a |> Or_error.ok_exn)
      |> fun ui -> run ui "30jiX<Esc> o dsj<CR>" in
    assert (List.equal String.equal (files ui) [ "a.txt"; "b.txt" ]);
    let ui = run ui "iY<Esc> bp" in
    assert (Editor.cursor_line (editor ui) = 30 && Editor.is_dirty (editor ui));
    let scroll = Ui_state.scroll ui in
    assert (scroll.top > 0);
    let ui = run ui " bnu bp" in
    assert (Scroll.equal scroll (Ui_state.scroll ui));
    assert (Editor.is_dirty (editor ui));
    let ui = run ui "u" in
    assert (not (Editor.is_dirty (editor ui)));
    assert (Option.is_some (Ui_state.side_layout ui ~width ~height));
    Session.dispose (Ui_state.session ui))
;;
