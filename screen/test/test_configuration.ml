open! Core
open Ches_core
open Ches_app
open Ches_screen
module Settings = Ches_config_runtime.Settings
module Theme = Ches_theme.Theme

let press t s = Helpers.run ~width:100 ~height:25 t (Helpers.keys s)
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let apply ?theme_override t settings =
  Ui_state.apply_configuration ?theme_override t settings |> Result.ok_or_failwith
let reload t = press t " ccconfiguration.reload<CR>"
let configured = { Settings.completion_enabled = false
  ; completion_ghost_preview = true; completion_min_prefix_chars = 3
  ; completion_prefer_local_snippets = false; line_numbers = true
  ; theme = Theme.id (List.last_exn Theme.all) }

let%test_unit "startup application is explicit; session toggles and removed fields reset on reload" =
  let t = Helpers.ui "unsaved" in
  let _, requests = Ui_state.take_config_reload_requests t in
  assert (List.is_empty requests);
  let t = apply t configured in
  assert (not (Ui_state.completion_enabled t) && Ui_state.completion_ghost_enabled t);
  assert (Line_numbers.equal (Ui_state.prefs t).line_numbers Absolute);
  let t = press t " cccompletion.toggle<CR> cccompletion.ghost<CR>A edit<Esc>" in
  assert (Ui_state.completion_enabled t && not (Ui_state.completion_ghost_enabled t));
  let snapshot = text t and revision = Editor.revision (editor t) in
  let t, requests = Ui_state.take_config_reload_requests (reload t) in
  assert ([%equal: int list] requests [1]);
  let _, requests = Ui_state.take_config_reload_requests t in
  assert (List.is_empty requests);
  let t = Ui_state.receive_configuration t ~generation:1 (Ok configured) in
  assert (not (Ui_state.completion_enabled t) && Ui_state.completion_ghost_enabled t);
  let t = reload t |> fun t -> Ui_state.receive_configuration t ~generation:2 (Ok Settings.default) in
  assert (Ui_state.completion_enabled t && not (Ui_state.completion_ghost_enabled t));
  assert (Line_numbers.equal (Ui_state.prefs t).line_numbers Off);
  assert (Theme.equal (Ui_state.theme t) Theme.default);
  assert (String.equal snapshot (text t) && revision = Editor.revision (editor t));
  let _, requests = Ui_state.take_source_requests t in
  assert (List.is_empty requests);
  let _, requests = Ui_state.take_file_requests t in
  assert (List.is_empty requests)
;;

let%test_unit "invalid theme and invalid prefix are atomic even with a CLI override and live completion" =
  let t = press (Helpers.ui "\nfoobar") "if" in
  assert (not (List.is_empty (Ui_state.completion_candidates t)));
  let candidates = Ui_state.completion_candidates t in
  List.iter [ { configured with theme = "missing-theme" }
            ; { configured with completion_min_prefix_chars = 0 } ] ~f:(fun settings ->
    assert (Result.is_error (Ui_state.apply_configuration ~theme_override:Theme.default t settings));
    assert (Ui_state.completion_enabled t && not (Ui_state.completion_ghost_enabled t));
    assert (List.equal Ches_completion.Model.Candidate.equal candidates (Ui_state.completion_candidates t));
    assert (String.equal (text t) "f\nfoobar"));
  let applied = apply t configured in
  assert (List.is_empty (Ui_state.completion_candidates applied));
  assert (String.equal (text t) (text applied))
;;

let%test_unit "latest generation only; failure preserves settings and duplicate result is ignored" =
  let t = apply (Helpers.ui "dirty") configured |> reload |> reload in
  let t, requests = Ui_state.take_config_reload_requests t in
  assert ([%equal: int list] requests [1; 2]);
  let stale = Ui_state.receive_configuration t ~generation:1 (Ok Settings.default) in
  assert (phys_equal t stale);
  let failed = Ui_state.receive_configuration t ~generation:2 (Error "compile failed") in
  assert (not (Ui_state.completion_enabled failed));
  assert (Theme.equal (Ui_state.theme t) (Ui_state.theme failed));
  assert (Geometry.Prefs.equal (Ui_state.prefs t) (Ui_state.prefs failed));
  assert (String.equal (text t) (text failed));
  assert (phys_equal failed (Ui_state.receive_configuration failed ~generation:2 (Ok Settings.default)))
;;

let%test_unit "invalid reload preserves live completion and unsaved buffer" =
  let t = reload (Helpers.ui "\nfoobar") |> fun t -> press t "if" in
  let candidates = Ui_state.completion_candidates t in
  assert (not (List.is_empty candidates));
  let failed = Ui_state.receive_configuration t ~generation:1
      (Ok { configured with theme = "does-not-exist" }) in
  assert (List.equal Ches_completion.Model.Candidate.equal candidates
    (Ui_state.completion_candidates failed));
  assert (Ui_state.completion_enabled failed && not (Ui_state.completion_ghost_enabled failed));
  assert (Editor.revision (editor failed) = Editor.revision (editor t));
  assert (String.equal (text failed) (text t))
