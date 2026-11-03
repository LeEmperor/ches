open! Core
open Ches_core
open Ches_app
open Ches_screen
module Q = Ches_error.Language_query

let width = 100
let height = 25
let run t inputs = Helpers.run ~width ~height t inputs
let press t keys = run t (Helpers.keys keys)
let editor t = Controller.editor (Ui_state.controller t)
let create ?keymap_config ?(path = "/tmp/signatures.ml") text =
  let text = Text_buffer.of_string text |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith in
  Ui_state.create ~source_attached:true ~tiles_visible:false
    (Controller.create ?keymap_config (Editor.create ~path ~cell_width:Cell_map.width text))
let queries t =
  let t, requests = Ui_state.take_source_requests t in
  t, List.filter_map requests ~f:(function Ches_error.Source_request.Query q -> Some q | _ -> None)
let request t keys =
  let t, requests = queries (press t keys) in
  t, List.last_exn requests
let reply t (request : Q.request) result =
  run t [Source (Query_result { token = request.token; cursor = request.cursor
    ; kind = request.kind; source = "fake"; result })]
let payload : Q.signature_help =
  { signatures =
      [ { label = "f(😀, 界é)"; documentation = [{kind = Markdown; value = "Function documentation"}]
        ; parameters = [{label_start = 2; label_stop = 6; documentation = []}
            ; {label_start = 8; label_stop = 13; documentation = [{kind = Plaintext; value = "Argument docs"}]}]
        ; active_parameter = Some 1 }
      ; {label = "alternate(x)"; documentation = []; parameters = []; active_parameter = None} ]
  ; active_signature = 0; active_parameter = Some 0 }
let opened t keys =
  let t, q = request t keys in
  reply t q (Signature_result (Some payload))
let shown t = Option.is_some (Ui_state.signature_help t)
let rendered t = Frame.to_string (Frame.render t ~width ~height)

let%test_unit "manual Normal and Insert Ctrl-k and palette bypass the automatic toggle" =
  List.iter ["<C-k>"; "i<C-k>"; " ccSignature help<CR>"] ~f:(fun keys ->
    let t = press (create "abc") " ccToggle automatic signature help<CR>" in
    assert (not (Ui_state.signature_help_enabled t));
    let t, q = request t keys in
    assert (match q.kind with Signature_help {automatic = false; character = None; retrigger = false} -> true | _ -> false);
    assert (shown (reply t q (Signature_result (Some payload)))))
;;

let%test_unit "Unicode byte parameter highlight documentation overload count and Insert-only cycling" =
  let t = opened (create "abc") "i<C-k>" in
  let spans = Signature_overlay.rows (Option.value_exn (Ui_state.signature_help t)) in
  let highlighted = List.filter (List.hd_exn spans) ~f:(fun span -> Style.equal span.Span.style Pending) in
  assert (String.equal (String.concat (List.map highlighted ~f:(fun span -> span.Span.text))) "界é");
  assert (String.is_substring (rendered t) ~substring:"Argument docs");
  assert (String.is_substring (rendered t) ~substring:"Signature 1/2");
  let next = press t "<C-g>" in
  assert (String.is_substring (rendered next) ~substring:"alternate(x)");
  let previous = press next "<C-b>" in
  assert (String.is_substring (rendered previous) ~substring:"f(😀, 界é)");
  assert (Mode.equal (Editor.mode (editor previous)) Insert);
  assert (Editor.cursor (editor previous) = 0);
  assert (not (shown (press previous "<Esc>")));
  let normal = opened (create "abc") "<C-k>" in
  assert (not (String.is_substring (rendered (press normal "<C-g>")) ~substring:"alternate(x)"))
;;

let%test_unit "invalid byte boundaries never split Unicode labels" =
  let signature = List.hd_exn payload.signatures in
  let payload = { payload with signatures = [{signature with
    parameters = [{label_start = 3; label_stop = 6; documentation = []}]; active_parameter = Some 0}] } in
  let rows = Signature_overlay.rows (Signature_overlay.create payload) in
  assert (List.for_all (List.hd_exn rows) ~f:(fun span -> not (Style.equal span.Span.style Pending)));
  assert (List.for_all (List.concat rows) ~f:(fun span -> Stdlib.String.is_valid_utf_8 span.Span.text))
