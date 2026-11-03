open! Core
open Ches_core
open Ches_app
open Ches_screen
module Theme = Ches_theme.Theme

let width = 100
let height = 25
let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let editor t = Controller.editor (Ui_state.controller t)
let picker t = Option.value_exn (Ui_state.theme_picker t)
let selected t = Option.value_exn (Theme_picker_tile.selected (picker t))
let create ?(bare = false) ?report ?(theme = Theme.default) () =
  Ui_state.create ~bare ?report ~theme (Controller.create
    (Editor.create ~path:"theme.ml" ~cell_width:Cell_map.width
       (Text_buffer.of_string "let answer = 42\n" |> Result.ok |> Option.value_exn)))
;;

let%test_unit "live preview, navigation, original cancellation and acceptance" =
  let initial = create () in
  let revision = Editor.revision (editor initial) in
  let _, highlights = Controller.highlights (Ui_state.controller initial) in
  let text = Text_buffer.to_string (Editor.text (editor initial)) in
  let opened = run initial " vT" in
  assert (Theme.equal (selected opened) Theme.default);
  let moved = run opened "<Tab><Tab><C-n><S-Tab><C-p>" in
  assert (not (Theme.equal (Ui_state.theme moved) Theme.default));
  assert (Theme.equal (Ui_state.theme moved) (selected moved));
  let cancelled = run moved "<Esc>" in
  assert (Option.is_none (Ui_state.theme_picker cancelled));
  assert (Theme.equal (Ui_state.theme cancelled) Theme.default);
  let accepted = run moved "<CR>" in
  assert (Option.is_none (Ui_state.theme_picker accepted));
  assert (Theme.equal (Ui_state.theme accepted) (selected moved));
  assert (Theme.equal (selected (run accepted " vT")) (Ui_state.theme accepted));
  let cancelled_again = run accepted " vT<Tab><Tab><Tab><C-p><Esc>" in
  assert (Theme.equal (Ui_state.theme cancelled_again) (Ui_state.theme accepted));
  List.iter [ moved; cancelled; accepted ] ~f:(fun t ->
    assert (Editor.revision (editor t) = revision);
    assert (phys_equal highlights (snd (Controller.highlights (Ui_state.controller t))));
    assert (String.equal text (Text_buffer.to_string (Editor.text (editor t)))));
  assert (Editor.revision (editor (run accepted "u")) = revision)
;;

let%test_unit "filter previews, no match cannot commit, cancel restores original after filtering" =
  let target = List.last_exn Theme.all in
  let opened = run (create ()) " vT" in
  let filtered = Helpers.run ~width ~height opened (Helpers.paste (Theme.title target)) in
  assert (Theme.equal (Ui_state.theme filtered) target);
  let unmatched = run filtered "zzzzzzzzzzzzzzzz" in
  assert (Option.is_none (Theme_picker_tile.selected (picker unmatched)));
  assert (Theme.equal (Ui_state.theme unmatched) target);
  let unmatched = run unmatched "<CR>" in
  assert (Option.is_some (Ui_state.theme_picker unmatched));
  assert (Theme.equal (Ui_state.theme (run unmatched "<Esc>")) Theme.default)
;;

let%test_unit "bare and zen preserve presentation, numbers and document while picker owns cursor" =
  List.iter [ ""; " vz"; " vB" ] ~f:(fun presentation ->
    let initial = run (create ()) presentation in
    let prefs = Ui_state.prefs initial and bare_prefs = Ui_state.bare_prefs initial in
    let opened = run initial " vT<Tab>" in
    assert (Presentation.equal (Ui_state.presentation initial) (Ui_state.presentation opened));
    assert (Geometry.Prefs.equal prefs (Ui_state.prefs opened));
    assert (Presentation.Bare_prefs.equal bare_prefs (Ui_state.bare_prefs opened));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view opened ~width ~height) Theme_picker_tile.id);
    let frame = Frame.render opened ~width ~height in
    assert (Option.is_some frame.cursor);
    assert (List.is_empty frame.smear);
    let resized = Helpers.run ~width:10 ~height:2 opened [ Resize ] in
    assert (Option.is_none (Ui_state.theme_picker resized));
    assert (Theme.equal (Ui_state.theme resized) Theme.default);
    assert (Presentation.equal (Ui_state.presentation initial) (Ui_state.presentation resized)))
;;