;;

let%test_unit "screen forwards configured local snippet priority to provider merges" =
  let module M = Ches_completion.Model in
  List.iter [true; false] ~f:(fun prefer ->
    let t = Ui_state.create ~source_attached:true
        (Ui_state.controller (Helpers.ui ~path:"module.sv" "")) in
    let t = apply t { Settings.default with completion_prefer_local_snippets = prefer }
      |> fun t -> press t "iaff" in
    let t, requests = Ui_state.take_source_requests t in
    let request = List.find_map_exn requests ~f:(function
      | Ches_error.Source_request.Complete request -> Some request | _ -> None) in
    let candidate : M.Candidate.t =
      { id = "lsp-word"; source = Lsp "test"; label = "aff-server"; detail = None
      ; filter_text = "aff-server"; sort_text = "000"
      ; primary = { start = 0; stop = 3; text = "aff-server" }
      ; additional = []; cursor = 10; snippet = None } in
    let t = Helpers.run t [Source (Completion { token = request.token; source = "test"
      ; candidates = [candidate]; incomplete = false })] in
    let candidates = Ui_state.completion_candidates t in
    assert (List.exists candidates ~f:(fun c -> M.Candidate.equal_source c.source Snippet));
    let first = List.hd_exn candidates in
    assert (if prefer then M.Candidate.equal_source first.source Snippet
      else String.equal first.id "lsp-word"))
;;

let%test_unit "line numbers update both profiles without resetting layout; theme application cancels preview" =
  let prefs = { Geometry.Prefs.default with width = 73; offset = 9; left_padding = 5 } in
  List.iter [false; true] ~f:(fun bare ->
    let t = Ui_state.create ~prefs ~bare ~tiles_visible:false
        (Ui_state.controller (Helpers.ui "keep")) in
    let workspace = Ui_state.workspace_prefs t in
    let t = press t " vT<Tab>" in
    assert (Option.is_some (Ui_state.theme_picker t));
    let t = apply t configured in
    assert (Option.is_none (Ui_state.theme_picker t));
    assert (String.equal (Theme.id (Ui_state.theme t)) configured.theme);
    assert (Geometry.Prefs.equal (Ui_state.prefs t) { prefs with line_numbers = Absolute });
    assert (Line_numbers.equal (Ui_state.bare_prefs t).line_numbers Absolute);
    assert (Workspace.Prefs.equal workspace (Ui_state.workspace_prefs t));
    let t = apply t Settings.default in
    assert (Line_numbers.equal (Ui_state.prefs t).line_numbers Off);
    assert (Line_numbers.equal (Ui_state.bare_prefs t).line_numbers Off);
    assert (String.equal (text t) "keep"))
;;

let%test_unit "explicit startup theme and apply override persist across reloads" =
  let chosen = List.nth_exn Theme.all 1 in
  let assembly = Ui_state.create ~theme:chosen (Ui_state.controller (Helpers.ui "")) in
  let t = apply assembly configured in
  assert (Theme.equal (Ui_state.theme t) chosen);
  let t = reload t |> fun t -> Ui_state.receive_configuration t ~generation:1 (Ok Settings.default) in
  assert (Theme.equal (Ui_state.theme t) chosen);
  let t = apply ~theme_override:Theme.default t configured in
  let t = reload t |> fun t -> Ui_state.receive_configuration t ~generation:2 (Ok configured) in
  assert (Theme.equal (Ui_state.theme t) Theme.default)
;;

let%test_unit "minimum prefix counts Unicode characters; manual and punctuation bypass; reload restores default" =
  let settings = { Settings.default with completion_min_prefix_chars = 2 } in
  let initial = apply (Helpers.ui "\néclair éclat") settings in
  let one = Helpers.run initial (Helpers.keys "i" @ Helpers.paste "é") in
  (* Paste suppresses automatic completion; insert another character then backspace. *)
  let one = press one "x<BS>" in
  assert (List.is_empty (Ui_state.completion_candidates one));
  let two = press one "c" in
  assert (not (List.is_empty (Ui_state.completion_candidates two)));
  let manual = press one "<C-n>" in
  assert (not (List.is_empty (Ui_state.completion_candidates manual)));
  let t = apply (Helpers.ui "\nfoobar") settings |> fun t -> press t "if" in
  assert (List.is_empty (Ui_state.completion_candidates t));
  let t = press t "<Esc>" |> reload in
  let t = Ui_state.receive_configuration t ~generation:1 (Ok Settings.default) |> fun t -> press t "af" in
  (* ff has no matches, but a single f in a new word does after defaults reset. *)
  let t = press t " f" in
  assert (not (List.is_empty (Ui_state.completion_candidates t)));
  let t = Ui_state.create ~source_attached:true (Ui_state.controller (Helpers.ui "")) in
  let t = apply t { settings with completion_min_prefix_chars = 5000 } |> fun t -> press t "i." in
  let _, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function
    | Ches_error.Source_request.Complete { trigger = Character "."; _ } -> true | _ -> false))
;;
