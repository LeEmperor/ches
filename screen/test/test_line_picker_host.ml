open! Core
open Ches_core
open Ches_screen
module Lines = Ches_line_picker.Lines
module Controller = Ches_app.Controller

let width = 100
let height = 30
let apply t inputs = Helpers.run ~width ~height t inputs
let run t keys = apply t (Helpers.keys keys)
let picker t = Option.value_exn (Ui_state.line_picker t)
let session t = Line_picker_tile.session (picker t)
let work t = apply t [ Line_picker_work (Ui_state.line_picker_generation t) ]
let rec finish t = if Lines.busy (session t) then finish (work t) else t
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))

let%test_unit "Tab/Shift-Tab navigate duplicate lines independently of query and jump selection" =
  let initial = Helpers.ui (String.concat ~sep:"\n" (List.init 40 ~f:(fun _ -> "same"))) in
  let t = run initial " flsame" |> finish in
  let t = run t "<S-Tab>" in
  assert ([%equal: int option] (Lines.selected (session t)) (Some 1));
  let t = run t (String.concat (List.init 45 ~f:(fun _ -> "<Tab>"))) in
  assert ([%equal: int option] (Lines.selected (session t)) (Some 40));
  assert (String.equal (Lines.query (session t)) "same");
  (* The rendered viewport reveals the selected last line, not just its model index. *)
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"> 40  same");
  let t = run t "<S-Tab><C-p><C-n>" in
  assert ([%equal: int option] (Lines.selected (session t)) (Some 39));
  let t = run t "<BS>" |> finish in
  assert (String.equal (Lines.query (session t)) "sam");
  assert ([%equal: int option] (Lines.selected (session t)) (Some 39));
  let t = run t "<CR>" in
  assert (Option.is_none (Ui_state.line_picker t));
  assert (Editor.cursor (editor t) = Text_buffer.line_start (Editor.text (editor t)) 38);
  assert (String.equal (text initial) (text t));
  let t = run t " flzzzz" |> finish |> fun t -> run t "<Tab><S-Tab><CR>" in
  assert (Option.is_some (Ui_state.line_picker t) && Option.is_none (Lines.selected (session t)));
  assert (Option.is_none (Ui_state.line_picker (run t "<Esc>")))
;;

let%test_unit "live line binding: unsaved snapshot, bounded turns, Unicode jump and viewport reveal" =
  let initial = Helpers.ui (String.concat ~sep:"\n" (List.init 300 ~f:(sprintf "row %d"))) in
  let initial = run initial "GA<Tab>界éneedle<Esc>gg" in
  assert (Editor.is_dirty (editor initial));
  let contents = text initial in
  let revision = Editor.revision (editor initial) in
  let workspace = Ui_state.workspace initial ~width ~height in
  let t = run initial " fl" in
  assert (Lines.prepared_count (session t) = 0);
  let t = run t "<CR>" in
  assert (Option.is_some (Ui_state.line_picker t));
  let t = work t in
  assert (Lines.prepared_count (session t) = 128);
  let t = run t "needle" |> finish in
  assert (List.length (Lines.results (session t)) = 1);
  assert ([%equal: Workspace.t] workspace (Ui_state.workspace t ~width ~height));
  let frame = Frame.render t ~width ~height in
  assert (Frame.Cursor.equal_shape (Option.value_exn frame.cursor).shape Bar);
  assert (List.is_empty frame.smear);
  let expected = Text_buffer.line_start (Editor.text (editor t)) 299
    + String.substr_index_exn (Text_buffer.line_text (Editor.text (editor t)) 299) ~pattern:"needle" in
  let t = run t "<CR>" in
  assert (Option.is_none (Ui_state.line_picker t));
  assert (Editor.cursor (editor t) = expected);
  assert (Option.is_some (Ui_state.cursor_position t ~width ~height));
  assert ((Ui_state.scroll t).top > 0);
  assert (String.equal contents (text t) && Editor.revision (editor t) = revision);
  assert (Editor.is_dirty (editor t));
  assert (Frame.Cursor.equal_shape (Option.value_exn (Frame.render t ~width ~height).cursor).shape Block)
;;

