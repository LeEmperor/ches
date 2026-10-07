open! Core
open Ches_core
open Ches_app
open Ches_input
open Ches_screen
open Helpers

let width = 80
let height = 16
let run ui s = Helpers.run ~width ~height ui (keys s)
let active ui = Session.active_id (Ui_state.session ui)
let editor ui = Controller.editor (Ui_state.controller ui)
let with_files f =
  let dir = Core_unix.mkdtemp "/tmp/opencode/ches-tabs-" in
  let one = Filename.concat dir "one" and two = Filename.concat dir "two" in
  Core_unix.mkdir one; Core_unix.mkdir two;
  let a = Filename.concat one "same.txt" and b = Filename.concat two "same.txt" in
  let c = Filename.concat dir "other.txt" in
  List.iter [ a; b; c ] ~f:(fun p -> Out_channel.write_all p
    ~data:(String.concat (List.init 60 ~f:(fun i -> sprintf "row %d\n" i))));
  Exn.protect ~f:(fun () -> f a b c)
    ~finally:(fun () -> List.iter [ a; b; c ] ~f:Core_unix.unlink;
      List.iter [ one; two; dir ] ~f:Core_unix.rmdir)
;;
let create path = Ui_state.create ~tiles_visible:false
  (Controller.open_file ~cell_width:Cell_map.width path |> Or_error.ok_exn)
let open_ ui path = Ui_state.open_file ui ~width ~height path |> Or_error.ok_exn

