open! Core
open Ches_core
open Ches_app
open Ches_screen

let width = 120
let height = 24
let run t s = Helpers.run ~width ~height t (Helpers.keys s)
let editor t = Controller.editor (Ui_state.controller t)
let row_text row = String.concat (List.map row ~f:(fun (s : Span.t) -> s.text))
let bottom t = row_text (List.last_exn (Frame.render t ~width ~height).rows)
let create ?(bare = false) ?bare_prefs ?(smear_enabled = false) text =
  Ui_state.create ~bare ?bare_prefs ~smear_enabled
    (Controller.create (Editor.create ~path:"bare.txt" ~cell_width:Cell_map.width
       (Text_buffer.of_string text |> Result.ok |> Option.value_exn)))
;;

let check_bare ?(style = Line_numbers.Off) t ~width ~height =
  assert (Ui_state.bare t && not (Ui_state.zen t));
  assert (Line_numbers.equal (Ui_state.bare_prefs t).line_numbers style);
  let g = Ui_state.geometry t ~width ~height in
  let gutter_width = if Line_numbers.equal style Off
      || width < g.gutter_digits + 1 + Geometry.min_decorated_text_width
    then 0 else g.gutter_digits + 1 in
  assert (not g.border && g.padding = 0 && g.gutter.width = gutter_width);
  assert (g.gutter.x = 0 && g.text.x = gutter_width && g.text.y = 0
    && g.text.width = width - gutter_width);
  assert (g.text.height = Int.max 0 (height - 1));
  let workspace = Ui_state.workspace t ~width ~height in
  assert (Option.is_none workspace.status && List.is_empty workspace.minors);
  let frame = Frame.render t ~width ~height in
  assert (List.length frame.rows = height && List.is_empty frame.smear);
  List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width));
  assert (Option.equal [%equal: int * int]
    (Option.map frame.cursor ~f:(fun c -> c.x, c.y))
    (Ui_state.cursor_position t ~width ~height))
;;

let%test_unit "bare number switches use shared styles and feedback without changing workspace" =
  let initial = create ~bare:true "first\nsecond\nthird" in
  let prefs = Ui_state.prefs initial in
  check_bare initial ~width ~height;
  let _, final = List.fold
      [ " vn", Line_numbers.Absolute; " vN", Hybrid; " vn", Relative; " vN", Off ]
      ~init:((), initial) ~f:(fun ((), t) (keys, style) ->
        let t = run t keys in
        check_bare ~style t ~width ~height;
        assert (Geometry.Prefs.equal prefs (Ui_state.prefs t));
        assert (String.is_substring (bottom t) ~substring:(Line_numbers.to_string style));
        assert (not (String.is_substring (bottom t) ~substring:"no room"));
        let g = Ui_state.geometry t ~width ~height in
        let frame = Frame.render t ~width ~height in
        List.iteri (List.take frame.rows 3) ~f:(fun line row ->
          if not (Line_numbers.equal style Off) then
            assert (String.is_prefix (row_text row)
              ~prefix:(Line_numbers.label style ~digits:g.gutter_digits ~line ~cursor_line:0)));
        (), t) in
  assert (Presentation.Bare_prefs.equal (Ui_state.bare_prefs final) Presentation.Bare_prefs.default)
;;

let%test_unit "workspace and zen number switches and resets leave bare profile retained" =
  let t = create ~bare_prefs:{ line_numbers = Relative } "hello" in
  List.iter [ ""; " vz" ] ~f:(fun enter ->
    let t = run t enter |> fun t -> run t " vn" in
    assert (Line_numbers.equal (Ui_state.prefs t).line_numbers Absolute);
    let saved = Ui_state.prefs t in
    let bare = run t " vB" in
    check_bare ~style:Relative bare ~width ~height;
    let changed = run bare " vn" in
    check_bare ~style:Hybrid changed ~width ~height;
    assert (Geometry.Prefs.equal saved (Ui_state.prefs changed));
    let restored = run changed " vB" in
    assert (Presentation.equal (Ui_state.presentation restored) (Ui_state.presentation t));
    assert (Geometry.Prefs.equal saved (Ui_state.prefs restored));
    let reset = run restored " vr" in
    assert (Geometry.Prefs.equal (Ui_state.prefs reset) Geometry.Prefs.default);
    check_bare ~style:Hybrid (run reset " vB") ~width ~height)
