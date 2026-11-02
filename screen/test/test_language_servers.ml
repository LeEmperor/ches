open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers
module Server = Ches_error.Source_event.Server
module Text_view = Ches_tile.Text_view

let width = 100
let height = 24
let run t keys_ = Helpers.run ~width ~height t (keys keys_)
let source t event = Helpers.run ~width ~height t [ Source event ]
let view t = View_registry.text_view (Ui_state.views t) Language_servers_tile.id |> Option.value_exn
let text t = Text_view.text (view t)
let contains t s = assert (String.is_substring (text t) ~substring:s)
let create ?(source_attached = true) ?path () =
  Ui_state.create ~tiles_visible:false ~source_attached
    (Controller.create (Editor.create ?path ~cell_width:Cell_map.width Text_buffer.empty))
;;
let server source program root resources status : Server.t =
  { source; program; args = [ "--stdio"; "argument with spaces" ]; root; resources; status }
;;
let ocaml = server "ocamllsp#1" "/bin/ocamllsp" "/ocaml project" [ "/ocaml project/a.ml" ] Server.Running
let slang = server "slang-server#2" "slang-server" "/rtl" [ "/rtl/a.sv" ] Server.Starting

let%test_unit "live authoritative inventory: mixed roots, failure, restart, detach, literal output" =
  let t = create ~path:"/ocaml project/a.ml" ()
    |> fun t -> source t (Servers [ ocaml; slang ])
    |> fun t -> run t " li" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Language_servers_tile.id);
  contains t "Current file attached to: \"ocamllsp#1\"";
  contains t "\"slang-server#2\"";
  contains t "Status: Starting";
  contains t "Root: \"/ocaml project\"";
  contains t "\"/bin/ocamllsp\" \"--stdio\" \"argument with spaces\"";
  let t, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function Inspect -> true | _ -> false));
  let t = source t (Started { source = slang.source; root = slang.root }) in
  (* Diagnostic readiness does not invent process inventory readiness. *)
  contains t "Status: Starting";
  let failure = "failed\n\027[31m[markup]" in
  let t = run t "v" |> fun t -> source t (Servers [ ocaml; { slang with status = Unavailable failure } ]) in
  assert (Option.is_none (Text_view.visual (view t)));
  contains t ("Unavailable: " ^ sprintf "%S" failure);
  assert (not (String.contains (text t) '\027'));
  let t = source t (Servers [ { ocaml with status = Stopped "exit 1" }; { slang with status = Running } ]) in
  contains t "Stopped: \"exit 1\"";
  let t = source t (Servers [ { ocaml with status = Starting }; slang ]) in
  assert (not (String.is_substring (text t) ~substring:"exit 1"));
  let t = source t (Servers [ { ocaml with resources = []; status = Running }; slang ]) in
  contains t "Current file: no managed language server attached";
  contains t "Attached documents: 0";
  let t = source t (Servers []) in
  contains t "No managed language servers.";
  assert (not (String.is_substring (text t) ~substring:"Unavailable"))
;;

let%test_unit "global inventory bypasses stale ownership; unrelated stale diagnostics stay dropped" =
  let t = create ~path:"/ocaml project/a.ml" () |> fun t -> run t " li" in
  let wrap event = Ches_error.Source_event.Owned { resource = "/closed.ml"; generation = -1; event } in
  let t = source t (wrap (Servers [ ocaml; slang ])) in
  contains t "ocamllsp#1";
  let before = Controller.feedback (Ui_state.controller t) |> Ches_error.Error.sexp_of_t in
  let t = source t (wrap (Unavailable { source = "unrelated"; root = "/"; reason = "late" })) in
  let after = Controller.feedback (Ui_state.controller t) |> Ches_error.Error.sexp_of_t in
  assert (Sexp.equal before after)
;;

