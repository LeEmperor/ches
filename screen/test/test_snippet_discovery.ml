open! Core
open Ches_core
open Ches_app
open Ches_screen
module U = Ches_completion.User_snippets
module Settings = Ches_config_runtime.Settings

let width = 100
let height = 25
let run t inputs = Helpers.run ~width ~height t inputs
let press t keys = run t (Helpers.keys keys)
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let picker t = Option.value_exn (Ui_state.snippet_picker t)
let selected t = Option.value_exn (Snippet_picker_tile.selected (picker t))
let open_picker t = press t " ccInsert snippet<CR>"
let create ?(path = "discovery.ml") initial =
  Ui_state.apply_configuration (Helpers.ui ~path initial)
    { Settings.default with completion_enabled = false
      ; snippets = [ U.Add { id = "test.discovery"; prefix = "unique_prefix"
          ; description = Some "café linked assignment"; scopes = []; collection = None
          ; body = "assign ${1:signal} = $1; ${2:value}$0" }
        ; U.Add { id = "test.scoped"; prefix = "sv_only"; description = None
          ; scopes = [ "systemverilog" ]; collection = None; body = "sv $0" } ] }
  |> Result.ok_or_failwith
;;

let%test_unit "configuration toggles survive late legacy load and restore picker insertion" =
  let toggle enabled = U.Set_collection_enabled { collection = "personal"; enabled } in
  let settings enabled = { Settings.default with snippets = [toggle enabled] } in
  let initial = Ui_state.apply_configuration (Helpers.ui ~path:"collections.txt" "keep")
      (settings false) |> Result.ok_or_failwith in
  let legacy = U.parse {|{"version":1,"snippets":[
    {"id":"personal.template","prefix":"zzcollection","collection":"personal.tools","body":"added $0"},
    {"id":"untagged","prefix":"zzcustom","body":"custom $0"}]}|} |> Or_error.ok_exn in
  let initial = Ui_state.receive_snippets initial ~generation:1 (Ok legacy) in
  let automatic = press initial "izzcollection" in
  assert (List.is_empty (Ui_state.completion_candidates automatic));
  let hidden = run (open_picker initial) (Helpers.paste "personal.tools") in
  assert (Option.is_none (Snippet_picker_tile.selected (picker hidden)));
  let untagged = run (open_picker initial) (Helpers.paste "zzcustom") in
  assert (String.equal (selected untagged).declaration.id "untagged");
  let restored = Ui_state.apply_configuration hidden (settings true) |> Result.ok_or_failwith in
  assert (Option.is_none (Ui_state.snippet_picker restored));
  let discovered = run (open_picker restored) (Helpers.paste "personal.tools") in
  assert (String.equal (selected discovered).declaration.id "personal.template");
  assert (String.is_substring (Frame.render discovered ~width ~height |> Frame.to_string)
    ~substring:"personal.tools");
  let inserted = press discovered "<CR>" in
  assert (String.equal (text inserted) "added keep");
  let removed = Ui_state.apply_configuration initial Settings.default |> Result.ok_or_failwith in
  let discovered = run (open_picker removed) (Helpers.paste "personal.tools") in
  assert (String.equal (selected discovered).declaration.id "personal.template")
;;

let%test_unit "explicit insertion ignores prefix, retains suffix, activates fields and one undo group without LSP or auto completion" =
  let initial = press (create "prefixTAIL") "6l" in
  let before_cursor = Editor.cursor (editor initial) in
  assert (before_cursor = 6);
  List.iter [ "unique_prefix"; "linked assignment"; "café" ] ~f:(fun query ->
    let opened = open_picker initial in
    assert (Option.is_some (Ui_state.snippet_picker opened));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view opened ~width ~height) Snippet_picker_tile.id);
    assert (Option.is_some (Ui_state.cursor_owner opened ~width ~height));
    let filtered = run opened (Helpers.paste query) in
    assert (String.equal (selected filtered).declaration.id "test.discovery");
    assert (String.equal (text filtered) "prefixTAIL");
    let inserted = press filtered "<CR>" in
    assert (Option.is_none (Ui_state.snippet_picker inserted));
    assert (Mode.equal (Editor.mode (editor inserted)) Insert);
    assert (not (Ui_state.completion_enabled inserted));
    assert (String.equal (text inserted) "prefixassign signal = signal; valueTAIL");
    assert (List.length (Ui_state.snippet_ranges inserted) = 2);
    let edited = press inserted "bus<Tab>42<Tab>" in
    assert (String.equal (text edited) "prefixassign bus = bus; 42TAIL");
    assert (List.is_empty (Ui_state.snippet_ranges edited));
    assert (String.equal (text (press edited "<Esc>u")) (text initial));
    let _, requests = Ui_state.take_source_requests edited in
    assert (List.is_empty requests))
;;