;;

let%test_unit "bare reset affects only its own profile including with nondefault geometry" =
  let t = create "hello" |> fun t -> run t " vn v+ vL vp+" in
  let prefs = Ui_state.prefs t and workspace = Ui_state.workspace_prefs t in
  let reset = run t " vB vN vr" in
  check_bare reset ~width ~height;
  assert (Geometry.Prefs.equal prefs (Ui_state.prefs reset));
  assert (Workspace.Prefs.equal workspace (Ui_state.workspace_prefs reset));
  assert (Geometry.Prefs.equal prefs (Ui_state.prefs (run reset " vB")))
;;

let%test_unit "direct zen entry from bare selects workspace numbers and retains bare numbers" =
  let t = create "first\nsecond" |> fun t -> run t " vn vB vN" in
  check_bare ~style:Relative t ~width ~height;
  let zen = run t " vz" in
  assert (Ui_state.zen zen && not (Ui_state.bare zen));
  assert (Line_numbers.equal (Ui_state.prefs zen).line_numbers Absolute);
  assert (Line_numbers.equal (Ui_state.bare_prefs zen).line_numbers Relative);
  let zen = run zen " vN" in
  assert (Line_numbers.equal (Ui_state.prefs zen).line_numbers Hybrid);
  check_bare ~style:Relative (run zen " vB") ~width ~height
;;

let%test_unit "optional initial bare profile and palette reuse existing number actions" =
  let t = create ~bare:true ~bare_prefs:{ line_numbers = Absolute } "first\nsecond" in
  check_bare ~style:Absolute t ~width ~height;
  let allocation = { Geometry.Rect.x = 3; y = 2; width = 40; height = 8 } in
  let g = Ui_state.geometry_in t ~allocation ~reserve_status_row:false in
  assert (not g.border && g.padding = 0 && g.text.height = 8);
  assert (g.gutter.x = 3 && g.text.x = 7 && g.text.width = 36);
  let frame = Frame.render t ~allocation ~reserve_status_row:false ~width ~height in
  assert (Option.equal [%equal: int * int]
    (Option.map frame.cursor ~f:(fun c -> c.x, c.y))
    (Ui_state.cursor_position_in t ~allocation ~reserve_status_row:false));
  let prefs = Ui_state.prefs t in
  let t = run t " ccrel num<CR>" in
  assert (Option.is_none (Ui_state.palette t));
  check_bare ~style:Hybrid t ~width ~height;
  let t = run t " ccabsolute line numbers<CR>" in
  assert (Option.is_none (Ui_state.palette t));
  check_bare ~style:Relative t ~width ~height;
  assert (Geometry.Prefs.equal prefs (Ui_state.prefs t))
;;

let%test_unit "numbered bare tiny fallback refits tab and wide text and restores gutter" =
  let t = create ~bare:true ~bare_prefs:{ line_numbers = Hybrid }
      "first\n\t界abcdefghijklmnopqrstuv\nthird" |> fun t -> run t "jll" in
  let t = List.fold [ 120, 24; 20, 6; 19, 6; 2, 2; 1, 1; 0, 0; 120, 24 ]
      ~init:t ~f:(fun t (width, height) ->
        let t, _ = Ui_state.apply t ~width ~height Resize in
        check_bare ~style:Hybrid t ~width ~height;
        t) in
  assert (Option.equal [%equal: int * int] (Ui_state.cursor_position t ~width ~height) (Some (14, 1)));
  let tiny = Helpers.run ~width:19 ~height:6 t (Helpers.keys " vn") in
  assert (Option.exists (Ui_state.message tiny)
    ~f:(fun message -> String.is_substring message.text ~substring:"relative (no room)"));
  let restored = run tiny " vn" in
  check_bare ~style:Hybrid restored ~width ~height;
  assert (not (String.is_substring (bottom restored) ~substring:"no room"))
;;

