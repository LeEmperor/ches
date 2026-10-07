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
    let tabs = File_tabs.tabs (Ui_state.session ui) in
    assert ([%equal: string list] (List.map tabs ~f:(fun t -> t.File_tabs.label))
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
    { File_tabs.id = Buffer_id.of_int (i + 1)
    ; label = sprintf "directory-%d/same-very-long-filename.txt" i
    ; active = i = 6; modified = i = 6 }) in
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
              ; "tabs.close", "Space b c"; "tabs.close-discarding-changes", "Space b C" ]
      ~f:(fun (id, expected) ->
        let entry = Ches_palette.Catalog.find Ches_palette.Catalog.default (Ches_palette.Catalog.Id.of_string id) |> Option.value_exn in
        let shortcuts = Ches_palette.Shortcut.sequences (Bindings.to_list Bindings.default) (Ches_palette.Catalog.Entry.action entry) in
        assert ([%equal: string list] (List.map shortcuts ~f:Ches_palette.Shortcut.to_string_hum) [ expected ]));
    Session.dispose (Ui_state.session ui))
;;
