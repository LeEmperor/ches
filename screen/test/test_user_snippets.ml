open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers

module U = Ches_completion.User_snippets
module M = Ches_completion.Model

let press t s = run t (keys s)
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let candidates = Ui_state.completion_candidates
let snippets t = List.filter (candidates t) ~f:(fun c ->
  M.Candidate.equal_source c.source Snippet)
let active t = not (List.is_empty (Ui_state.snippet_ranges t))

let catalog = lazy (U.parse {|{"version":1,"snippets":[
  {"id":"test.aff","prefix":"aff","body":["assign ${1:signal} = $1;","    ${2:value}","$0"]},
  {"id":"test.long","prefix":"affinity","body":"longer $0"},
  {"id":"test.sv","prefix":"scope_sv","scope":[".sv"],"body":"sv $0"},
  {"id":"test.ml","prefix":"scope_ml","scope":["ocaml"],"body":"ml $0"}
]}|} |> Or_error.ok_exn)

let loaded ?path initial =
  Ui_state.receive_snippets (ui ?path initial) ~generation:1 (Ok (Lazy.force catalog))
;;

module Settings = Ches_config_runtime.Settings

let declaration ?(id = "test.aff") ?(prefix = "aff") body =
  U.Add { id; prefix; scopes = []; collection = None; description = None; body }
;;

let configure t snippets =
  Ui_state.apply_configuration t { Settings.default with snippets }
  |> Result.ok_or_failwith
;;

let configuration_reply t generation settings =
  let t = press t " ccconfiguration.reload<CR>" in
  Ui_state.receive_configuration t ~generation settings
;;

let expansion t = text (press t "iaff<CR>")

let%test_unit "late legacy loads and legacy reloads always reapply current configuration operations" =
  let t = configure (ui "") [declaration "configured $0"; U.Disable "test.long"] in
  assert (String.equal (expansion t) "configured ");
  let t = Ui_state.receive_snippets t ~generation:1 (Ok (Lazy.force catalog)) in
  assert (String.equal (expansion t) "configured ");
  assert (List.length (snippets (press t "iaff")) = 1);
  let t = press t " ccsnippets.reload<CR>" in
  let replacement = U.parse {|{"version":1,"snippets":[
    {"id":"test.aff","prefix":"aff","body":"new base $0"},
    {"id":"test.long","prefix":"affinity","body":"new longer $0"}
  ]}|} |> Or_error.ok_exn in
  let t = Ui_state.receive_snippets t ~generation:2 (Ok replacement) in
  assert (String.equal (expansion t) "configured ");
  let t = configuration_reply t 1 (Ok Settings.default) in
  assert (String.equal (expansion t) "new base ");
  assert (List.length (snippets (press t "iaff")) = 2)
;;

let%test_unit "configuration changes, disables, removals and invalid whole snapshots preserve layering" =
  let t = configure (loaded "") [declaration "first $0"] in
  let t = configuration_reply t 1
      (Ok { Settings.default with snippets = [declaration "second $0"] }) in
  assert (String.equal (expansion t) "second ");
  List.iter [Error "compile failed";
    Ok { Settings.completion_enabled = false;
      signature_help_enabled = false;
      completion_ghost_preview = true; completion_min_prefix_chars = 3;
      completion_prefer_local_snippets = false; line_numbers = true;
      theme = Ches_theme.Theme.id (List.last_exn Ches_theme.Theme.all); completion_colors = [];
      snippets = [declaration "would replace $0"; declaration ~id:"bad.entry" "${UNKNOWN}"] };
    Ok { Settings.default with theme = "missing"; snippets = [] }]
    ~f:(fun result ->
      let pending = press t " ccconfiguration.reload<CR>iaff" in
      let before = candidates pending in
       let failed = Ui_state.receive_configuration pending ~generation:2 result in
       assert (Ui_state.completion_enabled failed);
       assert (Bool.equal (Ui_state.completion_ghost_enabled pending)
         (Ui_state.completion_ghost_enabled failed));
       assert (Ches_theme.Theme.equal (Ui_state.theme pending) (Ui_state.theme failed));
       assert (Geometry.Prefs.equal (Ui_state.prefs pending) (Ui_state.prefs failed));
       assert (Presentation.Bare_prefs.equal (Ui_state.bare_prefs pending) (Ui_state.bare_prefs failed));
       assert (List.equal M.Candidate.equal before (candidates failed));
      assert (String.equal (text failed) "aff");
      assert (String.equal (expansion (press failed "<Esc>dd")) "second "));
  let t = configuration_reply t 2
      (Ok { Settings.default with snippets = [U.Disable "test.aff"; U.Disable "test.long"] }) in
  assert (List.is_empty (snippets (press t "iaff")));
  let t = configuration_reply t 3 (Ok Settings.default) in
  assert (String.equal (expansion t) "assign signal = signal;\n    value\n")