;;

let%test_unit "Normal Ctrl-k respects configured bindings, counts and pending search" =
  let module I = Ches_input in
  let normal = I.Bindings.create [[I.Key.Ctrl 'k'], Move Right] |> Or_error.ok_exn in
  let keymap_config = {I.Keymap.Config.default with normal} in
  let t, qs = queries (press (create ~keymap_config "abc") "<C-k>") in
  assert (Editor.cursor (editor t) = 1);
  assert (List.is_empty qs);
  List.iter ["2<C-k>"; "/<C-k>"] ~f:(fun keys ->
    let _, qs = queries (press (create "abc") keys) in
    assert (List.is_empty qs))
;;

let%test_unit "cycling to a shorter overload normalizes its fallback argument" =
  let signature : Q.signature =
    { label = "g(x)"; documentation = []; active_parameter = None
    ; parameters = [{label_start = 2; label_stop = 3; documentation = []}] } in
  List.iter [Some 1; None] ~f:(fun active_parameter ->
    let help = {payload with signatures = payload.signatures @ [signature]; active_parameter} in
    let overlay = Signature_overlay.create help |> fun t -> Signature_overlay.cycle t 2 in
    let row = List.hd_exn (Signature_overlay.rows overlay) in
    assert (List.exists row ~f:(fun span -> Style.equal span.Span.style Pending && String.equal span.text "x")))
;;

let%test_unit "automatic intents follow actual edits and delayed space flush, not held keys or paste" =
  let t, qs = queries (press (create "") "ia") in
  assert (List.length qs = 1);
  assert (match (List.hd_exn qs).kind with Signature_help {automatic = true; character = Some "a"; retrigger = false} -> true | _ -> false);
  let t = reply t (List.hd_exn qs) (Signature_result (Some payload)) in
  let t, qs = queries (press t " ") in
  assert (List.is_empty qs);
  let t = run t [Toggle_tick (Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 1.))] in
  let t, qs = queries t in
  assert (List.length qs = 1);
  assert (match (List.hd_exn qs).kind with Signature_help {character = Some " "; retrigger = true; _} -> true | _ -> false);
  let t, qs = queries (run t (Helpers.paste "pasted")) in
  assert (List.is_empty qs);
  assert (not (shown t));
  let t = press t "<Esc> ccToggle automatic signature help<CR>" in
  let _, qs = queries (press t "ia") in
  assert (List.is_empty qs)
;;

let%test_unit "jk's inserted first character requests help and its escape cancels; following literal edit sends its own character" =
  let t, qs = queries (press (create "") "ij") in
  assert (match (List.last_exn qs).kind with Signature_help {character = Some "j"; _} -> true | _ -> false);
  let _, qs = queries (press t "k") in
  assert (List.is_empty qs);
  let t, qs = queries (press t "x") in
  assert (String.equal (Text_buffer.to_string (Editor.text (editor t))) "jx");
  assert (match (List.last_exn qs).kind with Signature_help {character = Some "x"; _} -> true | _ -> false)
;;

let%test_unit "stale cursor revision mode focus supersession server stop and module changes reject replies" =
  let t, q = request (create "abc") "i<C-k>" in
  let check t = assert (not (shown (reply t q (Signature_result (Some payload))))) in
  List.iter ["<Right>"; "x"; "<Esc>"; "<C-Space>"; "<C-k>"; "<Esc> cc"] ~f:(fun keys -> check (press t keys));
  check (run t [Source (Stopped {source = "fake"; root = "/tmp"; reason = "stopped"})]);
  check (run t [Source (Instance_context_changed { source = "fake"; revision = 1; module_name = Some "other"; hier_path = None })]);
  let cancelled, requests = Ui_state.take_source_requests (press t "<Esc>") in
  assert (List.exists requests ~f:(function Cancel_query token -> Ches_completion.Model.Token.equal token q.token | _ -> false));
  assert (not (shown cancelled))
;;

