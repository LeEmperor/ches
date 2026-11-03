open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers
module M = Ches_completion.Model
module Request = Ches_error.Source_request

let press t s = run t (keys s)
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let revision t = Editor.revision (editor t)

let query ?(initial = "\ntrailing") () =
  let buffer = Text_buffer.of_string initial |> Result.ok |> Option.value_exn in
  let t = Ui_state.create ~tiles_visible:false ~source_attached:true
    (Controller.create (Editor.create ~path:"/completion-resolve-review.ml" ~cell_width:Cell_map.width buffer)) in
  let t = press t "ial" in
  let t, requests = Ui_state.take_source_requests t in
  t, List.find_map_exn requests ~f:(function Request.Complete req -> Some req | _ -> None)
;;

let candidate ?(additional = []) (req : M.Request.t) id : M.Candidate.t =
  { id; source = Lsp "test"; label = id; detail = None; filter_text = "alpha"; sort_text = id
  ; primary = { start = req.fallback_start; stop = req.fallback_stop; text = "alpha" }
  ; additional; cursor = 5; snippet = None }
;;

let reply t (req : M.Request.t) candidates =
  run t [ Source (Completion { token = req.token; source = "test"; candidates; incomplete = false }) ]
;;

let info ?revision ?additional ?(resolvable = true) candidate_id : Ches_error.Completion_info.t =
  { candidate_id; kind = Some 3; documentation = Some "docs"; detail = None
  ; resolvable; additional; revision }
;;

let metadata t (req : M.Request.t) items =
  run t [ Source (Completion_metadata { token = req.token; source = "test"; items }) ]
;;

let resolve_requests t =
  let t, requests = Ui_state.take_source_requests t in
  t, List.filter_map requests ~f:(function Request.Resolve_completion req ->
    Some (req.candidate_id, req.revision) | _ -> None)
;;

let extras text = [ { Text_edit.start = 3; stop = 3; text } ]

let selected () =
  let t, req = query () in
  let t = reply t req [candidate req "alpha"] in
  let t = metadata t req [info "alpha"] in
  let t, requests = resolve_requests t in
  assert ([%equal: (string * int) list] requests ["alpha", revision t]);
  t, req
;;

let%expect_test "resolve before first Tab must never finalize a primary that was not installed" =
  List.iter ["x", "alx\ntrailing"; "<Esc>", "al\ntrailing"] ~f:(fun (key, expected) ->
    let t, req = selected () in
    let t = metadata t req [info ~revision:(revision t) ~additional:(extras "import\n") "alpha"] in
    let t = press t key in
    assert (String.equal (text t) expected));
  [%expect {| |}]
;;

let%expect_test "resolve accepted before Tab remains valid through primary installation and acceptance" =
  let t, req = selected () in
  let t = metadata t req [info ~revision:(revision t) ~additional:(extras "import\n") "alpha"] in
  let t = press t "<Tab>" in
  assert (String.equal (text t) "alpha\ntrailing");
  let t, requests = resolve_requests t in
  assert (List.is_empty requests);
  let t = press t "<CR>" in
  assert (String.equal (text t) "alpha\nimport\ntrailing");
  assert (not (Ui_state.toggle_key_pending t));
  [%expect {| |}]
;;

let%expect_test "resolved additional edits replace known extras, including clearing them with an empty list" =
  List.iter [[], "alpha\ntrailing"; extras "new\n", "alpha\nnew\ntrailing"]
    ~f:(fun (additional, expected) ->
      let t, req = query () in
      let t = reply t req [candidate req ~additional:(extras "old\n") "alpha"] in
      let t = metadata t req [info "alpha"] in
      let t, _ = resolve_requests t in
      let t = metadata t req [info ~revision:(revision t) ~additional "alpha"] in
      let t = press t "<Tab><CR>" in
      assert (String.equal (text t) expected));
  [%expect {| |}]
;;

let accepted () =
  let t, req = selected () in
  let t = press t "<CR>" in
  let t, requests = resolve_requests t in
  assert ([%equal: (string * int) list] requests ["alpha", revision t]);
  assert (String.equal (text t) "alpha\ntrailing");
  assert (Ui_state.toggle_key_pending t);
  t, req, revision t
;;

let%expect_test "deferred acceptance expires without typing and cancels its source token" =
  let t, req, at = accepted () in
  let t = run t [Toggle_tick (Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_int_sec 2))] in
  assert (not (Ui_state.toggle_key_pending t));
  let t, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function Request.Cancel_completion token ->
    M.Token.equal token req.token | _ -> false));
  let t = metadata t req [info ~revision:at ~additional:(extras "too late\n") "alpha"] in
  assert (String.equal (text t) "alpha\ntrailing");
  [%expect {| |}]
;;

let%expect_test "paste and edits cancel deferred acceptance before a late response can mutate the buffer" =
  List.iter [keys "!"; paste "pasted"] ~f:(fun inputs ->
    let t, req, at = accepted () in
    let t = run t inputs in
    let expected = text t in
    assert (not (Ui_state.toggle_key_pending t));
    let t = metadata t req [info ~revision:at ~additional:(extras "late\n") "alpha"] in
    assert (String.equal (text t) expected));
  [%expect {| |}]
;;

let%expect_test "a key held by toggle recognition invalidates deferred acceptance before it changes text" =
  let t, req, at = accepted () in
  let t = press t " " in
  assert (String.equal (text t) "alpha\ntrailing" && revision t = at);
  let t = metadata t req [info ~revision:at ~additional:(extras "late\n") "alpha"] in
  assert (String.equal (text t) "alpha\ntrailing");
  let _, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function Request.Cancel_completion token ->
    M.Token.equal token req.token | _ -> false));
  [%expect {| |}]
;;

let%expect_test "same-primary selection changes allow resolving an item whose earlier response was dropped" =
  let t, req = query () in
  (* Extras distinguish otherwise-equivalent candidates; cycling their identical
     primaries does not increment the editor revision. *)
  let t = reply t req [candidate req "alpha"; candidate req ~additional:(extras "known\n") "beta"] in
  let t = metadata t req [info "alpha"; info ~resolvable:false "beta"] in
  let t, _ = resolve_requests t in
  let t = press t "<Tab>" in
  let t, _ = resolve_requests t in
  let at = revision t in
  let t = press t "<Tab>" in
  assert (revision t = at);
  let t = metadata t req [info ~revision:at ~additional:(extras "dropped\n") "alpha"] in
  let t = press t "<Tab>" in
  assert (revision t = at);
  let t, requests = resolve_requests t in
  assert ([%equal: (string * int) list] requests ["alpha", at]);
  let t = metadata t req [info ~revision:at ~additional:(extras "fresh\n") "alpha"] in
  let t = press t "<CR>" in
  assert (String.equal (text t) "alpha\nfresh\ntrailing");
  [%expect {| |}]
;;