;;

let%test_unit "removed or disabled config before pending JSON uses the latest operations" =
  List.iter [[]; [U.Disable "test.aff"; U.Disable "test.long"]] ~f:(fun snippets_ops ->
    let t = configure (ui "") [declaration "old override $0"] in
    let t = configuration_reply t 1 (Ok { Settings.default with snippets = snippets_ops }) in
    let t = Ui_state.receive_snippets t ~generation:1 (Ok (Lazy.force catalog)) in
    if List.is_empty snippets_ops then
      assert (String.equal (expansion t) "assign signal = signal;\n    value\n")
    else assert (List.is_empty (snippets (press t "iaff"))))
;;

let%test_unit "catalog replacement retains installed snippet ranges and mirrors" =
  let t = press (loaded "") "iaff<CR>bus" in
  assert (active t);
  let ranges = Ui_state.snippet_ranges t in
  let t = configure t [U.Disable "test.aff"] in
  assert (Poly.equal ranges (Ui_state.snippet_ranges t));
  let t = press t "<Tab>42<Tab>" in
  assert (String.equal (text t) "assign bus = bus;\n    42\n");
  let t = configure (ui "") [declaration "assign ${1:signal} = $1;\n    ${2:value}\n$0"]
    |> fun t -> press t "iaff<CR>bus" in
  let ranges = Ui_state.snippet_ranges t in
  let t = Ui_state.receive_snippets t ~generation:1 (Ok U.builtins) in
  assert (Poly.equal ranges (Ui_state.snippet_ranges t));
  let t = press t "<Tab>42<Tab>" in
  assert (String.equal (text t) "assign bus = bus;\n    42\n");
  assert (not (active t))
;;

let%expect_test "startup uses builtins, loads once, and snippets are independent of LSP and automatic preference" =
  let t = ui ~path:"module.sv" "" in
  let t, generations = Ui_state.take_snippet_reload_requests t in
  assert ([%equal: int list] generations [1]);
  let _, again = Ui_state.take_snippet_reload_requests t in
  assert (List.is_empty again);
  let t = press t "iaff" in
  assert (List.exists (snippets t) ~f:(fun c -> String.equal c.label "aff"));
  let t = press (loaded "") "iaff" in
  assert (List.exists (snippets t) ~f:(fun c -> String.equal c.label "aff"));
  let _, requests = Ui_state.take_source_requests t in
  assert (List.is_empty requests);
  let t = press (loaded "") " cccompletion.toggle<CR>iaff" in
  assert (not (Ui_state.completion_enabled t) && List.is_empty (candidates t));
  let t = press t "<C-n>" in
  assert (List.exists (snippets t) ~f:(fun c -> String.equal c.label "aff"));
  let t = press t "<CR>bus<Tab>42<Tab>" in
  assert (String.equal (text t) "assign bus = bus;\n    42\n");
  assert (not (active t));
  [%expect {| |}]
;;

let%expect_test "scope matching includes global snippets and only the current file scope" =
  List.iter ["f.txt", []; "f.sv", ["scope_sv"]; "f.ml", ["scope_ml"]]
    ~f:(fun (path, expected) ->
      let t = press (loaded ~path "") "iscope" in
      assert ([%equal: string list] (List.map (snippets t) ~f:(fun c -> c.label)) expected);
      let t = press (loaded ~path "") "iaff" in
      assert (List.exists (snippets t) ~f:(fun c -> String.equal c.label "aff")));
  [%expect {| |}]
;;

let%expect_test "middle-line template replaces only prefix, indents fields, mirrors, and leaves suffix intact" =
  let t = press (loaded "  TAIL") "lli aff" in
  (* The space before aff belongs to the surrounding line, not the replacement. *)
  let t = press t "<Tab>" in
  assert (String.equal (text t) "   assign signal = signal;\n       value\n   TAIL");
  assert (not (active t));
  let t = press t "<CR>bus" in
  assert (active t && String.equal (text t) "   assign bus = bus;\n       value\n   TAIL");
  let t = press t "<Tab>42<Tab>" in
  assert (not (active t) && Editor.cursor (editor t) = String.length "   assign bus = bus;\n       42\n   ");
  assert (String.equal (text (press t "<Esc>u")) "  TAIL");
  [%expect {| |}]
;;