let%test_unit "automatic failure is silent manual failure explains and successful empty result clears" =
  let t, q = request (create "abc") "ia" in
  let failed = reply t q (Failed "unsupported automatic") in
  assert (not (shown failed));
  assert (not (String.is_substring (rendered failed) ~substring:"unsupported automatic"));
  let t, q = request failed "<C-k>" in
  let failed = reply t q (Failed "manual unavailable") in
  assert (String.is_substring (rendered failed) ~substring:"manual unavailable");
  assert (not (shown (reply t q (Signature_result None))))
;;

let%test_unit "displayed Normal help keeps its cursor and cannot revive after movement or context reload" =
  let initial = press (create "abc") "l" in
  let t = opened initial "<C-k>" in
  assert (shown t && Editor.cursor (editor t) = 1);
  assert (Mode.equal (Editor.mode (editor t)) Normal);
  ignore (rendered t : string);
  assert (Option.equal Frame.Cursor.equal
    (Frame.render initial ~width ~height).cursor (Frame.render t ~width ~height).cursor);
  assert (shown t && Editor.cursor (editor t) = 1);
  assert (not (shown (press t "lh")));
  let other, _ = Ui_state.open_file t ~width ~height "/tmp/signatures-other.ml" |> Or_error.ok_exn in
  let returned, _ = Ui_state.open_file other ~width ~height "/tmp/signatures.ml" |> Or_error.ok_exn in
  assert (not (shown returned));
  assert (not (shown (press t " ccconfiguration.reload<CR>")));
  assert (not (shown (run t [Source (Instance_context_changed
    {source = "fake"; revision = 1; module_name = None; hier_path = None})])))
;;

let%test_unit "multiline labels and large documentation have bounded escaped rendering" =
  let signature : Q.signature =
    {label = "f(\n😀\027" ^ String.make 65000 'x'; parameters = []; active_parameter = None
    ; documentation = [{kind = Markdown; value = String.make 65000 '\n'}]} in
  let rows = Signature_overlay.rows (Signature_overlay.create
    {signatures = [signature]; active_signature = 0; active_parameter = None}) in
  assert (List.length rows <= 4);
  let spans = List.concat rows in
  assert (List.sum (module Int) spans ~f:(fun span -> String.length span.Span.text) < 5000);
  assert (List.for_all spans ~f:(fun span ->
    Stdlib.String.is_valid_utf_8 span.Span.text
    && not (String.exists span.text ~f:(fun c -> Char.equal c '\n' || Char.equal c '\027'))))
;;

let%test_unit "block insertion suppresses both automatic intents and manual help" =
  let t = press (create "abc\ndef") "<C-v>jIx<C-k>" in
  assert (not (List.is_empty (Editor.block_insert_points (editor t))));
  let _, qs = queries t in
  assert (List.is_empty qs)
;;

let%test_unit "completion and signatures coexist on opposite sides without moving the input cursor" =
  let t = press (create "alpha alphabet\n\n\n\n\n\n") "5ji" in
  let t, q = request t "al<C-k>" in
  let t = reply t q (Signature_result (Some payload)) in
  assert (shown t);
  assert (not (List.is_empty (Ui_state.completion_candidates t)));
  let frame = rendered t in
  assert (String.is_substring frame ~substring:"Signature 1/2");
  assert (String.is_substring frame ~substring:"[buffer]");
  assert (Mode.equal (Editor.mode (editor t)) Insert)
;;

let%test_unit "atomic configuration signature setting validates before changing state" =
  let t = opened (create "abc") "<C-k>" in
  let settings = {Ches_config_runtime.Settings.default with signature_help_enabled = false} in
  let invalid = {settings with theme = "missing-theme"} in
  assert (Result.is_error (Ui_state.apply_configuration t invalid));
  assert (shown t && Ui_state.signature_help_enabled t);
  let applied = Ui_state.apply_configuration t settings |> Result.ok_or_failwith in
  assert (not (shown applied) && not (Ui_state.signature_help_enabled applied))
;;