let%test_unit "picker scope, empty query result, cancellation, frame cursor and Unicode query paste never edit" =
  let initial = create "unchanged" in
  let revision = Editor.revision (editor initial) in
  let opened = open_picker initial in
  let frame = Frame.render opened ~width ~height |> Frame.to_string in
  assert (String.is_substring frame ~substring:"Insert snippet");
  let filtered = run opened (Helpers.paste "unique_prefix") in
  assert (String.is_substring (Frame.render filtered ~width ~height |> Frame.to_string)
    ~substring:"unique_prefix");
  assert (not (String.is_substring frame ~substring:"sv_only"));
  let unmatched = press opened "no_such_template_xyz<CR>" in
  assert (Option.is_some (Ui_state.snippet_picker unmatched));
  assert (Option.is_none (Snippet_picker_tile.selected (picker unmatched)));
  let cancelled = press unmatched "<Esc>" in
  assert (Option.is_none (Ui_state.snippet_picker cancelled));
  assert (Editor.revision (editor cancelled) = revision);
  assert (Mode.equal (Editor.mode (editor cancelled)) Normal);
  assert (String.equal (text cancelled) (text initial));
  let unicode = run (open_picker initial) (Helpers.paste "café") in
  assert (String.equal (Snippet_picker_tile.query (picker unicode)) "café");
  assert (String.equal (selected unicode).declaration.id "test.discovery");
  ignore (Frame.render unicode ~width:18 ~height:6 : Frame.t)
;;

let%test_unit "explicit insertion handles empty and Unicode anchors without consuming existing text" =
  List.iter [ "", "", 0; "é界TAIL", "2l", 5 ] ~f:(fun (original, movement, cursor) ->
    let initial = press (create original) movement in
    assert (Editor.cursor (editor initial) = cursor);
    let accepted = open_picker initial |> fun t -> press t "unique_prefix<CR>" in
    let expected = String.prefix original cursor ^ "assign signal = signal; value"
      ^ String.drop_prefix original cursor in
    assert (String.equal (text accepted) expected);
    assert (String.equal (text (press accepted "<Esc>u")) original))
;;

let%test_unit "explicit insertion in a long identifier is independent of completion prefix limits" =
  let prefix = String.make 4100 'x' in
  let original = prefix ^ "TAIL" in
  let initial = press (create original) "4100l" in
  assert (Editor.cursor (editor initial) = String.length prefix);
  let inserted = open_picker initial |> fun t -> press t "unique_prefix<CR>" in
  assert (String.equal (text inserted) (prefix ^ "assign signal = signal; valueTAIL"));
  assert (List.length (Ui_state.snippet_ranges inserted) = 2);
  let edited = press inserted "bus<Tab>42<Tab>" in
  assert (String.equal (text edited) (prefix ^ "assign bus = bus; 42TAIL"));
  assert (Editor.cursor (editor edited) = String.length prefix + String.length "assign bus = bus; 42");
  assert (String.equal (text (press edited "<Esc>u")) original)
;;

let%test_unit "middle-prefix insertion resolves filename and indentation with exact field and final cursors" =
  let initial = Ui_state.apply_configuration (Helpers.ui ~path:"dir/top.ml" "\t  triggerTAIL")
      { Settings.default with completion_enabled = false
        ; snippets = [ U.Add { id = "context"; prefix = "trigger"; description = None
            ; scopes = []; collection = None; body = "${1:${TM_FILENAME_BASE}}/$1\n${2:é}${0}!" } ] }
    |> Result.ok_or_failwith |> fun t -> press t "7l" in
  let base = String.length "\t  trig" in
  assert (Editor.cursor (editor initial) = base);
  let inserted = open_picker initial |> fun t -> press t "trigger<CR>" in
  assert (String.equal (text inserted) "\t  trigtop/top\n\t  é!gerTAIL");
  assert (Editor.cursor (editor inserted) = base + String.length "top");
  let second = press inserted "new<Tab>" in
  assert (String.equal (text second) "\t  trignew/new\n\t  é!gerTAIL");
  assert (Editor.cursor (editor second) = String.length "\t  trignew/new\n\t  é");
  let finished = press second "界<Tab>" in
  assert (String.equal (text finished) "\t  trignew/new\n\t  界!gerTAIL");
  assert (Editor.cursor (editor finished) = String.length "\t  trignew/new\n\t  界");
  assert (List.is_empty (Ui_state.snippet_ranges finished));
  assert (String.equal (text (press finished "<Esc>u")) (text initial))
;;

let%test_unit "picker close, focus change, interrupted paste and document switch cannot insert stale selection" =
  let initial = create "keep" in
  let opened = open_picker initial in
  let resized = Helpers.run ~width:10 ~height:2 opened [ Resize ] in
  assert (Option.is_none (Ui_state.snippet_picker resized));
  assert (String.equal (text resized) "keep");
  let replaced = Ui_state.open_line_picker opened ~width ~height in
  assert (Option.is_none (Ui_state.snippet_picker replaced));
  assert (Option.is_some (Ui_state.line_picker replaced));
  let pasting = run opened (Paste_start :: Helpers.keys "query") in
  let resized = Helpers.run ~width:10 ~height:2 pasting [ Resize ] in
  let finished = run resized (Helpers.keys "ifoo" @ [ Paste_end ]) in
  assert (String.equal (text finished) "keep");
  let root = Helpers.scratch_dir "ches-snippet-discovery-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let switched, _ = Ui_state.open_file opened ~width ~height (Filename.concat root "other.ml")
      |> Or_error.ok_exn in
    assert (Option.is_none (Ui_state.snippet_picker switched));
    assert (String.equal (text switched) "");
    let closed, did_close = Ui_state.close_current opened ~width ~height ~force:true in
    assert did_close;
    assert (Option.is_none (Ui_state.snippet_picker closed)))
