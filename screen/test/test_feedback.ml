open! Core
open Ches_core
open Ches_screen
open Helpers
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller

let state t = Controller.feedback (Ui_state.controller t)
let problem_count t = List.length (Feedback.problems (state t))
let attention t = List.count (Feedback.problems (state t)) ~f:(fun p -> p.attention)

let has_message t text =
  Option.exists (Ui_state.message t) ~f:(fun m ->
    String.is_substring m.text ~substring:text)
;;

let%expect_test "identity, recovery, renewed attention, and cycling retained details" =
  let save : Feedback.Identity.t = { source = "file"; kind = Save; resource = "a" } in
  let reload = { save with kind = Reload } in
  let other = { save with resource = "b" } in
  let f =
    Feedback.empty
    |> fun f ->
    Feedback.apply f (Failed (save, Error, "save a"))
    |> fun f ->
    Feedback.apply f (Failed (reload, Error, "reload a"))
    |> fun f ->
    Feedback.apply f (Failed (other, Error, "save b"))
    |> fun f ->
    Feedback.apply
      f
      (Notify { source = "workspace"; scope = None; severity = Info; text = "layout" })
    |> fun f ->
    Feedback.apply f Command_completed |> fun f -> Feedback.apply f Acknowledge
  in
  assert (List.length (Feedback.problems f) = 3);
  assert (not (List.hd_exn (Feedback.problems f)).attention);
  let f = Feedback.apply f Inspect_next in
  assert (String.equal (Option.value_exn (Feedback.notification f)).text "save a");
  let f = Feedback.apply f Inspect_next |> fun f -> Feedback.apply f Acknowledge in
  assert (not (List.nth_exn (Feedback.problems f) 1).attention);
  let f = Feedback.apply f (Failed (save, Error, "save a again")) in
  assert (List.length (Feedback.problems f) = 3);
  assert (List.hd_exn (Feedback.problems f)).attention;
  let f = Feedback.apply f (Resolve { save with resource = "unrelated" }) in
  assert (List.length (Feedback.problems f) = 3);
  let f = Feedback.apply f (Resolve save) in
  assert (List.length (Feedback.problems f) = 2);
  let f =
    List.fold
      [ Feedback.Inspect_next; Inspect_next; Inspect_next ]
      ~init:f
      ~f:(fun f update ->
        let f = Feedback.apply f update in
        print_endline (Option.value_exn (Feedback.notification f)).text;
        f)
  in
  assert (List.length (Feedback.problems f) = 2);
  [%expect {|
    reload a
    save b
    reload a
    |}]
;;

let%expect_test "real save/reload failures survive input and layouts until matching \
                 recovery"
  =
  let dir = Core_unix.mkdtemp "/tmp/ches-feedback" in
  Exn.protect
    ~finally:(fun () ->
      ignore (Core_unix.system ("rm -rf " ^ Filename.quote dir) : _ Result.t))
    ~f:(fun () ->
      let path = dir ^/ "file" in
      let t = ui ~path "hello" |> fun t -> run t (keys "iX<Esc>") in
      Core_unix.mkdir path;
      let t = run t (keys " w") in
      assert (problem_count t = 1 && attention t = 1);
      assert (has_message t "Failed to write");
      let t = run t (keys "l vt vph vpk vp+ vz vz vN3^") in
      assert (problem_count t = 1 && attention t = 1);
      assert (has_message t "Failed to write");
      List.iter
        [ 160, 12; 23, 4; 1, 1; 0, 0 ]
        ~f:(fun (width, height) ->
          let frame = Frame.render t ~width ~height in
          assert (List.length frame.rows = height);
          List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
      let t = run t (keys "<Esc>") in
      assert (attention t = 0 && problem_count t = 1);
      assert (Editor.is_dirty (Controller.editor (Ui_state.controller t)));
      assert (has_message t "1 problem");
      let t = run t (keys " ve") in
      assert (has_message t "Failed to write" && attention t = 0);
      let t = run t (keys " w:e!<CR>") in
      assert (attention t = 2 && problem_count t = 2);
      Core_unix.rmdir path;
      let t = run t (keys " w") in
      assert (problem_count t = 1);
      assert (has_message t "Failed to reload");
      let t = run t (keys ":e!<CR>") in
      assert (problem_count t = 0 && attention t = 0);
      assert (not (Editor.is_dirty (Controller.editor (Ui_state.controller t))));
      print_endline
        "save and reload recover independently; acknowledgement preserves dirty state");
  [%expect
    {| save and reload recover independently; acknowledgement preserves dirty state |}]
;;

let%expect_test "Escape precedence, selected acknowledgement, and transient command \
                 lifetime"
  =
  let controller =
    Controller.create (Editor.create ~cell_width:Cell_map.width Text_buffer.empty)
  in
  let save : Feedback.Identity.t = { source = "file"; kind = Save; resource = "a" } in
  let reload = { save with kind = Reload } in
  let controller = Controller.update_feedback controller (Failed (save, Error, "save")) in
  let controller =
    Controller.update_feedback controller (Failed (reload, Error, "reload"))
  in
  let t = Ui_state.create controller in
  let t = run t (keys "i<Esc>v<Esc>3<Esc>d<Esc>/<Esc>:<Esc> ") in
  assert (attention t = 2);
  let t = run t (keys "<Esc>") in
  assert (attention t = 2);
  let t = run t (keys " ve ve<Esc>") in
  assert (attention t = 1);
  assert (List.hd_exn (Feedback.problems (state t))).attention;
  assert (not (List.nth_exn (Feedback.problems (state t)) 1).attention);
  let t = run t (keys "<Esc>") in
  assert (attention t = 0 && problem_count t = 2);
  let t = run (ui "hello") (keys "iX<Esc> q") in
  assert (has_message t "Unsaved changes");
  let t = run t (keys "Zg<Esc>") in
  assert (has_message t "Unsaved changes");
  let t = run t [ Ui_state.Input.Animation_tick Time_ns.epoch ] in
  assert (has_message t "Unsaved changes");
  let t = run t (keys "l") in
  assert (Option.is_none (Ui_state.message t));
  let t = run t (keys "3^") in
  assert (has_message t "does not take a count");
  let t = run t (keys " vt") in
  assert (has_message t "Status");
  let t = run t (keys "l") in
  assert (Option.is_none (Ui_state.message t));
  print_endline
    "Escape cancels first; details acknowledge the selected identity; commands clear \
     transient feedback";
  [%expect
    {| Escape cancels first; details acknowledge the selected identity; commands clear transient feedback |}]
;;

let%expect_test "idle Escape acknowledges attention and clears search highlighting \
                 together"
  =
  let t = run (ui "hello hello") (keys "/hello<CR>") in
  let controller = Ui_state.controller t in
  assert (Option.is_some (Editor.search_state (Controller.editor controller)));
  let controller =
    Controller.update_feedback
      controller
      (Failed ({ source = "file"; kind = Save; resource = "f.txt" }, Error, "save failed"))
  in
  let t = run (Ui_state.create controller) (keys "<Esc>") in
  assert (attention t = 0 && problem_count t = 1);
  assert (Option.is_none (Editor.search_state (Controller.editor (Ui_state.controller t))));
  print_endline "acknowledged; search highlights cleared; problem retained";
  [%expect {| acknowledged; search highlights cleared; problem retained |}]
;;