let%test_unit "bare numbers survive opening and activating buffers and workspace focus" =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-bare-numbers-" in
  let path = Filename.concat root "other.txt" in
  Out_channel.write_all path ~data:"other\nfile";
  Exn.protect ~f:(fun () ->
    let t = create ~bare:true "original" |> fun t -> run t " vN" in
    let original = Option.value_exn (Session.active_id (Ui_state.session t)) in
    let opened, other = Ui_state.open_file t ~width ~height path |> Or_error.ok_exn in
    check_bare ~style:Relative opened ~width ~height;
    let original = Ui_state.activate_buffer opened ~width ~height original |> Or_error.ok_exn in
    check_bare ~style:Relative original ~width ~height;
    let cycled = run original " bn" in
    assert (Option.equal Buffer_id.equal (Session.active_id (Ui_state.session cycled)) (Some other));
    check_bare ~style:Relative cycled ~width ~height;
    let workspace = run cycled " vo" in
    assert (not (Ui_state.bare workspace));
    check_bare ~style:Relative (run workspace " vB") ~width ~height;
    Session.dispose (Ui_state.session workspace))
    ~finally:(fun () -> Core_unix.unlink path; Core_unix.rmdir root)
;;

let%test_unit "startup bare uses top-left text and an idle quiet feedback row at every size" =
  let t = create ~bare:true ~smear_enabled:true "hello\nworld" in
  List.iter [ 120, 24; 24, 6; 2, 2; 1, 1; 0, 0; 0, 8; 120, 24 ]
    ~f:(fun (width, height) -> check_bare t ~width ~height);
  let frame = Frame.render t ~width ~height in
  assert (String.is_prefix (row_text (List.hd_exn frame.rows)) ~prefix:"hello");
  assert (String.is_empty (String.strip (bottom t)));
  assert (not (Animation.enabled (Ui_state.animation t)));
  (* Headless callers may explicitly give every row to text. The cursor and render
     must use the same override, rather than subtracting a second feedback row. *)
  let allocation = { Geometry.Rect.x = 3; y = 2; width = 40; height = 8 } in
  let g = Ui_state.geometry_in t ~allocation ~reserve_status_row:false in
  assert (Geometry.Rect.equal g.text allocation);
  let frame = Frame.render t ~allocation ~reserve_status_row:false ~width ~height in
  assert (Option.exists frame.cursor ~f:(fun c -> c.x = 3 && c.y = 2))
;;

let%test_unit "bare feedback preserves pending search command and useful messages without permanent fields" =
  let t = create ~bare:true "hello\nworld" in
  let pending = run t " " in
  assert (String.is_substring (bottom pending) ~substring:"Space");
  let search = run t "/world" in
  assert (String.is_substring (bottom search) ~substring:"world");
  let command = run t ":w" in
  assert (String.is_substring (bottom command) ~substring:":w");
  List.iter [ pending; search; command ] ~f:(fun t ->
    let text = bottom t in
    assert (not (String.is_substring text ~substring:"NORMAL"));
    assert (not (String.is_substring text ~substring:"bare.txt"));
    assert (not (String.is_substring text ~substring:"1:1")));
  let failed = Ui_state.update_feedback t ~width ~height
      (Ches_error.Error.Failed
         ({ source = "file"; kind = Save; resource = "bare.txt" }, Error, "Cannot save file")) in
  assert (String.is_substring (bottom failed) ~substring:"Cannot save file");
  assert (not (String.is_substring (bottom failed) ~substring:"problems"));
  let acknowledged = run failed "<Esc>" in
  assert (String.is_empty (String.strip (bottom acknowledged)))
;;

