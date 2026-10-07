open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers

let width = 72
let height = 14
let run ui notation = Helpers.run ~width ~height ui (keys notation)
let directory ui = Session.directory_buffer (Ui_state.session ui) |> Option.value_exn
let selected ui = Directory_buffer.selected (directory ui) |> Option.value_exn
let text ui = Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller ui)))
let create path = Ui_state.create ~tiles_visible:false ~source_attached:true
  (Startup.open_path ~cell_width:Cell_map.width path |> Or_error.ok_exn)
let fixture f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-directory-test-" in
  let child = Filename.concat root "child" in
  Core_unix.mkdir child;
  let names = [ ".hidden"; "a.txt"; "b.txt"; "bad.txt"; "odd\n\255" ]
    @ List.init 30 ~f:(fun i -> sprintf "z%02d.txt" i) in
  List.iter names ~f:(fun name -> Out_channel.write_all (Filename.concat root name)
    ~data:(if String.equal name "bad.txt" then "\000" else "one\ntwo\nthree\n"));
  Core_unix.symlink ~target:"child" ~link_name:(Filename.concat root "link");
  Core_unix.symlink ~target:"missing" ~link_name:(Filename.concat root "broken");
  Core_unix.mkfifo (Filename.concat root "pipe") ~perm:0o600;
  Exn.protect ~f:(fun () -> f root child)
    ~finally:(fun () -> List.iter ("link" :: "broken" :: "pipe" :: names) ~f:(fun name -> Core_unix.unlink (Filename.concat root name));
      Core_unix.rmdir child; Core_unix.rmdir root)
;;

let file_names ui = Session.buffers (Ui_state.session ui)
  |> List.map ~f:(fun (_, c) -> Filename.basename (Option.value_exn (Editor.path (Controller.editor c))))
;;

let%test_unit "an unreadable batch file does not prevent later files, and failed marks survive" =
  fixture (fun root _ ->
    let path = Filename.concat root "a.txt" in
    Core_unix.chmod path ~perm:0;
    Exn.protect ~finally:(fun () -> Core_unix.chmod path ~perm:0o600) ~f:(fun () ->
      let ui = create root |> fun ui -> run ui "jVj ms<Esc> mo" in
      assert (List.equal String.equal (file_names ui) [ "b.txt" ]);
      assert (Option.exists (Ui_state.message ui) ~f:(fun m -> String.equal m.text "Batch open: 1 opened, 1 failed, 0 skipped"));
      let ui = run ui " o" in
      assert (List.equal String.equal (List.map (Directory_buffer.marked_entries (directory ui)) ~f:(fun e -> e.name)) [ "a.txt" ]);
      Session.dispose (Ui_state.session ui)))
;;

