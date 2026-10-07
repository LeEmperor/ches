open! Core
open Ches_screen
module Model = Ches_file_picker.Model
module Preview = Ches_file_preview_model.Model
module Interaction = Ches_file_picker.Interaction

let discovery n : Model.Discovery.t =
  { request = { run_id = Model.Run_id.of_int n; root = "/project" }
  ; status = Complete { truncated = false }
  ; candidates = List.map [ "a.ml"; "b.ml" ] ~f:(fun relative_path ->
      Model.Candidate.create ~root:"/project" ~relative_path |> Or_error.ok_exn) }
let drain picker =
  while Interaction.busy (File_picker_tile.session picker) do
    File_picker_tile.work picker ~budget:128
  done
let request picker generation : Preview.request =
  let model = Interaction.model (File_picker_tile.session picker) in
  { session = (Model.discovery model).request
  ; selected = Option.value_exn (Model.selected model); generation }
let text rows = String.concat ~sep:"\n" (List.map rows ~f:(fun row ->
  String.concat (List.map row ~f:(fun (span : Span.t) -> span.text))))

let%test_unit "preview geometry, safe cells, visible rows and identity/generation guards" =
  let picker = File_picker_tile.create ~token:() ~discovery:(discovery 1) in
  drain picker;
  let a = request picker 1 in
  let raw = "\t界é\027\r\n" ^ String.concat ~sep:"\n" (List.init 120 ~f:(sprintf "row%d")) in
  let pos = ref 0 in
  let state = Preview.collect ~source:(Buffer { revision = 4 }) ~cancelled:(fun () -> false)
    ~read:(fun bytes ~len ->
      let len = Int.min len (String.length raw - !pos) in
      Stdlib.Bytes.blit_string raw !pos bytes 0 len; pos := !pos + len; len)
    |> Option.value_exn in
  let delivery : Preview.snapshot = { request = a; state } in
  File_picker_tile.expect_preview picker (Some a);
  assert (File_picker_tile.install_preview picker delivery);
  List.iter [ 0; 1; 14; 80; 95; 96; 104; 140; 180 ] ~f:(fun width ->
    List.iter [ 0; 1; 2; 3; 8 ] ~f:(fun rows ->
      let content = File_picker_tile.render picker ~width ~rows in
      assert (List.length content.body <= rows);
      List.iter content.body ~f:(fun row -> assert (Span.total_width row = width));
      let rendered = text content.body in
      assert (not (String.contains rendered '\027') && not (String.contains rendered '\t'));
      if width < 96 then assert (not (String.is_substring rendered ~substring:"Preview"));
      if width >= 96 && rows >= 3 then (
        assert (String.is_substring rendered ~substring:"Preview | a.ml");
        assert (String.is_substring rendered ~substring:"TRUNCATED");
        assert (String.is_substring rendered ~substring:"buffer r4");
        assert (not (String.is_substring rendered ~substring:"row10")));
      let cursor = File_picker_tile.cursor picker ~width in
      if width > 0 then assert (cursor.column < fst (File_picker_tile.columns ~width))));
  File_picker_tile.update picker ~rows:8 Next;
  (* Even without host synchronization a changed selection rejects delivery. *)
  assert (not (File_picker_tile.install_preview picker delivery));
  let b = request picker 2 in
  File_picker_tile.expect_preview picker (Some b);
  assert (Option.is_none (File_picker_tile.preview picker));
  File_picker_tile.update picker ~rows:8 Previous;
  File_picker_tile.expect_preview picker (Some (request picker 3));
  assert (not (File_picker_tile.install_preview picker delivery));
  File_picker_tile.clear_preview picker;
  assert (not (File_picker_tile.install_preview picker delivery));
  let replacement = File_picker_tile.create ~token:() ~discovery:(discovery 2) in
  drain replacement;
  File_picker_tile.expect_preview replacement (Some (request replacement 1));
  assert (not (File_picker_tile.install_preview replacement delivery))

let%test_unit "preview states keep padded columns aligned; narrow footer hints are opt-in" =
  let picker = File_picker_tile.create ~token:() ~discovery:(discovery 3) in
  drain picker;
  let expected = request picker 1 in
  File_picker_tile.expect_preview picker (Some expected);
  List.iter
    [ Preview.Loading, "Loading..."
    ; Empty Disk, "Empty file"
    ; Missing, "File missing"
    ; Unreadable "bad\027\t\r\226\128\174access", "Unreadable: bad"
    ; Unsupported Binary, "Unsupported binary"
    ; Unsupported Encoding, "Unsupported encoding"
    ; Unsupported Special_file, "Unsupported non-regular"
    ] ~f:(fun (state, label) ->
      assert (File_picker_tile.install_preview picker { request = expected; state });
      List.iter [ 96; 97; 104; 140 ] ~f:(fun width ->
        let content = File_picker_tile.render picker ~width ~rows:8 in
        let left, _ = File_picker_tile.columns ~width in
        List.iter content.body ~f:(fun row ->
          assert (Span.total_width row = width);
          let separator = Span.of_glyphs (Cell_map.glyphs (text [ row ]))
            ~left ~cols:3 ~text:Status ~special:Status_special |> fun row -> text [ row ] in
          assert (String.equal separator " | "));
        let rendered = text content.body in
        assert (String.is_substring rendered ~substring:label);
        List.iter [ '\027'; '\t'; '\r' ] ~f:(fun control ->
          assert (not (String.contains rendered control)))));
  let content = File_picker_tile.render picker ~width:80 ~rows:8 in
  let hint = (Option.value_exn content.footer).text in
  let visible = Tile_text.row Status hint ~width:76 |> fun row -> text [ row ] in
  assert (not (String.is_substring visible ~substring:"Enter, Esc"));
  assert (not (String.is_substring visible ~substring:"Tab/Shift-Tab"));
  assert (String.is_substring visible ~substring:"discovered");
  let content = File_picker_tile.render ~hotkey_hints:true picker ~width:80 ~rows:8 in
  let hint = (Option.value_exn content.footer).text in
  let visible = Tile_text.row Status hint ~width:76 |> fun row -> text [ row ] in
  assert (String.is_substring visible ~substring:"Enter, Esc");
  assert (String.is_substring visible ~substring:"Tab/Shift-Tab")