let%test_unit "disabled, synthetic-only empty, unnamed and unsupported file reports" =
  let t = create ~source_attached:false () |> fun t -> run t " li" in
  contains t "Current buffer: no file buffer";
  contains t "No diagnostic source attached";
  contains t "--no-lsp";
  let _, requests = Ui_state.take_source_requests t in
  assert (List.is_empty requests);
  let t = create ~path:"/notes.txt" () |> fun t -> source t (Servers []) |> fun t -> run t " li" in
  contains t "Current file: \"/notes.txt\"";
  contains t "unsupported or not managed";
  contains t "No managed language servers.";
  assert (not (String.is_substring (text t) ~substring:"disabled"))
;;

let%test_unit "normal view keys: copy, reject mutation, escape focus, close and reopen from zen" =
  let t = create ~path:"/ocaml project/a.ml" () |> fun t -> source t (Servers [ ocaml; slang ]) in
  let before = Editor.text (Controller.editor (Ui_state.controller t)) |> Text_buffer.to_string in
  let t = run t " vz li" in
  assert (Ui_state.zen t);
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Language_servers_tile.id);
  let frame = Frame.render t ~width ~height |> Frame.to_string in
  assert (String.is_substring frame ~substring:"Language servers");
  let report = text t in
  let t = run t "ggVGy" in
  assert (Option.is_none (Text_view.visual (view t)));
  let _, clipboard = Controller.take_clipboard (Ui_state.controller t) in
  assert (Option.exists clipboard ~f:(fun copied ->
    String.equal (String.rstrip copied) (String.rstrip report)));
  let t = run t "ixdp" in
  assert (String.equal report (text t));
  assert (String.equal before (Editor.text (Controller.editor (Ui_state.controller t)) |> Text_buffer.to_string));
  let t = run t "<Esc>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Language_servers_tile.id);
  let t = run t " bc" in
  assert (Option.equal View_registry.Placement.equal
    (View_registry.placement (Ui_state.views t) Language_servers_tile.id) (Some Hidden));
  let t = run t " li" in
  assert (String.equal report (text t))
;;

let%test_unit "current file follows the active file, retaining it under the report tab" =
  let dir = scratch_dir "ches-language-servers-" in
  let a = Filename.concat dir "a.ml" and b = Filename.concat dir "b.sv" in
  Out_channel.write_all a ~data:"let x = 1\n";
  Out_channel.write_all b ~data:"module b; endmodule\n";
  Exn.protect ~finally:(fun () -> List.iter [ a; b ] ~f:Core_unix.unlink; Core_unix.rmdir dir)
    ~f:(fun () ->
      let t = create ~path:a () in
      let t = source t (Servers [ { ocaml with resources = [ a ] }; { slang with resources = [ b ] } ]) in
      let t = run t " li" in
      contains t "Current file attached to: \"ocamllsp#1\"";
      let t, _ = Ui_state.open_file t ~width ~height b |> Or_error.ok_exn in
      let t = run t " li" in
      contains t "Current file attached to: \"slang-server#2\"";
      let t = run t " bc bc li" in
      contains t "Current file attached to: \"ocamllsp#1\"";
      let t = source t (Servers [ { ocaml with resources = [ a ] }; { slang with resources = [] } ]) in
      contains t "Attached documents: 0")
;;

let%test_unit "palette lsp search opens the registered tab" =
  let t = create ~path:"/ocaml project/a.ml" () |> fun t -> source t (Servers [ ocaml ]) in
  let t = run t " cclsp<CR>" in
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Language_servers_tile.id)
;;

let%test_unit "palette discovery keywords all find Language servers" =
  List.iter [ "lsp"; "attached"; "clients"; "status"; "server" ] ~f:(fun query ->
    let t = create () |> fun t -> run t (" cc" ^ query) in
    let palette = Ui_state.palette t |> Option.value_exn |> Palette_tile.palette in
    assert (List.exists (Ches_palette.Palette.results palette) ~f:(fun result ->
      String.equal (Ches_palette.Catalog.Entry.title result.item) "Language servers")))
;;

let%test_unit "bare mode opens the report as a major tab" =
  let t = create () |> fun t -> run t " vB li" in
  assert (not (Ui_state.bare t));
  assert (Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Language_servers_tile.id)
;;