let%expect_test "snippet tags follow aligned labels and coexist with buffer and server duplicates" =
  let t = Ui_state.create ~tiles_visible:false ~source_attached:true
      (Controller.create (Editor.create ~path:"f.txt" ~cell_width:Cell_map.width
        (Text_buffer.of_string "\naffinity"
         |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith))) in
  let t = Ui_state.receive_snippets t ~generation:1 (Ok (Lazy.force catalog)) in
  let t = press t "iaff" in
  let t, requests = Ui_state.take_source_requests t in
  let req = List.find_map_exn requests ~f:(function
    | Ches_error.Source_request.Complete r -> Some r | _ -> None) in
  let c : M.Candidate.t =
    { id = "plain"; source = Lsp "test"; label = "aff"; detail = None
    ; filter_text = "aff"; sort_text = "aff"
    ; primary = { start = req.fallback_start; stop = req.cursor; text = "aff" }
    ; additional = []; cursor = 3; snippet = None } in
  let t = run t [Source (Completion { token = req.token; source = "test";
      candidates = [c]; incomplete = false })] in
  assert (List.exists (candidates t) ~f:(fun c -> M.Candidate.equal_source c.source Buffer));
  assert (List.exists (candidates t) ~f:(fun c -> M.Candidate.equal_source c.source (Lsp "test")));
  assert (List.length (snippets t) = 2);
  let rendered = Frame.to_string (Frame.render t ~width:80 ~height:12) in
  assert (String.is_substring rendered ~substring:"aff       [snippet]");
  assert (String.is_substring rendered ~substring:"affinity  [snippet]");
  assert (String.is_substring rendered ~substring:"affinity  [buffer]");
  let _, requests = Ui_state.take_source_requests t in
  assert (not (List.exists requests ~f:(function
    | Ches_error.Source_request.Resolve_completion _ -> true | _ -> false)));
  let rec choose t remaining =
    assert (remaining > 0);
    match Ui_state.completion_selected t with
    | Some c when M.Candidate.equal_source c.source Snippet && String.equal c.label "aff" -> t
    | _ -> choose (press t "<Tab>") (remaining - 1) in
  let t = press (choose t 10) "<CR>bus" in
  assert (active t && String.is_prefix (text t) ~prefix:"assign bus = bus;");
  [%expect {| |}]
;;

let%expect_test "reload generation rejects stale successes/errors and source replies, preserves last good on failure" =
  let t = loaded "" in
  let t = press t " ccsnippets.reload<CR> ccsnippets.reload<CR>" in
  let t, generations = Ui_state.take_snippet_reload_requests t in
  assert ([%equal: int list] generations [1; 2; 3]);
  let t = Ui_state.receive_snippets t ~generation:3 (Error "invalid entry test.bad") in
  assert (String.is_substring (Option.value_exn (Ui_state.message t)).text ~substring:"invalid entry test.bad");
  let t = Ui_state.receive_snippets t ~generation:2 (Ok U.builtins) in
  let t = Ui_state.receive_snippets t ~generation:1 (Error "stale failure") in
  assert (not (String.is_substring (Option.value_exn (Ui_state.message t)).text ~substring:"stale failure"));
  assert (not (List.is_empty (snippets (press t "iaff")))) ;
  let t = press t " ccsnippets.reload<CR>" in
  let t = Ui_state.receive_snippets t ~generation:4 (Ok U.builtins) in
  assert (String.equal (Option.value_exn (Ui_state.message t)).text "Snippets reloaded");
  assert (List.is_empty (snippets (press t "iaff")));
  let t = Test_completion.attached "" in
  let t, req = Test_completion.request (press t "ial") in
  (* A load arriving with an open source menu invalidates its token. *)
  let t = Ui_state.receive_snippets t ~generation:1 (Ok (Lazy.force catalog)) in
  let t = Test_completion.reply t req [Test_completion.candidate req "alpha"] in
  assert (List.is_empty (candidates t));
  let _, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function
    | Ches_error.Source_request.Cancel_completion token -> M.Token.equal token req.token
    | _ -> false));
  [%expect {| |}]
;;

let%expect_test "malformed JSON and duplicate disables retain the entire last-good catalog" =
  List.iter [ "{broken";
    {|{"version":1,"snippets":[{"id":"test.aff","disabled":true},{"id":"test.aff","disabled":true}]}|};
    {|{"version":1,"snippets":[{"id":"test.aff","disabled":true},{"id":"bad","prefix":"b","body":"${UNKNOWN}"}]}|} ]
    ~f:(fun input ->
      let t = press (loaded "") " ccsnippets.reload<CR>" in
      let result = U.parse input |> Result.map_error ~f:Error.to_string_hum in
      assert (Result.is_error result);
      let t = Ui_state.receive_snippets t ~generation:2 result in
      assert (String.is_substring (Option.value_exn (Ui_state.message t)).text
        ~substring:"Could not reload snippets:");
      let t = press t "iaff<CR>bus<Tab>42<Tab>" in
      assert (String.equal (text t) "assign bus = bus;\n    42\n"));
  [%expect {| |}]
;;
