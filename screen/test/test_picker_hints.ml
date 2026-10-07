open! Core
open Ches_screen

let width = 180
let height = 48
let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let footer (content : Tile_shell.Content.t) = (Option.value_exn content.footer).text
let text row = String.concat (List.map row ~f:(fun (s : Span.t) -> s.text))

let file_snapshot : Ches_file_picker.Model.Discovery.t =
  { request = { run_id = Ches_file_picker.Model.Run_id.of_int 1; root = "/project" }
  ; candidates = []; status = Cancelled }

let content_snapshot : Ches_content_picker.Model.snapshot =
  { request = { run_id = Ches_content_picker.Model.Run_id.of_int 1
              ; root = "/project"; query = "needle" }
  ; hits = []; status = Cancelled }

let adapters =
  [ (fun ui -> Ui_state.open_file_picker ui ~width ~height ~discovery:file_snapshot
        ~release:(fun () -> ()))
    , (fun ?hotkey_hints ?notice ui ~width ~rows -> File_picker_tile.render
        ?hotkey_hints ?notice (Option.value_exn (Ui_state.file_picker ui)) ~width ~rows)
    , Ui_state.file_picker_layout, "0/0 matches", "Discovery cancelled"
  ; (fun ui -> Ui_state.open_content_picker ui ~width ~height ~snapshot:content_snapshot
        ~release:(fun () -> ()))
    , (fun ?hotkey_hints ?notice ui ~width ~rows -> Content_picker_tile.render
        ?hotkey_hints ?notice (Option.value_exn (Ui_state.content_picker ui)) ~width ~rows)
    , Ui_state.content_picker_layout, "0 matches", "Search cancelled"
  ; (fun ui -> run ui " fl")
    , (fun ?hotkey_hints ?notice ui ~width ~rows -> Line_picker_tile.render
        ?hotkey_hints ?notice (Option.value_exn (Ui_state.line_picker ui)) ~width ~rows)
    , Ui_state.line_picker_layout, "matches / 1 lines", "Filtering"
  ; (fun ui -> run ui " cc")
    , (fun ?hotkey_hints ?notice ui ~width ~rows -> Palette_tile.render
        ?hotkey_hints ?notice (Option.value_exn (Ui_state.palette ui)) ~width ~rows)
    , Ui_state.palette_layout, "1/", "1/"
  ]

let%test_unit "all floating control footers default hidden and preserve metadata/notices" =
  List.iter adapters ~f:(fun (open_picker, render, _, count, status) ->
    let ui = open_picker (Helpers.ui "document") in
    let hidden = render ui ~width:180 ~rows:8 in
    let shown = render ui ~hotkey_hints:true ~width:180 ~rows:8 in
    assert (String.equal (footer hidden)
      (footer (render ui ~hotkey_hints:false ~width:180 ~rows:8)));
    List.iter [ count; status ] ~f:(fun substring ->
      assert (String.is_substring (footer hidden) ~substring);
      assert (String.is_substring (footer shown) ~substring));
    List.iter [ "Tab/Shift-Tab"; "Ctrl-n/p"; "Esc" ] ~f:(fun substring ->
      assert (not (String.is_substring (footer hidden) ~substring));
      assert (String.is_substring (footer shown) ~substring));
    assert (Poly.equal hidden.body shown.body);
    List.iter [ false; true ] ~f:(fun hotkey_hints ->
      let content = render ui ~hotkey_hints ~notice:"Capture notice" ~width:180 ~rows:8 in
      assert (String.is_substring (footer content) ~substring:"Capture notice")))
;;

let%test_unit "palette invokes the existing hint action and returns to the document" =
  let initial = Helpers.ui "document" in
  let enabled = run initial " ccToggle tile hotkey hints<CR>" in
  assert (Ui_state.hotkey_hints enabled && Option.is_none (Ui_state.palette enabled));
  let hidden = run enabled " ccToggle tile hotkey hints<CR>" in
  assert (not (Ui_state.hotkey_hints hidden));
  assert (Option.is_none (Ui_state.palette hidden))
;;

let%test_unit "actual frame propagates the existing global toggle to every floating footer" =
  List.iter adapters ~f:(fun (open_picker, render, layout, _, _) ->
    let initial = Helpers.ui "document" in
    assert (not (Ui_state.hotkey_hints initial));
    let check ui hints =
      let ui = open_picker ui in
      let layout = Option.value_exn (layout ui ~width ~height) in
      let expected = render ui ~hotkey_hints:hints
        ~width:layout.content.width ~rows:layout.content.height in
      let expected = Tile_shell.render layout ~focused:true expected |> List.last_exn |> text in
      let frame = Frame.render ui ~width ~height in
      let row = List.nth_exn frame.rows (layout.outer.y + layout.outer.height - 1) in
      let actual = text row in
      assert (String.is_substring actual ~substring:expected);
      expected
    in
    let hidden = check initial false in
    let enabled = run initial " v?" in
    assert (Ui_state.hotkey_hints enabled);
    let shown = check enabled true in
    assert (not (String.equal hidden shown));
    assert (String.equal hidden (check (run enabled " v?") false)))
;;