let%test_unit "mark commands are discoverable with shortcuts and execute through the palette" =
  fixture (fun root _ ->
    let action = Ches_input.Keymap.Action.View Ches_input.View_command.Toggle_entry_mark in
    let entry = Ches_palette.Catalog.find Ches_palette.Catalog.default
      (Ches_palette.Catalog.Id.of_string "directory.toggle-mark") |> Option.value_exn in
    assert (Ches_input.Keymap.Action.equal (Ches_palette.Catalog.Entry.action entry) action);
    let shortcuts = Ches_palette.Shortcut.sequences (Ches_input.Bindings.to_list Ches_input.Bindings.default) action in
    assert (List.exists shortcuts ~f:(fun keys -> String.equal (Ches_palette.Shortcut.to_string_hum keys) "Space m m"));
    let ui = create root |> fun ui -> run ui " cctoggle directory entry mark<CR>" in
    assert (Set.length (directory ui).marks = 1);
    let ui = run ui " ccclear directory marks<CR>" in
    assert (Set.is_empty (directory ui).marks);
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "visual Enter batches all selection kinds, retains marks, and shares the register" =
  fixture (fun root _ ->
    List.iter [ "Vj"; "vj"; "<C-v>j" ] ~f:(fun selection ->
      let ui = create root |> fun ui -> run ui ("j mm" ^ selection ^ "<CR>") in
      assert (List.equal String.equal (file_names ui) [ "a.txt"; "b.txt" ]);
      assert (String.equal (Filename.basename (Option.value_exn (Editor.path (Controller.editor (Ui_state.controller ui))))) "a.txt");
      let ui = run ui " o" in
      assert (Set.length (directory ui).marks = 1);
      assert (Mode.equal (Editor.mode (Controller.editor (Ui_state.controller ui))) Normal);
      let before = text ui in
      let ui = run ui "Vjy oP" in
      assert (String.is_prefix (text ui) ~prefix:"a.txt\nb.txt\n");
      let ui = run ui " o" in
      assert (String.equal before (text ui));
      Session.dispose (Ui_state.session ui)))
;;

let%test_unit "noncontiguous marks open in listing order; normal Enter ignores them" =
  fixture (fun root _ ->
    let ui = create root |> fun ui -> run ui "2j mmk mm2j mm" in
    assert (Set.length (directory ui).marks = 3);
    let before = text ui in
    let ui = run ui "k<CR>" in
    assert (List.equal String.equal (file_names ui) [ "b.txt" ]);
    let ui = run ui " o mo" in
    assert (List.equal String.equal (file_names ui) [ "b.txt"; "a.txt" ]);
    assert (String.equal (Filename.basename (Option.value_exn (Editor.path (Controller.editor (Ui_state.controller ui))))) "a.txt");
    let ui = run ui " o" in
    assert (String.equal before (text ui));
    assert (List.equal String.equal (List.map (Directory_buffer.marked_entries (directory ui)) ~f:(fun e -> e.name)) [ "bad.txt" ]);
    let ui = run ui " mo" in
    assert (List.length (file_names ui) = 2 && Set.length (directory ui).marks = 1);
    assert (String.is_substring (Frame.to_string (Frame.render ui ~width ~height)) ~substring:"1 marked");
    let ui = run ui " mc" in
    assert (Set.is_empty (directory ui).marks);
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "selection mark commands, skipped kinds, refresh and directory-local lifetime" =
  fixture (fun root child ->
    let ui = create root in
    let before = text ui in
    let ui = run ui "V8j ms mu ms<Esc>" in
    assert (Set.length (directory ui).marks = 9);
    assert (String.equal before (text ui));
    assert (not (Editor.is_dirty (Controller.editor (Ui_state.controller ui))));
    let ui = run ui " mo o" in
    assert (List.equal String.equal (file_names ui) [ ".hidden"; "a.txt"; "b.txt"; "odd\n\255" ]);
    let marks = (directory ui).marks in
    assert (Set.length marks = 5);
    let ui = run ui " r" in
    assert (Set.equal marks (directory ui).marks);
    let ui = Ui_state.show_directory ui ~width ~height child |> Or_error.ok_exn in
    assert (Set.is_empty (directory ui).marks);
    let ui = run ui "-" in
    assert (Set.equal marks (directory ui).marks);
    List.iter (List.range 0 30) ~f:(fun width -> List.iter (List.range 0 14) ~f:(fun height ->
      let frame = Frame.render ui ~width ~height in
      List.iter frame.rows ~f:(fun spans -> assert (List.sum (module Int) spans ~f:(fun s -> s.Span.width) = width))));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "directory startup and complete persistent-tab workflow with editable undo" =
  fixture (fun root _ ->
    let ui = create root in
    assert (List.is_empty (Session.buffers (Ui_state.session ui)));
    assert (String.equal (selected ui).name ".hidden");
    let before = text ui in
    let ui = run ui " oAXXX<Esc>u" in
    assert (String.equal before (text ui));
    assert (not (Editor.is_dirty (Controller.editor (Ui_state.controller ui))));
    let presentation = Session.directory_presentation (Ui_state.session ui) |> Option.value_exn in
    assert (Group_id.equal presentation.target_group (Session.group_id (Ui_state.session ui)));
    let ui = run ui "j<CR>iA<Esc>" in
    let aid = Session.active_id (Ui_state.session ui) |> Option.value_exn in
    let cursor = Editor.cursor (Controller.editor (Ui_state.controller ui)) in
    let scroll = Ui_state.scroll ui in
    let ui = run ui " o" in
    assert (String.equal (selected ui).name "a.txt");
    let ui = run ui "j<CR>iB<Esc> o o" in
    assert (List.length (Session.buffers (Ui_state.session ui)) = 2);
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    assert (Editor.cursor (Controller.editor (Ui_state.controller ui)) = cursor);
    assert (Scroll.equal (Ui_state.scroll ui) scroll);
    assert (String.is_prefix (text ui) ~prefix:"A");
    let ui = run ui "u o<CR>" in
    assert (List.length (Session.buffers (Ui_state.session ui)) = 2);
    assert (not (Editor.is_dirty (Controller.editor (Ui_state.controller ui))));
    let ui = run ui " bC bC" in
    assert (List.is_empty (Session.buffers (Ui_state.session ui)));
    assert (String.equal (directory ui).path root);
    let ui, requests = Ui_state.take_source_requests ui in
    assert (List.for_all requests ~f:(function
      | Ches_error.Source_request.Document_opened { resource; _ }
      | Document_changed { resource; _ } -> not (String.equal resource root)
      | _ -> true));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "cached navigation, origin selection, refresh identities, failures and tiny rendering" =
  fixture (fun root child ->
    let ui = create root |> fun ui -> run ui "G" in
    let scroll = Ui_state.scroll ui in
    assert (scroll.top > 0);
    let id = (directory ui).id in
    let ui = run ui " o" in
    assert (Scroll.equal scroll (Ui_state.scroll ui));
    let ui = run ui "gg5j<CR>" in
    assert (String.equal (directory ui).path child);
    assert (String.is_substring (Frame.to_string (Frame.render ui ~width ~height)) ~substring:"empty directory");
    let ui = run ui "-" in
    assert (String.equal (selected ui).name "child" && Buffer_id.equal (directory ui).id id);
    let child_id = (selected ui).id in
    let ui = run ui " r" in
    assert ((selected ui).id = child_id);
    let ui = run ui "gg3j<CR>" in
    assert (String.equal (selected ui).name "bad.txt" && String.equal (directory ui).path root);
    let ui = run ui "j<CR>" in
    assert (String.equal (selected ui).name "broken");
    let before = text ui in
    let ui = Helpers.run ~width ~height ui [ Paste_start; Key (Ches_input.Key.char 'X'); Paste_end ] in
    assert (String.equal before (text ui));
    let ui = run ui "gg8j<CR>" in
    assert (String.equal (selected ui).name "pipe");
    List.iter (List.range 0 30) ~f:(fun width -> List.iter (List.range 0 14) ~f:(fun height ->
      let ui = Helpers.run ~width ~height ui [ Resize ] in
      let frame = Frame.render ui ~width ~height in
      List.iter frame.rows ~f:(fun spans -> assert (List.sum (module Int) spans ~f:(fun s -> s.Span.width) = width));
      Option.iter frame.cursor ~f:(fun c -> assert (c.x >= 0 && c.x < width && c.y >= 0 && c.y < height))));
    let session = Ui_state.session ui in
    assert (Or_error.is_error (Session.show_directory session (Filename.concat root "missing")));
    Session.dispose session)
;;

let%test_unit "per-directory viewport caching and input/paste context switches with the same file tab" =
  fixture (fun root child ->
    let names = List.init 30 ~f:(fun i -> sprintf "item%02d" i) in
    List.iter names ~f:(fun name -> Out_channel.write_all (Filename.concat child name) ~data:"text");
    Exn.protect ~finally:(fun () -> List.iter names ~f:(fun name -> Core_unix.unlink (Filename.concat child name)))
      ~f:(fun () ->
        let ui = create (Filename.concat root "a.txt") |> fun ui -> run ui "2Gl" in
        let cursor = Editor.cursor (Controller.editor (Ui_state.controller ui)) in
        let ui = run ui " o" in
        let ui = run ui "gg5j<CR>G" in
        let child_id = (directory ui).id and child_scroll = Ui_state.scroll ui in
        assert (child_scroll.top > 0);
        let ui = run ui "-<CR>" in
        assert (Buffer_id.equal child_id (directory ui).id && Scroll.equal child_scroll (Ui_state.scroll ui));
        let ui = run ui " o" in
        assert (Editor.cursor (Controller.editor (Ui_state.controller ui)) = cursor);
        let aid = Session.active_id (Ui_state.session ui) |> Option.value_exn in
        let ui = run ui "i" |> fun ui -> Helpers.run ~width ~height ui [ Paste_start; Key (Ches_input.Key.char 'X') ] in
        let ui = Ui_state.show_directory ui ~width ~height root |> Or_error.ok_exn in
        let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
        let before = text ui in
        let ui = Helpers.run ~width ~height ui [ Paste_end ] in
        assert (String.equal before (text ui));
        let ui = run ui " o" in
        let id = (selected ui).id in
        let displaced = Filename.concat root "displaced" in
        let a = Filename.concat root "a.txt" in
        Core_unix.rename ~src:a ~dst:displaced;
        Out_channel.write_all a ~data:"replacement";
        Exn.protect ~finally:(fun () -> Core_unix.unlink a; Core_unix.rename ~src:displaced ~dst:a)
          ~f:(fun () ->
            let ui = run ui " r" in
            assert (String.equal (selected ui).name "a.txt" && (selected ui).id <> id);
            Session.dispose (Ui_state.session ui))))
;;

let%test_unit "unreadable navigation/refresh preserve the current view; save-all while browsing targets files" =
  fixture (fun root child ->
    let ui = create (Filename.concat root "a.txt") |> fun ui -> run ui "iA<Esc> o" in
    let ui = run ui "gg5j" in
    let directory_id = (directory ui).id in
    Core_unix.chmod child ~perm:0;
    let ui = Exn.protect ~finally:(fun () -> Core_unix.chmod child ~perm:0o700)
      ~f:(fun () ->
        assert (Or_error.is_error (Startup.open_path ~cell_width:Cell_map.width child));
        let ui = run ui "<CR>" in
        assert (Buffer_id.equal directory_id (directory ui).id && String.equal (selected ui).name "child");
        ui) in
    let ui = run ui "<CR>" in
    let child_id = (directory ui).id and before = text ui in
    Core_unix.chmod child ~perm:0;
    let ui = Exn.protect ~finally:(fun () -> Core_unix.chmod child ~perm:0o700)
      ~f:(fun () ->
        let ui = run ui " r" in
        assert (Buffer_id.equal child_id (directory ui).id && String.equal before (text ui));
        ui) in
    let ui, results = Ui_state.save_all ui ~width ~height in
    assert (List.length results = 1 && snd (List.hd_exn results));
    assert (Buffer_id.equal child_id (directory ui).id);
    assert (String.is_prefix (In_channel.read_all (Filename.concat root "a.txt")) ~prefix:"A");
    let ui = run ui " o" in
    assert (Option.is_none (Session.directory_buffer (Ui_state.session ui)));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "typed lexical resource ownership and symlink-directory navigation" =
  fixture (fun root child ->
    assert (Poly.equal (Startup.classify root) Startup.Directory);
    assert (Poly.equal (Startup.classify (Filename.concat root "missing.txt")) Startup.File);
    let ui = create root in
    let root_id = (directory ui).id in
    let ui = Ui_state.show_directory ~select:"link" ui ~width ~height (root ^ "/./") |> Or_error.ok_exn in
    assert (Buffer_id.equal root_id (directory ui).id);
    let ui = run ui "<CR>" in
    assert (String.equal (directory ui).path (Filename.concat root "link"));
    let alias_id = (directory ui).id in
    let ui = Ui_state.show_directory ui ~width ~height child |> Or_error.ok_exn in
    assert (not (Buffer_id.equal alias_id (directory ui).id));
    let ui = Ui_state.show_directory ui ~width ~height (Filename.concat root "link") |> Or_error.ok_exn in
    let ui = run ui "-" in
    assert (String.equal (selected ui).name "link");
    (match Session.find_resource_buffer (Ui_state.session ui) (root ^ "/child/..") with
     | Some (Session.Directory_buffer d) -> assert (Buffer_id.equal d.id root_id)
     | _ -> assert false);
    assert (List.is_empty (Open_buffers.of_session (Ui_state.session ui)));
    Session.dispose (Ui_state.session ui))
;;