let%test_unit "bare restores prior zen and retained workspace preferences without losing edits or undo" =
  let t = create ~smear_enabled:true "abc" |> fun t -> run t "iX<Esc> vph vn vL" in
  let initial_editor = editor t in
  let prefs = Ui_state.prefs t and workspace = Ui_state.workspace_prefs t in
  let zen = run t " vz" in
  let bare = run zen " vB" in
  check_bare bare ~width ~height;
  assert (phys_equal initial_editor (editor bare));
  let changed = run bare " v+ vN vp+ vs" in
  check_bare ~style:Relative changed ~width ~height;
  assert (Line_numbers.equal prefs.line_numbers (Ui_state.prefs changed).line_numbers);
  assert (not (Geometry.Prefs.equal prefs (Ui_state.prefs changed)));
  let restored_zen = run changed " vB" in
  assert (Ui_state.zen restored_zen && not (Ui_state.bare restored_zen));
  let restored = run restored_zen " vz" in
  assert (not (Ui_state.zen restored));
  assert (Option.is_some (Ui_state.workspace restored ~width ~height).status);
  assert (not (Workspace.Prefs.equal workspace (Ui_state.workspace_prefs restored)));
  assert (phys_equal initial_editor (editor restored));
  let undone = run restored "u" in
  assert (String.equal (Text_buffer.to_string (Editor.text (editor undone))) "abc");
  let redone = run undone "<C-r>" in
  assert (String.equal (Text_buffer.to_string (Editor.text (editor redone))) "Xabc")
;;

let%test_unit "entering bare from view tab or focused minor returns to file and retains placements" =
  List.iter [ " vo"; " vo st"; " vo ss"; " gt" ] ~f:(fun commands ->
    let base = create "file contents" in
    let t = Ui_state.create ~views:[ Vcs_view.entry ~cwd:"/tmp/opencode" () ]
        (Ui_state.controller base) in
    let t = run t commands in
    let placements = View_registry.placements (Ui_state.views t) in
    let buffers = List.map (Session.buffers (Ui_state.session t)) ~f:fst in
    let bare = run t " vB" in
    check_bare bare ~width ~height;
    assert (Option.is_none (Ui_state.active_tab_view bare));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view bare ~width ~height) Ui_state.document_id);
    assert (Option.is_none (Ui_state.capture_pending bare));
    assert (Option.is_none (Ches_input.Keymap.pending (Controller.keymap (Ui_state.controller bare))));
    let restored = run bare " vB" in
    assert ([%equal: (Ches_tile.View_id.t * View_registry.Placement.t) list]
      placements (View_registry.placements (Ui_state.views restored)));
    assert ([%equal: Buffer_id.t list] buffers (List.map (Session.buffers (Ui_state.session restored)) ~f:fst)))
;;

let%test_unit "explicit workspace focus leaves bare but layout preference changes keep it" =
  let base = create ~bare:true "hello" in
  let resized = run base " vc vL vn vt vp+" in
  check_bare ~style:Absolute resized ~width ~height;
  let focused = run resized " vo" in
  assert (not (Ui_state.bare focused));
  assert (Ches_tile.View_id.equal (Ui_state.focused_view focused ~width ~height) Problems_tile.id)
;;

let%test_unit "bare retains syntax selection and search overlays while suppressing cursor animation" =
  let controller = Ui_state.controller (Helpers.ui ~path:"bare.ml" "let value = 1\n") in
  let t = Ui_state.create ~bare:true ~smear_enabled:true controller in
  let spans t = List.concat (Frame.render t ~width ~height).rows in
  assert (List.exists (spans t) ~f:(fun span -> match span.Span.style with
    | Document d -> Ches_highlight.Category.equal d.syntax Keyword
    | _ -> false));
  let selected = run t "vll" in
  assert (List.exists (spans selected) ~f:(fun span -> match span.Span.style with
    | Document d -> Option.equal Style.Overlay.equal d.overlay (Some Selection)
    | _ -> false));
  let searched = run t "/value<CR>" in
  assert (List.exists (spans searched) ~f:(fun span -> match span.Span.style with
    | Document d -> Option.exists d.overlay ~f:(function Search_match | Search_current -> true | _ -> false)
    | _ -> false));
  let moved = run t "ll" in
  assert (not (Animation.active (Ui_state.animation moved)));
  let restored = run moved " vB" in
  assert (Animation.enabled (Ui_state.animation restored));
  Controller.close (Ui_state.controller restored)
;;

