open! Core
open Ches_core
open Ches_screen
open Helpers
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller

let id i : Feedback.Identity.t =
  { source = sprintf "checker%d" i; kind = Save; resource = if i = 1 then "b" else "a" }
;;

let report i = Feedback.Report (id i, Warning, sprintf "finding %d" i,
  if i = 0 then None else Some { line = 2; column = 9 })
;;

let create () =
  let t = ui ~path:"a" "first\n\t界🙂x\nthird" in
  List.fold (List.range 0 10) ~init:t ~f:(fun t i ->
    Ui_state.update_feedback t ~width:80 ~height:16 (report i))
;;

let run t keys = Helpers.run ~width:80 ~height:16 t (Helpers.keys keys)
let focused t = Ui_state.problems_focused t ~width:80 ~height:16
let selected t = (Ui_state.problem_navigation t ~width:80 ~height:16).selected
let feedback t = Controller.feedback (Ui_state.controller t)
let editor t = Controller.editor (Ui_state.controller t)
let update t u = Ui_state.update_feedback t ~width:80 ~height:16 u
let is_selected t i = Option.exists (selected t) ~f:(Feedback.Identity.equal (id i))
let notice t text = Option.exists (Ui_state.problem_notice t) ~f:(fun s ->
  String.is_substring s ~substring:text)
;;

let%expect_test "focus, navigation, scrolling and rejection never edit or execute editor commands" =
  let t = create () |> fun t -> run t "iX<Esc> vo" in
  assert (focused t && is_selected t 0);
  assert (Option.is_none (Frame.render t ~width:80 ~height:16).cursor);
  let t = run t "jj<C-d>" in
  assert (is_selected t 4);
  let t = run t "G" in
  assert (is_selected t 9 && (Ui_state.problem_navigation t ~width:80 ~height:16).top = 6);
  let t = run t "ggk<C-u>" in
  assert (is_selected t 0);
  let before = editor t in
  let t = run t "idu w q Q" in
  assert (focused t);
  assert (notice t "Editor command unavailable");
  assert (Text_buffer.equal (Editor.text before) (Editor.text (editor t)));
  assert (Editor.is_dirty (editor t));
  assert (Editor.cursor before = Editor.cursor (editor t));
  let t = run t " vo" in
  assert (not (focused t));
  let t = run t "u" in
  assert (String.equal (Text_buffer.to_string (Editor.text (editor t))) "first\n\t界🙂x\nthird");
  assert (Option.is_some (Frame.render t ~width:80 ~height:16).cursor);
  print_endline "selection scrolls; pane cursor hidden; readonly routing preserves undo";
  [%expect {| selection scrolls; pane cursor hidden; readonly routing preserves undo |}]
;;

let%expect_test "identity reconciliation, next neighbor, filtering and selected acknowledgement" =
  let t = create () |> fun t -> run t " vojjjje" in
  assert (is_selected t 4);
  let t = update t (Report (id 4, Error, "updated", Some { line = 3; column = 2 })) in
  assert (is_selected t 4 && Ui_state.problem_details t);
  let t = update t (Resolve (id 0)) in
  assert (is_selected t 4);
  let t = update t (Resolve (id 4)) in
  assert (is_selected t 5 && not (Ui_state.problem_details t));
  let t = run t "G" |> fun t -> update t (Resolve (id 9)) in
  assert (is_selected t 8);
  let t = run t "gg" in
  assert (is_selected t 1);
  let t = run t " vf" in
  assert (is_selected t 2);
  let t = run t "a" in
  assert (List.length (Feedback.problems (feedback t)) = 7);
  assert (not (List.find_exn (Feedback.problems (feedback t)) ~f:(fun p ->
    Feedback.Identity.equal p.identity (id 2))).attention);
  assert (List.find_exn (Feedback.problems (feedback t)) ~f:(fun p ->
    Feedback.Identity.equal p.identity (id 1))).attention;
  let t = update t (report 2) in
  assert (is_selected t 2);
  assert (List.find_exn (Feedback.problems (feedback t)) ~f:(fun p ->
    Feedback.Identity.equal p.identity (id 2))).attention;
  let t = List.fold (Feedback.problems (feedback t)) ~init:t ~f:(fun t p ->
    update t (Resolve p.identity)) in
  assert (Option.is_none (selected t) && focused t);
  let t = run t "jkGggae<CR>" in
  assert (notice t "No problem selected");
  print_endline "identity stable; removals/filter choose neighbor; acknowledgement does not resolve";
  [%expect {| identity stable; removals/filter choose neighbor; acknowledgement does not resolve |}]