let%test_unit "tab bindings preserve edits, undo, cursor, scroll, open order and close policy" =
  with_files (fun a b c ->
    let ui = create a |> fun ui -> run ui "30G5kiA<Esc>" in
    let aid = active ui in
    let cursor = Editor.cursor (editor ui) and scroll = Ui_state.scroll ui in
    let geometry = Ui_state.geometry ui ~width ~height in
    let ui, bid = open_ ui b in
    assert ((Ui_state.geometry ui ~width ~height).text.y = geometry.text.y + 1);
    let ui = run ui "iB<Esc>" in
    let ui, cid = open_ ui c in
    let ui = run ui " bp" in
    assert (Option.equal Buffer_id.equal (active ui) (Some bid));
    let ui = run ui " bp" in
    assert (Option.equal Buffer_id.equal (active ui) aid);
    assert (Editor.cursor (editor ui) = cursor && Scroll.equal (Ui_state.scroll ui) scroll);
    assert (not (Animation.active (Ui_state.animation ui)));
    let ui = run ui " bp" in
    assert (Option.equal Buffer_id.equal (active ui) (Some cid));
    let ui = run ui " bn" in
    assert (Option.equal Buffer_id.equal (active ui) aid);
    let tabs = Open_buffers.of_session (Ui_state.session ui) in
    assert ([%equal: string list] (List.map tabs ~f:(fun t -> t.Open_buffers.label))
      [ "one/same.txt"; "two/same.txt"; "other.txt" ]);
    assert (List.count tabs ~f:(fun t -> t.modified) = 2);
    let ui = run ui " bc" in
    assert (Option.equal Buffer_id.equal (active ui) aid && List.length (Session.buffers (Ui_state.session ui)) = 3);
    let ui = run ui "u" in
    assert (not (Editor.is_dirty (editor ui)));
    let ui = run ui " bc" in
    assert (Option.equal Buffer_id.equal (active ui) (Some bid));
    assert (Editor.is_dirty (editor ui));
    let ui = run ui " bC" in
    assert (Option.equal Buffer_id.equal (active ui) (Some cid));
    assert (Geometry.Rect.equal geometry.text (Ui_state.geometry ui ~width ~height).text);
    let ui = run ui " bn bp" in
    assert (Option.equal Buffer_id.equal (active ui) (Some cid));
    let ui = run ui " bc bn bp bc bC" in
    assert (Ui_state.has_document ui && not (Ui_state.exited ui));
    assert (List.is_empty (Session.buffers (Ui_state.session ui)));
    assert (String.equal (Session.startup_directory (Ui_state.session ui)) (Filename.dirname a));
    let frame = Frame.render ui ~width ~height in
    assert (String.is_substring (Frame.to_string frame) ~substring:"Directory:");
    let ui = run ui " cc<Esc>" in
    assert (Option.is_none (Ui_state.palette ui));
    let ui = run ui " " in
    let ui, _ = open_ ui b in
    assert (Ui_state.has_document ui && List.length (Session.buffers (Ui_state.session ui)) = 1);
    let ui = run ui " bcq" in
    assert (not (Ui_state.exited ui));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "last-index successor, deduplication and inactive close use the same lifecycle" =
  with_files (fun a b c ->
    let ui = create a in
    let aid = Option.value_exn (active ui) in
    let ui, bid = open_ ui b in
    let ui, _ = open_ ui c in
    let ui = run ui " bc" in
    assert (Option.equal Buffer_id.equal (active ui) (Some bid));
    let ui, same = open_ ui a in
    assert (Buffer_id.equal same aid && List.length (Session.buffers (Ui_state.session ui)) = 2);
    let ui = run ui " bn" in
    assert (Option.equal Buffer_id.equal (active ui) (Some bid));
    let ui = run ui " " in
    let pending = Keymap.pending (Controller.keymap (Ui_state.controller ui)) in
    let ui, closed = Ui_state.close_buffer ui ~width ~height aid ~force:false in
    assert (closed && Option.equal Buffer_id.equal (active ui) (Some bid));
    assert ([%equal: string option] pending (Keymap.pending (Controller.keymap (Ui_state.controller ui))));
    let ui = run ui "bc" in
    assert (Option.is_some (Session.directory_buffer (Ui_state.session ui)));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "overflow is deterministic, cell-exact, and retains the active tab and dirty badge" =
  let tabs = List.init 12 ~f:(fun i ->
    { Open_buffers.id = Buffer_id.of_int (i + 1)
    ; label = sprintf "directory-%d/same-very-long-filename.txt" i
    ; active = i = 6; modified = i = 6; missing = false }) in
  List.iter (List.range 0 160) ~f:(fun width ->
    let spans = File_tabs.render tabs ~width in
    assert (List.sum (module Int) spans ~f:(fun s -> s.Span.width) = width);
    assert (String.equal
      (String.concat (List.map spans ~f:(fun s -> s.Span.text)))
      (String.concat (List.map (File_tabs.render tabs ~width) ~f:(fun s -> s.Span.text))));
    List.iter spans ~f:(fun s -> assert (s.width >= 0 && String.length s.text = s.width));
    if width > 0 then assert (List.exists spans ~f:(fun s -> Style.equal s.style Title));
    if width >= 9 then (
      let active = List.find_exn spans ~f:(fun s -> Style.equal s.style Title) in
      assert (String.is_prefix active.text ~prefix:"[7:" && String.is_suffix active.text ~suffix:"*]")));
  let row = File_tabs.render tabs ~width:80 |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  assert (String.is_prefix row ~prefix:"<" && String.is_suffix row ~suffix:">")
;;

let%test_unit "resizes, tab visibility, zen and offset allocations share valid frame/cursor geometry" =
  with_files (fun a b _ ->
    let ui = create a |> fun ui -> run ui "30G5l" in
    let ui, _ = open_ ui b in
    let ui = run ui " bp" in
    let check ui ~width ~height =
      let frame = Frame.render ui ~width ~height in
      assert (List.length frame.rows = height);
      List.iter frame.rows ~f:(fun spans ->
        assert (List.sum (module Int) spans ~f:(fun s -> s.Span.width) = width);
        List.iter spans ~f:(fun s -> assert (s.width >= 0)));
      let geometry = Ui_state.geometry ui ~width ~height in
      assert (geometry.text.width >= 0 && geometry.text.height >= 0);
      assert (Option.equal [%equal: int * int]
        (Option.map frame.cursor ~f:(fun c -> c.Frame.Cursor.x, c.y))
        (Ui_state.cursor_position ui ~width ~height));
      Option.iter frame.cursor ~f:(fun c ->
        assert (c.x >= 0 && c.x < width && c.y >= 0 && c.y < height);
        assert (c.y >= geometry.text.y && c.y < geometry.text.y + geometry.text.height)) in
    List.iter [ ui; run ui " vz" ] ~f:(fun ui ->
      List.iter (List.range 0 36) ~f:(fun width ->
        List.iter (List.range 0 15) ~f:(fun height ->
          let resized = Helpers.run ~width ~height ui [ Resize ] in
          check resized ~width ~height)));
    let zen = run ui " vz" in
    assert (Option.is_none (Ui_state.tab_rect zen ~allocation:(Ui_state.workspace zen ~width ~height).document.rect));
    let rect : Geometry.Rect.t = { x = 5; y = 3; width = 40; height = 9 } in
    let frame = Frame.render ~allocation:rect ui ~width ~height in
    let geometry = Ui_state.geometry_in ui ~allocation:rect ~reserve_status_row:true in
    assert (geometry.text.y > rect.y);
    Option.iter frame.cursor ~f:(fun cursor -> assert (cursor.y >= geometry.text.y));
    List.iter frame.rows ~f:(fun spans -> assert (List.sum (module Int) spans ~f:(fun s -> s.Span.width) = width));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "palette accepts tab commands once and derives the exact bindings" =
  with_files (fun a b _ ->
    let ui = create a in
    let aid = active ui in
    let ui, bid = open_ ui b in
    let ui = run ui " ccprevious file tab<CR>" in
    assert (Option.equal Buffer_id.equal (active ui) aid && Option.is_none (Ui_state.palette ui));
    let ui = run ui " ccnext file tab<CR>" in
    assert (Option.equal Buffer_id.equal (active ui) (Some bid));
    let ui = run ui " ccClose file tab<CR>" in
    assert (List.length (Session.buffers (Ui_state.session ui)) = 1);
    List.iter [ "tabs.next", "Space b n"; "tabs.previous", "Space b p"
              ; "tabs.close", "Space b c"; "tabs.close-discarding-changes", "Space b C"
              ; "buffers.top", "Space b t"; "buffers.status-rows", "Space b s" ]
      ~f:(fun (id, expected) ->
        let entry = Ches_palette.Catalog.find Ches_palette.Catalog.default (Ches_palette.Catalog.Id.of_string id) |> Option.value_exn in
        let shortcuts = Ches_palette.Shortcut.sequences (Bindings.to_list Bindings.default) (Ches_palette.Catalog.Entry.action entry) in
        assert ([%equal: string list] (List.map shortcuts ~f:Ches_palette.Shortcut.to_string_hum) [ expected ]));
    Session.dispose (Ui_state.session ui))
;;

let status_text ui ~width ~height =
  let layout = Ui_state.view_layout ui ~width ~height Ui_state.status_id |> Option.value_exn in
  let frame = Frame.render ui ~width ~height in
  List.slice frame.rows layout.content.y (layout.content.y + layout.content.height)
  |> List.map ~f:(fun spans ->
    String.concat (List.map spans ~f:(fun s -> s.Span.text))
    |> Cell_map.glyphs |> Array.to_list
    |> List.filter ~f:(fun g -> g.Cell_map.Glyph.col >= layout.content.x
      && g.col < layout.content.x + layout.content.width)
    |> List.map ~f:(fun g -> g.Cell_map.Glyph.text) |> String.concat)
  |> String.concat ~sep:"\n"
;;

let%test_unit "status presentation removes only the strip and preserves shared buffer lifecycle" =
  with_files (fun a b c ->
    let ui = create a |> fun ui -> run ui "30G5liA<Esc>" in
    let aid = Option.value_exn (active ui) in
    let cursor = Editor.cursor (editor ui) in
    let ui, bid = open_ ui b in
    let ui, cid = open_ ui c in
    let ui = run ui " vt bt" in
    let top = Ui_state.geometry ui ~width ~height in
    let panes = Ui_state.workspace ui ~width ~height in
    let ui = run ui " bs" in
    assert (Ui_state.buffers_in_status ui ~width ~height);
    assert (Workspace.Pane.equal panes.document (Ui_state.workspace ui ~width ~height).document);
    let rows = Ui_state.geometry ui ~width ~height in
    assert (rows.text.y = top.text.y - 1 && rows.text.height = top.text.height + 1);
    let text = status_text ui ~width ~height in
    List.iter [ "one/same.txt"; "two/same.txt"; ">3: other.txt"; "1:*" ] ~f:(fun substring ->
      if not (String.is_substring text ~substring) then
        failwith (sprintf "Expected %S in status body:\n%s" substring text));
    let ui = run ui " bn" in
    assert (Option.equal Buffer_id.equal (active ui) (Some aid));
    assert (Editor.cursor (editor ui) = cursor && Editor.is_dirty (editor ui));
    let ui = run ui " bc" in
    assert (List.length (Session.buffers (Ui_state.session ui)) = 3);
    let ui = run ui " bp" in
    assert (Option.equal Buffer_id.equal (active ui) (Some cid));
    let ui, closed = Ui_state.close_buffer ui ~width ~height bid ~force:false in
    assert (closed && Option.equal Buffer_id.equal (active ui) (Some cid));
    assert (List.length (Open_buffers.of_session (Ui_state.session ui)) = 2);
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    assert (Editor.cursor (editor ui) = cursor && Editor.is_dirty (editor ui));
    let ui = run ui "u" in
    assert (not (Editor.is_dirty (editor ui)));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "status rows follow the active buffer through overflow, missing state and palette placement" =
  with_files (fun a b c ->
    let controller = Controller.open_file ~cell_width:Cell_map.width a |> Or_error.ok_exn
      |> Controller.mark_missing in
    let ui = Ui_state.create ~tiles_visible:false ~buffer_presentation:Status_rows controller in
    let ui = run ui " vt" in
    assert (String.is_substring (status_text ui ~width ~height) ~substring:">!1:");
    let aid = Option.value_exn (active ui) in
    let ui, _ = open_ ui b in
    let ui, cid = open_ ui c in
    let ui = run ui " vpj vp- vp-" in
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    let data = Open_buffers.of_session (Ui_state.session ui) in
    let missing = List.hd_exn data in
    assert (missing.missing && String.equal missing.label "one/same.txt");
    assert (not (String.is_substring missing.label ~substring:"missing"));
    assert (String.is_substring (status_text ui ~width ~height) ~substring:">!1:");
    let ui = run ui " bp" in
    assert (Option.equal Buffer_id.equal (active ui) (Some cid));
    (* The three-row stacked status has only one buffer row: active still wins. *)
    assert (String.is_substring (status_text ui ~width ~height) ~substring:">3: other.txt");
    let ui = run ui " cctop strip<CR>" in
    assert (View_command.Buffer_presentation.equal (Ui_state.buffer_presentation ui) Top);
    let ui = run ui " ccstatus rows<CR>" in
    assert (View_command.Buffer_presentation.equal (Ui_state.buffer_presentation ui) Status_rows);
    assert (Option.is_none (Ui_state.palette ui));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "alternate presentation restores across hidden status, zen, compact resize and directory surfaces" =
  with_files (fun a b _ ->
    let ui = create a in
    let ui, _ = open_ ui b in
    let ui = run ui " vt bs" in
    let shown = Ui_state.geometry ui ~width ~height in
    let hidden = run ui " vt" in
    assert (not (Ui_state.buffers_in_status hidden ~width ~height));
    assert (Option.is_some (Ui_state.tab_rect hidden
      ~allocation:(Ui_state.workspace hidden ~width ~height).document.rect));
    assert (View_command.Buffer_presentation.equal (Ui_state.buffer_presentation hidden) Status_rows);
    let restored = run hidden " vt" in
    assert (Geometry.Rect.equal shown.text (Ui_state.geometry restored ~width ~height).text);
    let zen = run ui " vz" in
    assert (not (Ui_state.buffers_in_status zen ~width ~height));
    assert (Option.is_none (Ui_state.tab_rect zen
      ~allocation:(Ui_state.workspace zen ~width ~height).document.rect));
    assert (Ui_state.buffers_in_status (run zen " vz") ~width ~height);
    let directory = run ui " o" in
    let side = run directory " ds" in
    let check ui ~width ~height =
      let ui = Helpers.run ~width ~height ui [ Resize ] in
      let frame = Frame.render ui ~width ~height in
      List.iter frame.rows ~f:(fun spans ->
        assert (Span.total_width spans = width);
        List.iter spans ~f:(fun s -> assert (s.width >= 0)));
      let geometry = Ui_state.geometry ui ~width ~height in
      Option.iter frame.cursor ~f:(fun cursor ->
        assert (cursor.x >= 0 && cursor.x < width && cursor.y >= 0 && cursor.y < height);
        assert (Option.equal [%equal: int * int] (Some (cursor.x, cursor.y))
          (Ui_state.cursor_position ui ~width ~height));
        assert (cursor.y >= geometry.text.y && cursor.y < geometry.text.y + geometry.text.height));
      if not (Ui_state.zen ui) && width >= 1 && height >= 3
         && Option.is_none (Session.input_directory (Ui_state.session ui)) then
        assert (Bool.equal (Option.is_some (Ui_state.tab_rect
          ~buffers_in_status:(Ui_state.buffers_in_status ui ~width ~height) ui
          ~allocation:(Ui_state.workspace ui ~width ~height).document.rect))
          (not (Ui_state.buffers_in_status ui ~width ~height))) in
    List.iter [ ui; zen; directory; side; run ui " vpj"; run ui " vpk"; run ui " vph" ] ~f:(fun ui ->
      List.iter [ 0; 1; 16; 24; 25; 40; 80 ] ~f:(fun width ->
        List.iter [ 0; 1; 2; 3; 4; 6; 8; 16 ] ~f:(fun height -> check ui ~width ~height)));
    (* Explicit document allocations have no companion status tile, so fall back. *)
    let allocation : Geometry.Rect.t = { x = 4; y = 2; width = 40; height = 9 } in
    let frame = Frame.render ~allocation ui ~width ~height in
    assert (String.is_substring (Frame.to_string frame) ~substring:"same.txt");
    Option.iter frame.cursor ~f:(fun cursor ->
      let geometry = Ui_state.geometry_in ui ~allocation ~reserve_status_row:true in
      assert (cursor.y >= geometry.text.y));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "passive row windows retain active and badges in every constrained size" =
  let buffers = List.init 20 ~f:(fun i ->
    { Open_buffers.id = Buffer_id.of_int (i + 1); label = sprintf "file-%d" i
    ; active = i = 12; modified = i = 12; missing = i = 12 }) in
  List.iter (List.range 0 30) ~f:(fun width ->
    List.iter (List.range 0 25) ~f:(fun rows ->
      let body = Buffer_rows.render buffers ~width ~rows in
      assert (List.length body = rows);
      List.iter body ~f:(fun row -> assert (Span.total_width row = width));
      if width > 0 && rows > 0 then
        assert (List.exists body ~f:(fun row ->
          List.exists row ~f:(fun span -> Style.equal span.Span.style Title)));
      if width >= 7 && rows > 0 then
        assert (List.exists body ~f:(fun row ->
          String.concat (List.map row ~f:(fun s -> s.Span.text))
          |> fun text -> String.is_prefix text ~prefix:">!13:*"))))
;;
