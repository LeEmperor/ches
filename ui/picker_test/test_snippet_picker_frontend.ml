open! Core
open! Async
open Bonsai_test
open Bonsai_term
module Expect_test_config = Async.Expect_test_config

let%expect_test "palette discovers and inserts configured snippets without LSP or automatic completion" =
  let settings =
    { Ches_config_runtime.Settings.default with
      completion_enabled = false
    ; snippets =
        [ Ches_completion.User_snippets.Add
            { id = "frontend.discovery"
            ; prefix = "not_the_preceding_text"
            ; scopes = []
            ; description = Some "unique frontend discovery"
            ; body = "PICKED ${1:first} = $1; $0"
            }
        ]
    } in
  let snippets = Ches_ui.Snippet_host.For_testing.create ~load:(fun () ->
    return (Ok Ches_completion.User_snippets.builtins)) in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create
    ~cell_width:Ches_screen.Cell_map.width Ches_core.Text_buffer.empty) in
  let handle = Bonsai_term_test.create_handle
    ~initial_dimensions:{ width = 160; height = 30 }
    (Ches_ui.Editor_view.app ~snippets ~startup_configuration:(Ok settings)
      ~configuration_path:(Error "No configuration file in snippet fixture")
      ~bare:true controller ~exit:(fun () -> Effect.Ignore)) in
  let key key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
  let type_text text = String.iter text ~f:(fun c -> key (ASCII c)) in
  let view () =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let open_picker () =
    type_text " ccInsert snippet"; key Enter;
    type_text "unique frontend discovery" in
  type_text "iKEPT "; key Escape;
  open_picker ();
  assert (String.is_substring (view ()) ~substring:"unique frontend discovery");
  key Escape;
  let cancelled = view () in
  assert (String.is_substring cancelled ~substring:"KEPT");
  assert (not (String.is_substring cancelled ~substring:"PICKED"));
  open_picker (); key Enter;
  assert (String.is_substring (view ()) ~substring:"KEPTPICKED first = first;");
  type_text "changed";
  assert (String.is_substring (view ()) ~substring:"KEPTPICKED changed = changed;");
  key Tab; key Escape;
  Ches_ui.Snippet_host.stop snippets;
  Ches_app.Controller.close controller;
  ignore ([%expect.output] : string);
  print_endline "description search, cancel, prefix-independent insertion and mirrored fields work without LSP/completion";
  [%expect {| description search, cancel, prefix-independent insertion and mirrored fields work without LSP/completion |}];
  return ()
;;