;;

let%expect_test "inspection wraps full text, scrolls, and Escape obeys capture precedence" =
  let t = create () |> fun t -> update t (Report (id 0, Error,
    String.concat (List.init 50 ~f:(fun _ -> "界🙂finding ")), None))
    |> fun t -> run t " voeg" in
  assert (focused t && Ui_state.problem_details t);
  assert (Option.is_some (Ui_state.problem_pending t));
  let t = run t "<Esc>" in
  assert (focused t && Ui_state.problem_details t && Option.is_none (Ui_state.problem_pending t));
  let t = run t "G" in
  assert (Ui_state.problem_detail_top t > 0);
  let t = run t "gg" in
  assert (Ui_state.problem_detail_top t = 0);
  let t = run t "<Esc>" in
  assert (focused t && not (Ui_state.problem_details t));
  let t = run t "<Esc>" in
  assert (not (focused t));
  assert (List.for_all (Feedback.problems (feedback t)) ~f:(fun p -> p.attention));
  let t = run t " vo v<Esc>" in
  assert (focused t && Option.is_none (Ui_state.problem_pending t));
  let t = run t "<Esc>iZ<Esc>" in
  assert (String.is_prefix (Text_buffer.to_string (Editor.text (editor t))) ~prefix:"Zfirst");
  let t = run t " vog<Tab>" in
  assert (not (focused t) && Option.is_none (Ui_state.problem_pending t));
  print_endline "prefix cancelled, details closed, focus returned; no acknowledgement or leaked keys";
  [%expect {| prefix cancelled, details closed, focus returned; no acknowledgement or leaked keys |}]
;;

let%expect_test "safe same-file jumps, display-cell Unicode conversion, and rejected targets" =
  let t = create () |> fun t -> run t "iX<Esc> vo<CR>" in
  assert (focused t && notice t "no document location");
  let t = run t "j<CR>" in
  assert (focused t && notice t "Cross-file jump unavailable");
  let before = editor t in
  let t = run t "j<CR>" in
  let jump_cursor = Editor.cursor (editor t) in
  assert (not (focused t));
  assert (Editor.cursor_line (editor t) = 1);
  assert (Editor.cursor (editor t) = Text_buffer.line_start (Editor.text (editor t)) 1 + 1);
  assert (Editor.is_dirty (editor t) && Text_buffer.equal (Editor.text before) (Editor.text (editor t)));
  assert (List.length (Feedback.problems (feedback t)) = 10);
  List.iter [ 0, 1; 99, 1; 2, 0; 2, 999 ] ~f:(fun (line, column) ->
    let t = update t (Report (id 2, Error, "stale", Some { line; column })) |> fun t -> run t " vo<CR>" in
    assert (focused t && notice t "outside");
    assert (Editor.cursor (editor t) = jump_cursor);
    assert (Editor.is_dirty (editor t)));
  let t = run t "u" in
  assert (String.equal (Text_buffer.to_string (Editor.text (editor t))) "first\n\t界🙂x\nthird");
  let e = editor t in
  List.iter [ 9, 1; 10, 1; 11, 4; 12, 4; 13, 8 ] ~f:(fun (column, byte) ->
    let e = Editor.go_to_display_position e ~line:2 ~column |> Or_error.ok_exn in
    assert (Editor.cursor e = Text_buffer.line_start (Editor.text e) 1 + byte));
  print_endline "Unicode/TAB locations converted; missing, stale and cross-file jumps rejected; undo intact";
  [%expect {| Unicode/TAB locations converted; missing, stale and cross-file jumps rejected; undo intact |}]
;;

let%expect_test "hide, zen, resize and atomic paste restore editor ownership safely" =
  let t = create () |> fun t -> run t " vo v" in
  let t = Helpers.run ~width:15 ~height:4 t [ Ui_state.Input.Resize ] in
  assert (not (focused t) && Option.is_none (Ui_state.problem_pending t));
  let t = Helpers.run ~width:80 ~height:16 t [ Ui_state.Input.Resize ] in
  assert (not (focused t));
  List.iter [ " vb"; " vz" ] ~f:(fun input ->
    let t = run t (" vo" ^ input) in
    assert (not (focused t));
    assert (Option.is_some (Frame.render t ~width:80 ~height:16).cursor));
  let t = run t " vo" in
  let before = Editor.text (editor t) in
  let t = Helpers.run ~width:80 ~height:16 t
    (Ui_state.Input.Paste_start :: Helpers.keys " voij<CR>" ) in
  let t = Helpers.run ~width:15 ~height:4 t [ Resize ] in
  let t = Helpers.run ~width:80 ~height:16 t [ Paste_end ] in
  assert (Text_buffer.equal before (Editor.text (editor t)) && not (focused t));
  let t = run t "i" in
  let t = Helpers.run ~width:80 ~height:16 t (Helpers.paste " vojk") in
  assert (Mode.equal (Editor.mode (editor t)) Insert);
  assert (String.is_prefix (Text_buffer.to_string (Editor.text (editor t))) ~prefix:" vojk");
  print_endline "no stale focus/prefix after resize; pane paste rejected; editor paste stays literal";
  [%expect {| no stale focus/prefix after resize; pane paste rejected; editor paste stays literal |}]