let%test_unit "palette and line picker are usable in bare and close back to bare" =
  let t = create ~bare:true "first\nneedle" in
  let palette = run t " cc" in
  assert (Option.is_some (Ui_state.palette palette));
  assert (Option.is_some (Frame.render palette ~width ~height).cursor);
  let closed = run palette "<Esc>" in
  check_bare closed ~width ~height;
  let picker = Ui_state.open_line_picker closed ~width ~height in
  assert (Option.is_some (Ui_state.line_picker picker));
  assert (Option.is_some (Frame.render picker ~width ~height).cursor);
  let closed = run picker "<Esc>" in
  check_bare closed ~width ~height
;;

let%test_unit "file and content pickers retain bare; palette can enter bare after releasing a picker" =
  let base = create ~bare:true "hello" in
  let discovery : Ches_file_picker.Model.Discovery.t =
    { request = { run_id = Ches_file_picker.Model.Run_id.of_int 901; root = "/project" }
    ; candidates = []; status = Complete { truncated = false } } in
  let released = ref 0 in
  let opened = Ui_state.open_file_picker base ~width ~height ~discovery
      ~release:(fun () -> incr released) in
  assert (Ui_state.bare opened && Option.is_some (Ui_state.file_picker opened));
  let closed = run opened "<Esc>" in
  assert (!released = 1);
  check_bare closed ~width ~height;
  let snapshot : Ches_content_picker.Model.snapshot =
    { request = { run_id = Ches_content_picker.Model.Run_id.of_int 902; root = "/project"; query = "" }
    ; hits = []; status = Loading } in
  let opened = Ui_state.open_content_picker closed ~width ~height ~snapshot
      ~release:(fun () -> incr released) in
  assert (Ui_state.bare opened && Option.is_some (Ui_state.content_picker opened));
  let closed = run opened "<Esc>" in
  assert (!released = 2);
  check_bare closed ~width ~height;
  let workspace = run closed " vB" in
  let opened = Ui_state.open_file_picker workspace ~width ~height ~discovery
      ~release:(fun () -> incr released) in
  let palette = run opened "<Esc> cc" in
  let bare = run palette "bare<CR>" in
  assert (!released = 3 && Option.is_none (Ui_state.file_picker bare));
  check_bare bare ~width ~height
;;

let%test_unit "entering bare from a help float releases capture and pending workspace keys" =
  let t = create "hello" |> fun t -> run t " vo?" in
  assert (Option.is_some (Ui_state.help t));
  let t = run t " vB" in
  assert (Option.is_none (Ui_state.help t));
  assert (Option.is_none (Ui_state.capture_pending t));
  check_bare t ~width ~height
;;

let%test_unit "directory-only startup remains operable; side directory focus yields to active file" =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-bare-" in
  let path = Filename.concat root "file.txt" in
  Out_channel.write_all path ~data:"file contents";
  Exn.protect ~f:(fun () ->
    let controller = Startup.open_path ~cell_width:Cell_map.width root |> Or_error.ok_exn in
    let initial = Ui_state.create ~bare:true controller in
    check_bare initial ~width ~height;
    assert (Option.is_some (Session.input_directory (Ui_state.session initial)));
    let opened, _ = Ui_state.open_file initial ~width ~height path |> Or_error.ok_exn in
    check_bare opened ~width ~height;
    let directory = run opened " ds" in
    assert (not (Ui_state.bare directory));
    assert (Option.is_some (Session.input_directory (Ui_state.session directory)));
    let placement = Session.directory_presentation (Ui_state.session directory) in
    let bare = run directory " vB" in
    check_bare bare ~width ~height;
    assert (Option.is_none (Session.input_directory (Ui_state.session bare)));
    assert (String.equal (Text_buffer.to_string (Editor.text (editor bare))) "file contents");
    let restored = run bare " vB" in
    assert (Option.equal Poly.equal placement (Session.directory_presentation (Ui_state.session restored)));
    assert (Option.is_some (Ui_state.side_layout restored ~width ~height));
    let bare = run restored " vB" in
    let directory = run bare " o" in
    assert (not (Ui_state.bare directory));
    assert (Option.is_some (Session.input_directory (Ui_state.session directory)));
    Session.dispose (Ui_state.session directory))
    ~finally:(fun () -> Core_unix.unlink path; Core_unix.rmdir root)
;;