;;

let%test_unit "configuration and snippet replies close captured catalog; stale generations do not disturb it" =
  let opened = open_picker (create "keep") in
  assert (phys_equal opened (Ui_state.receive_snippets opened ~generation:0 (Ok U.builtins)));
  let reloaded = Ui_state.receive_snippets opened ~generation:1 (Ok U.builtins) in
  assert (Option.is_none (Ui_state.snippet_picker reloaded));
  assert (String.equal (text reloaded) "keep");
  let applied = Ui_state.apply_configuration opened Settings.default |> Result.ok_or_failwith in
  assert (Option.is_none (Ui_state.snippet_picker applied));
  let pasting = run opened (Paste_start :: Helpers.keys "query") in
  let applied = Ui_state.apply_configuration pasting Settings.default |> Result.ok_or_failwith in
  let finished = run applied (Helpers.keys "ifoo" @ [ Paste_end ]) in
  assert (String.equal (text finished) "keep");
  let pending = press (create "keep") " ccReload configuration<CR>" |> open_picker in
  List.iter [ Ok Settings.default; Error "invalid configuration" ] ~f:(fun reply ->
    let received = Ui_state.receive_configuration pending ~generation:1 reply in
    assert (Option.is_none (Ui_state.snippet_picker received));
    assert (String.equal (text received) "keep"))
;;

let open_configuration t = press t " ccOpen configuration<CR>"

let%test_unit "reopening active unsaved configuration from a split returns input to its document" =
  let root = Helpers.scratch_dir "ches-config-split-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let config = Filename.concat root "config.ml" in
    let initial = Ui_state.with_configuration_path (create "original") (Ok config) in
    let dirty = open_configuration initial |> fun t -> press t "iunsaved<Esc>" in
    let owner = Session.context_id (Ui_state.session dirty) in
    List.iter [" vo ss"; " vo st"] ~f:(fun placement ->
      let focused = press dirty placement in
      assert (not (Ches_tile.View_id.equal (Ui_state.focused_view focused ~width ~height)
        (Ches_tile.View_id.of_string "document")));
      let reopened = open_configuration focused in
      assert (Option.equal Buffer_id.equal owner (Session.context_id (Ui_state.session reopened)));
      assert (String.equal (text reopened) "unsaved");
      assert (Option.is_none (Ui_state.active_tab_view reopened));
      let edited = press reopened "A!<Esc>" in
      assert (String.equal (text edited) "unsaved!"));
    assert (not (Sys_unix.file_exists_exn config)))
;;

let%test_unit "configuration action opens absent path without creating parents, preserves and reuses unsaved buffers" =
  let root = Helpers.scratch_dir "ches-open-configuration-" in
  Exn.protect ~finally:(fun () -> Core_unix.rmdir root) ~f:(fun () ->
    let config = Filename.concat root "missing-parent/config.ml" in
    let initial = press (create "original") "A dirty<Esc>" in
    let original_id = Session.context_id (Ui_state.session initial) |> Option.value_exn in
    let initial = Ui_state.with_configuration_path initial (Ok config) in
    let opened = open_configuration initial in
    assert (String.equal (Option.value_exn (Editor.path (editor opened))) config);
    assert (String.equal (text opened) "");
    assert (not (Sys_unix.file_exists_exn (Filename.dirname config)));
    let config_id = Session.context_id (Ui_state.session opened) |> Option.value_exn in
    let dirty = press opened "i(* unsaved *)<Esc>" in
    let switched = Ui_state.activate_buffer dirty ~width ~height original_id |> Or_error.ok_exn in
    assert (String.equal (text switched) "original dirty");
    let reopened = open_configuration switched in
    assert (Option.value_exn (Session.context_id (Ui_state.session reopened)) |> Buffer_id.equal config_id);
    assert (String.equal (text reopened) "(* unsaved *)");
    assert (List.length (Session.buffers (Ui_state.session reopened)) = 2);
    assert (not (Sys_unix.file_exists_exn (Filename.dirname config))))
;;

let%test_unit "configuration path resolution errors use feedback and leave the current document intact" =
  let initial = create "keep" in
  let failed = Ui_state.with_configuration_path initial (Error "No configuration home")
    |> open_configuration in
  assert (String.equal (text failed) "keep");
  assert (String.is_substring (Option.value_exn (Ui_state.message failed)).text
    ~substring:"No configuration home")
;;