;;

let%expect_test "focused list/details remain bounded in every status position and tiny allocation" =
  List.iter [ ""; " vph"; " vpl"; " vpk"; " vpj" ] ~f:(fun position ->
    let t = create () |> fun t -> run t (position ^ " voG") in
    List.iter [ t; run t "e" ] ~f:(fun t ->
      List.iter (List.range 0 85) ~f:(fun width ->
        List.iter (List.range 0 18) ~f:(fun height ->
          let frame = Frame.render t ~width ~height in
          assert (List.length frame.rows = height);
          List.iter frame.rows ~f:(fun row ->
            assert (Span.total_width row = width);
            List.iter row ~f:(fun span ->
              assert (Cell_map.total_width (Cell_map.glyphs span.Span.text) = span.width)));
          if Ui_state.problems_focused t ~width ~height then assert (Option.is_none frame.cursor)))));
  print_endline "focused rows and details stay within bounds; pane owns no terminal cursor";
  [%expect {| focused rows and details stay within bounds; pane owns no terminal cursor |}]
;;

let%expect_test "Normal pending input has precedence and pane workspace routing honors configuration" =
  let t = create () |> fun t -> run t "3 vo" in
  assert (not (focused t));
  assert (Option.is_none (Ches_input.Keymap.pending (Controller.keymap (Ui_state.controller t))));
  let t = run t "/ vo" in
  assert (not (focused t));
  assert (Option.is_some (Ches_input.Keymap.search_preview (Controller.keymap (Ui_state.controller t))));
  let t = run t "<Esc> vo<Esc>" in
  assert (not (focused t));
  assert (Option.is_none (Ches_input.Keymap.pending (Controller.keymap (Ui_state.controller t))));
  let open Ches_input in
  let bindings = Bindings.create
    [ [Key.char 'o'], Bindings.Target.View Focus_problems
    ; [Key.char ' '; Key.char 'v'; Key.char 'h'], View Toggle_status
    ; [Key.char ' '; Key.char 'x'], Editor (Insert_text "UNSAFE")
    ; [Key.char ' '; Key.char 's'], Scroll Line_down
    ] |> Or_error.ok_exn in
  let controller = Controller.create
    ~keymap_config:{ Keymap.Config.default with normal = bindings } (editor (create ())) in
  let t = Ui_state.create controller |> fun t -> run t "o vh" in
  assert (focused t && (Ui_state.workspace_prefs t).status_visible);
  let before = Editor.text (editor t) in
  let t = run t " x s" in
  assert (notice t "Document scrolling is unavailable");
  assert (Text_buffer.equal before (Editor.text (editor t)));
  let t = run t "<Esc>o" in
  assert (focused t);
  print_endline "Normal prompts/counts retain precedence; configured view bindings work; editor actions blocked";
  [%expect {| Normal prompts/counts retain precedence; configured view bindings work; editor actions blocked |}]
;;

let%expect_test "resize-only focus reconciliation preserves lazy document-scroll restoration" =
  let t = ui (String.concat (List.init 200 ~f:(fun i -> sprintf "line %d\n" i))) in
  let t = Helpers.run ~width:80 ~height:24 t (keys "G999<C-e>kj") in
  let cursor_y t width height = (Option.value_exn (Frame.render t ~width ~height).cursor).y in
  assert (cursor_y t 80 24 = 2);
  let t = Helpers.run ~width:40 ~height:10 t [ Ui_state.Input.Resize ] in
  assert (cursor_y t 40 10 = 7);
  let t = Helpers.run ~width:80 ~height:24 t [ Ui_state.Input.Resize ] in
  assert (cursor_y t 80 24 = 2);
  print_endline "resize does not persist a temporary document scroll fit";
  [%expect {| resize does not persist a temporary document scroll fit |}]
;;