let%test_unit "companion switches reuse unsaved target cursor, multiple picker and jump history; missing never creates" =
  let root = Helpers.scratch_dir "ches-companions-" in
  let a = Filename.concat root "a.ml" and b = Filename.concat root "a.mli"
  and c = Filename.concat root "other.mli" and missing = Filename.concat root "missing.mli" in
  List.iter [a; b; c] ~f:(fun path -> Out_channel.write_all path ~data:"abcdef");
  Exn.protect ~finally:(fun () -> List.iter [a; b; c] ~f:Core_unix.unlink; Core_unix.rmdir root) ~f:(fun () ->
    let initial = create ~path:a "abcdef" in
    let retained, _ = Ui_state.open_file initial ~width ~height b |> Or_error.ok_exn in
    let dirty = press retained "iDIRTY<Esc>ll" in
    let cursor = Editor.cursor (editor dirty) in
    let origin, _ = Ui_state.open_file dirty ~width ~height a |> Or_error.ok_exn in
    let pending, q = request origin " ccSwitch interface/implementation<CR>" in
    assert (Q.equal_kind q.kind Companion_files);
    let jumped = reply pending q (Companions [b]) in
    assert (Option.equal String.equal (Editor.path (editor jumped)) (Some b));
    assert (Editor.is_dirty (editor jumped) && Editor.cursor (editor jumped) = cursor);
    let back = press jumped "<C-o>" in
    assert (Option.equal String.equal (Editor.path (editor back)) (Some a));
    let forward = press back "<C-i>" in
    assert (Option.equal String.equal (Editor.path (editor forward)) (Some b));
    assert (Editor.cursor (editor forward) = cursor);
    let picker = reply pending q (Companions [b; c]) in
    assert (Option.is_some (Ui_state.destinations picker));
    assert (String.is_substring (rendered picker) ~substring:"Choose counterpart");
    let chosen = press picker "<CR>" in
    assert (Option.equal String.equal (Editor.path (editor chosen)) (Some b));
    assert (Editor.cursor (editor chosen) = cursor);
    let missing_picker = reply pending q (Companions [missing; c]) in
    assert (Option.is_some (Ui_state.destinations missing_picker));
    let failed_selection = press missing_picker "missing<CR>" in
    assert (Option.equal String.equal (Editor.path (editor failed_selection)) (Some a));
    List.iter [Q.Companions [missing]; Companions []; Failed "unavailable"] ~f:(fun result ->
      let failed = reply pending q result in
      assert (Option.equal String.equal (Editor.path (editor failed)) (Some a)));
    assert (not (Sys_unix.file_exists_exn missing)))
;;

let%test_unit "invalid counterpart targets leave cursor and jump history intact" =
  let root = Helpers.scratch_dir "ches-companion-errors-" in
  let a = Filename.concat root "a.ml" and b = Filename.concat root "a.mli"
  and bad = Filename.concat root "bad.mli" and denied = Filename.concat root "denied.mli" in
  List.iter [a; b; denied] ~f:(fun path -> Out_channel.write_all path ~data:"abcdef");
  Out_channel.write_all bad ~data:"\255";
  Core_unix.chmod denied ~perm:0;
  Exn.protect ~finally:(fun () ->
    Core_unix.chmod denied ~perm:0o600;
    List.iter [a; b; bad; denied] ~f:Core_unix.unlink;
    Core_unix.rmdir root) ~f:(fun () ->
    let pending, q = request (press (create ~path:a "abcdef") "ll")
      " ccSwitch interface/implementation<CR>" in
    let jumped = reply pending q (Companions [b]) in
    let pending, q = request (press jumped "lll") " ccSwitch interface/implementation<CR>" in
    let paths = [root; bad; Filename.concat root "missing.mli"]
      @ (if Core_unix.geteuid () = 0 then [] else [denied]) in
    List.iter paths ~f:(fun path ->
      let failed = reply pending q (Companions [path]) in
      assert (Option.equal String.equal (Editor.path (editor failed)) (Some b));
      assert (Editor.cursor (editor failed) = 3);
      let back = press failed "<C-o>" in
      assert (Option.equal String.equal (Editor.path (editor back)) (Some a));
      assert (Editor.cursor (editor back) = 2)))
;;