let%test_unit "line float zen, duplicates, no-match Enter, exact cancel and palette dispatch" =
  let initial = run (Helpers.ui "same\nsame\nlast\n") " vzG" in
  let baseline = Frame.to_string (Frame.render initial ~width ~height) in
  let t = run initial " fl" |> finish |> fun t -> run t "same" |> finish in
  assert (List.length (Lines.results (session t)) = 2);
  let t = run t "<C-n>" in
  assert ([%equal: int option] (Lines.selected (session t)) (Some 2));
  let t = run t "<C-w>zzzz" |> finish |> fun t -> run t "<CR>" in
  assert (Option.is_some (Ui_state.line_picker t));
  let t = run t "<Esc>" in
  assert (String.equal baseline (Frame.to_string (Frame.render t ~width ~height)));
  let t = run t " ccSearch current document lines<CR>" in
  assert (Option.is_none (Ui_state.palette t) && Option.is_some (Ui_state.line_picker t));
  let t = finish t in
  assert (List.length (Lines.results (session t)) = 4);
  assert (Ui_state.zen t)
;;

let%test_unit "line host focus/paste/resize/reopen isolation and shared one-float policy" =
  let initial = run (Helpers.ui "untouched") " vo" in
  let t = Ui_state.open_line_picker initial ~width ~height |> finish in
  let t = run t "<Esc>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Problems_tile.id);
  let t = Ui_state.open_line_picker t ~width ~height |> finish in
  let t = apply t (Helpers.paste "un<CR>touched") |> finish in
  assert (String.equal (Lines.query (session t)) "un touched");
  let old_generation = Ui_state.line_picker_generation t in
  let old_session = session t in
  let t = Helpers.run ~width:14 ~height:5 t [ Resize ] in
  assert (String.equal (Lines.query (session t)) "un touched");
  let t = apply t (Paste_start :: Helpers.keys "OLD") in
  let refused = Ui_state.open_line_picker t ~width ~height in
  assert (phys_equal old_session (session refused));
  let t = Helpers.run ~width:13 ~height:5 refused [ Resize ] in
  assert (Lines.closed old_session && Option.is_none (Ui_state.line_picker t));
  let t = Helpers.run ~width ~height t [ Resize ] in
  let t = apply t (Helpers.keys "remaining" @ [ Paste_end ]) in
  assert (String.equal (text t) "untouched");
  let t = Ui_state.open_line_picker t ~width ~height in
  let t = apply t [ Line_picker_work old_generation ] in
  assert (Lines.prepared_count (session t) = 0);
  let t = run t "<Esc> cc" in
  let t = Ui_state.open_line_picker t ~width ~height in
  assert (Option.is_none (Ui_state.palette t));
  let releases = ref 0 in
  let discovery : Ches_file_picker.Model.Discovery.t =
    { request = { run_id = Ches_file_picker.Model.Run_id.of_int 123; root = "/project" }
    ; candidates = []; status = Complete { truncated = false } } in
  let line_session = session t in
  let t = Ui_state.open_file_picker t ~width ~height ~discovery ~release:(fun () -> incr releases) in
  assert (Lines.closed line_session && Option.is_none (Ui_state.line_picker t));
  let t = Ui_state.open_line_picker t ~width ~height in
  assert (!releases = 1 && Option.is_none (Ui_state.file_picker t));
  List.iter [ 0, 0; 14, 4; 13, 100 ] ~f:(fun (width, height) ->
    let t = Helpers.run ~width ~height t [ Resize ] in
    assert (Option.is_none (Ui_state.line_picker t)))
;;

let%test_unit "invalidated host results cannot accept; truncation is visible in real frame" =
  let initial = Helpers.ui "original" in
  let t = run initial " fl" |> finish in
  let other = Ui_state.controller (Helpers.ui "replacement") in
  assert (not (Line_picker_tile.validate (picker t) other));
  let t = work t in
  assert (List.is_empty (Lines.results (session t)));
  let t = run t "<CR>" in
  assert (Option.is_none (Ui_state.line_picker t));
  assert (Editor.cursor (editor t) = 0 && String.equal (text t) "original");
  assert (String.is_substring (Option.value_exn (Ui_state.message t)).text ~substring:"invalidated");
  let t = run (Helpers.ui (String.make 4097 'x')) " fl" |> finish in
  assert (String.is_substring (Frame.to_string (Frame.render t ~width ~height)) ~substring:"TRUNCATED")
;;