let%test_unit "interrupted picker paste never enters document" =
  let initial = create ~bare:true () in
  let opened = run initial " vT<Tab>" in
  let pasting = Helpers.run ~width ~height opened
      (Paste_start :: Helpers.keys "query") in
  let resized = Helpers.run ~width:10 ~height:2 pasting [ Resize ] in
  let finished = Helpers.run ~width ~height resized (Helpers.keys "ifoo" @ [ Paste_end ]) in
  assert (Option.is_none (Ui_state.theme_picker finished));
  assert (Theme.equal (Ui_state.theme finished) Theme.default);
  assert (Editor.revision (editor finished) = Editor.revision (editor initial));
  assert (String.equal (Text_buffer.to_string (Editor.text (editor finished)))
    (Text_buffer.to_string (Editor.text (editor initial))))
;;

let%test_unit "global palette IDs are identical in bare and workspace, theme opens from palette" =
  let ids t =
    let palette = Ui_state.palette (run t " cc") |> Option.value_exn |> Palette_tile.palette in
    Ches_palette.Palette.results palette |> List.map ~f:(fun r ->
      Ches_palette.Catalog.Entry.id r.item |> Ches_palette.Catalog.Id.to_string) in
  let workspace = create () and bare = create ~bare:true () in
  assert ([%equal: string list] (ids workspace) (ids bare));
  assert (List.mem (ids bare) "appearance.choose-theme" ~equal:String.equal);
  let t = run bare " ccChoose theme<CR>" in
  assert (Ui_state.bare t && Option.is_some (Ui_state.theme_picker t))
;;

let%test_unit "colored frame cache redraws on effective theme identity including direct get" =
  let cache = Frame.Cache.create () in
  let initial = run (create ()) " vT" in
  let draws = ref 0 in
  let draw_base _ = incr draws; Theme.id (Ui_state.theme initial) in
  ignore (Frame.Cache.get cache initial ~width ~height ~draw_base : Frame.t * string);
  let changed = run initial "<Tab>" in
  ignore (Frame.Cache.get cache changed ~width ~height ~draw_base : Frame.t * string);
  assert (!draws = 2);
  ignore (Frame.Cache.get cache changed ~width ~height ~draw_base : Frame.t * string);
  assert (!draws = 2)
;;

let%test_unit "view-local commands augment globals only over the installed focused view" =
  let ids t =
    let palette = Ui_state.palette t |> Option.value_exn |> Palette_tile.palette in
    Ches_palette.Palette.results palette |> List.map ~f:(fun r ->
      Ches_palette.Catalog.Entry.id r.item |> Ches_palette.Catalog.Id.to_string) in
  let globals = ids (run (create ~bare:true ()) " cc") in
  let local = ids (run (create ~report:Report_tile.demo ()) " vD cc") in
  assert (List.length local > List.length globals);
  assert (not (List.mem local "development.insert-demo-snippet" ~equal:String.equal));
  assert (List.for_all globals ~f:(fun id ->
     List.mem [ "development.insert-demo-snippet"; "snippets.insert" ] id ~equal:String.equal
     || List.mem local id ~equal:String.equal));
  let all_globals = Ches_palette.Catalog.entries Ches_palette.Catalog.default
    |> List.map ~f:(fun entry -> Ches_palette.Catalog.Entry.id entry
      |> Ches_palette.Catalog.Id.to_string) in
  assert ([%equal: string list] globals all_globals);
  let over_document = ids (run (create ~report:Report_tile.demo ()) " cc") in
  assert ([%equal: string list] over_document globals)
;;

let%test_unit "another float cancels preview, and picker cancellation returns to its view" =
  let initial = create ~report:Report_tile.demo () in
  let opened = run initial " vD vT<Tab>" in
  let closed = run opened "<Esc>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view closed ~width ~height) Report_tile.id);
  assert (Theme.equal (Ui_state.theme closed) Theme.default);
  let replaced = Ui_state.open_line_picker opened ~width ~height in
  assert (Option.is_none (Ui_state.theme_picker replaced));
  assert (Option.is_some (Ui_state.line_picker replaced));
  assert (Theme.equal (Ui_state.theme replaced) Theme.default)
;;

let%test_unit "custom initial and committed choices stay global across presentation changes" =
  let theme = List.last_exn Theme.all in
  let initial = create ~theme () in
  assert (Theme.equal (Ui_state.theme initial) theme);
  assert (Theme.equal (selected (run initial " vT")) theme);
  let committed = run initial " vT<C-p><CR>" in
  let choice = Ui_state.theme committed in
  List.iter [ " vz"; " vB"; " vz vB"; " vB vB" ] ~f:(fun keys ->
    let t = run committed keys in
    assert (Theme.equal (Ui_state.theme t) choice);
    let t = run t " vT<C-p><C-p><Esc>" in
    assert (Theme.equal (Ui_state.theme t) choice))
;;
