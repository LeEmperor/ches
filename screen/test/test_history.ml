open! Core
open Ches_core
open Ches_screen
module Feedback = Ches_error.Error
module History = Feedback.History
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id

let note ?(history = true) ?(severity = Feedback.Severity.Info) text : Feedback.update =
  Notify { source = "editor"; scope = Some "a"; severity; text; history }
;;

let save : Feedback.Identity.t = { source = "file"; kind = Save; resource = "a" }
let entries f = History.entries (Feedback.history f)
let print_history f = List.iter (entries f) ~f:(fun e -> print_endline (History_tile.description e))

let%expect_test "history is bounded, chronological, and merges consecutive repeats" =
  let f =
    List.fold
      [ note "one"; note "one"; note "two"; note "one"; note ~history:false "layout" ]
      ~init:Feedback.empty
      ~f:Feedback.apply
  in
  print_history f;
  (* Not kept in history, but still the transient notification. *)
  print_endline (Option.value_exn (Feedback.notification f)).text;
  [%expect
    {|
    #1 ×2 info [editor] a: one
    #2 info [editor] a: two
    #3 info [editor] a: one
    layout
    |}];
  let f =
    List.fold (List.range 0 250) ~init:Feedback.empty ~f:(fun f i ->
      Feedback.apply f (note (sprintf "n%d" i)))
  in
  let seqs f = List.map (entries f) ~f:(fun (e : History.Entry.t) -> e.seq) in
  print_s
    [%message
      ""
        ~length:(List.length (entries f) : int)
        ~first:(List.hd (seqs f) : int option)
        ~last:(List.last (seqs f) : int option)
        ~dropped:(History.dropped (Feedback.history f) : int)];
  [%expect {| ((length 200) (first (51)) (last (250)) (dropped 50)) |}];
  (* Clearing empties it; sequence numbers are never reused. *)
  let f = Feedback.apply f Clear_history in
  let f = Feedback.apply f (note "after") in
  print_history f;
  print_s [%sexp (History.dropped (Feedback.history f) : int)];
  [%expect {|
    #251 info [editor] a: after
    0
    |}]
;;

let%expect_test "problem lifecycle is recorded, independent of active problems" =
  let apply f updates = List.fold updates ~init:f ~f:Feedback.apply in
  let f =
    apply
      Feedback.empty
      [ Failed (save, Error, "Failed to write a")
      ; Failed (save, Error, "Failed to write a")
      ; note "typed"
      ; Failed (save, Error, "Failed to write a")
      ]
  in
  let before = entries f in
  (* Acknowledgement, inspection, and command completion are not events. *)
  let f =
    apply f [ Acknowledge; Inspect_next; Acknowledge_identity save; Command_completed ]
  in
  assert ([%equal: History.Entry.t list] before (entries f));
  print_history f;
  [%expect
    {|
    #1 ×2 error problem [file save] a: Failed to write a
    #2 info [editor] a: typed
    #3 error problem again [file save] a: Failed to write a
    |}];
  (* Clearing history leaves the problem, and its acknowledgement, alone. *)
  let problems = Feedback.problems f in
  let f = Feedback.apply f Clear_history in
  assert ([%equal: Feedback.Problem.t list] problems (Feedback.problems f));
  assert (List.is_empty (entries f));
  (* Resolving records the resolution and keeps the earlier occurrence; a resolve of
     an inactive identity (an ordinary successful save) records nothing. *)
  let f =
    apply
      f
      [ Failed (save, Error, "Failed to write a: denied")
      ; Resolve save
      ; Resolve save
      ; Resolve { save with kind = Reload }
      ]
  in
  print_history f;
  print_s [%sexp (List.length (Feedback.problems f) : int)];
  [%expect
    {|
    #4 error problem again [file save] a: Failed to write a: denied
    #5 resolved [file save] a (was: Failed to write a: denied)
    0
    |}]
;;

let%expect_test "real failures, recovery, and UI chatter through the application" =
  let dir = Core_unix.mkdtemp "/tmp/ches-history" in
  Exn.protect
    ~finally:(fun () ->
      ignore (Core_unix.system ("rm -rf " ^ Filename.quote dir) : _ Result.t))
    ~f:(fun () ->
      let path = dir ^/ "file" in
      let history t = Feedback.history (Controller.feedback (Ui_state.controller t)) in
      let show t =
        List.iter (History.entries (history t)) ~f:(fun e ->
          print_endline
            (String.substr_replace_all (History_tile.description e) ~pattern:dir ~with_:"$DIR"))
      in
      let t = Helpers.ui ~path "hello" |> fun t -> Helpers.run t (Helpers.keys "iX<Esc>") in
      Core_unix.mkdir path;
      let t = Helpers.run t (Helpers.keys " w w") in
      (* Layout commands, focus, acknowledgement, renders, resizes, and animation ticks
         never add entries. *)
      let before = History.entries (history t) in
      let t =
        Helpers.run t (Helpers.keys " vc vc vt vz vz vb vo<Esc><Esc>")
        |> fun t ->
        Helpers.run t [ Resize; Animation_tick Time_ns.epoch; Animation_tick Time_ns.epoch ]
      in
      List.iter [ 80, 24; 20, 6; 0, 0 ] ~f:(fun (width, height) ->
        ignore (Frame.render t ~width ~height : Frame.t));
      assert ([%equal: History.Entry.t list] before (History.entries (history t)));
      Core_unix.rmdir path;
      let t = Helpers.run t (Helpers.keys " w") in
      show t;
      print_s [%sexp (List.length (Feedback.problems (Controller.feedback (Ui_state.controller t))) : int)]);
  [%expect
    {|
    #1 ×2 error problem [file save] $DIR/file: Failed to write $DIR/file: Is a directory
    #2 resolved [file save] $DIR/file (was: Failed to write $DIR/file: Is a directory)
    #3 info [editor] $DIR/file: Wrote $DIR/file (6 bytes)
    0
    |}]
;;

(* The tile: problems and history coexist on the shared host, shell, and text view. *)

let width = 100
let height = 16

let create () =
  let t = Helpers.ui ~path:"a" "first\nsecond\nthird" in
  let t =
    List.fold (List.range 0 2) ~init:t ~f:(fun t i ->
      Ui_state.update_feedback t ~width ~height
        (Report
           ( { save with source = sprintf "checker%d" i }
           , Warning
           , sprintf "finding %d" i
           , Some { line = 2; column = 1 } )))
  in
  List.fold (List.range 1 4) ~init:t ~f:(fun t i ->
    Ui_state.update_feedback t ~width ~height (note (sprintf "event %d" i)))
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let feedback t = Controller.feedback (Ui_state.controller t)
let editor t = Controller.editor (Ui_state.controller t)
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)

let band t =
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  print_endline (String.concat ~sep:"\n" (List.drop lines 11))
;;

let copied t =
  let t, clipboard = Ui_state.take_clipboard t in
  print_s [%sexp (clipboard : string option)];
  t
;;

let%expect_test "history tile: follow, select, details, copy, rejection, clear" =
  let t = create () |> fun t -> run t " vb vm" in
  band t;
  [%expect
    {|
    ╭─ Problems (workspace): 2/2 ───────────────────╮ ╭─ History: 5 entries ───────────────────────────╮|
    │ warning [checker0] a:2:1: finding 0           │ │ #3 info [editor] a: event 1                    │|
    │ warning [checker1] a:2:1: finding 1           │ │ #4 info [editor] a: event 2                    │|
    │                                               │ │ #5 info [editor] a: event 3                    │|
    ╰───────────────────────────────────────────────╯ ╰─ +2 earlier ───────────────────────────────────╯|
    cursor: 3,1 Block
    |}];
  (* Focus follows the newest entry, also as entries arrive. *)
  let t = run t " vM" in
  let t = Ui_state.update_feedback t ~width ~height (note "event 4") in
  band t;
  [%expect {|
    ╭─ Problems (workspace): 2/2 ───────────────────╮ ╭─ History*: [6/6] ──────────────────────────────╮|
    │ warning [checker0] a:2:1: finding 0           │ │   #4 info [editor] a: event 2                  │|
    │ warning [checker1] a:2:1: finding 1           │ │   #5 info [editor] a: event 3                  │|
    │                                               │ │ > #6 info [editor] a: event 4                  │|
    ╰───────────────────────────────────────────────╯ ╰─ 3 above, 0 below ─────────────────────────────╯|
    cursor: none
    |}];
  (* Once moved, the selection stays on its entry. *)
  let t = run t "k" in
  let t = Ui_state.update_feedback t ~width ~height (note "event 5") in
  band t;
  [%expect {|
    ╭─ Problems (workspace): 2/2 ───────────────────╮ ╭─ History*: [5/7] ──────────────────────────────╮|
    │ warning [checker0] a:2:1: finding 0           │ │   #4 info [editor] a: event 2                  │|
    │ warning [checker1] a:2:1: finding 1           │ │ > #5 info [editor] a: event 3                  │|
    │                                               │ │   #6 info [editor] a: event 4                  │|
    ╰───────────────────────────────────────────────╯ ╰─ 3 above, 1 below ─────────────────────────────╯|
    cursor: none
    |}];
  (* Details are read-only text: select and copy; edits and paste are rejected. *)
  let t = run t "eVy" in
  let t = copied t in
  [%expect {| ("#5 info [editor] a: event 3\n") |}];
  let t = run t "x" in
  print_endline (Option.value (Ui_state.capture_notice t) ~default:"-");
  let t = Helpers.run ~width ~height t (Helpers.paste "zz") in
  print_endline (Option.value (Ui_state.capture_notice t) ~default:"-");
  [%expect {|
    History: read-only; edits unavailable
    History: read-only; paste ignored
    |}];
  (* A merged repeat of the open entry updates its details, never silently. *)
  let t = run t "<Esc>Ge" in
  let t = Ui_state.update_feedback t ~width ~height (note "event 5") in
  band t;
  [%expect {|
    ╭─ Problems (workspace): 2/2 ───────────────────╮ ╭─ History* details: [7/7] ──────────────────────╮|
    │ warning [checker0] a:2:1: finding 0           │ │ #7 ×2 info [editor] a: event 5                 │|
    │ warning [checker1] a:2:1: finding 1           │ │                                                │|
    │                                               │ │                                                │|
    ╰───────────────────────────────────────────────╯ ╰─ Details updated ──────────────────────────────╯|
    cursor: 52,12 Block
    |}];
  (* Clearing empties history only. *)
  let problems = Feedback.problems (feedback t) in
  let t = run t "X" in
  assert ([%equal: Feedback.Problem.t list] problems (Feedback.problems (feedback t)));
  band t;
  [%expect {|
    ╭─ Problems (workspace): 2/2 ───────────────────╮ ╭─ History*: [0/0] ──────────────────────────────╮|
    │ warning [checker0] a:2:1: finding 0           │ │ No history                                     │|
    │ warning [checker1] a:2:1: finding 1           │ │                                                │|
    │                                               │ │                                                │|
    ╰───────────────────────────────────────────────╯ ╰─ History cleared; active problems unchanged ───╯|
    cursor: none
    |}];
  (* Tab returns; the document never changed. *)
  let t = run t "<Tab>" in
  print_s
    [%message
      (focused t : string)
        ~text:(Text_buffer.to_string (Editor.text (editor t)) : string)
        ~dirty:(Editor.is_dirty (editor t) : bool)];
  [%expect {|
    (("focused t" document) (text  "first\
                                  \nsecond\
                                  \nthird") (dirty false))
    |}]
;;

let%expect_test "an evicted selection moves to the oldest retained entry" =
  let t = create () |> fun t -> run t " vMgg" in
  let selected t =
    (History_tile.selection (Ui_state.history_tile t)).selected |> Option.value ~default:0
  in
  print_s [%sexp (selected t : int)];
  let t =
    List.fold (List.range 0 History.capacity) ~init:t ~f:(fun t i ->
      Ui_state.update_feedback t ~width ~height (note (sprintf "flood %d" i)))
  in
  let first = (List.hd_exn (History.entries (Feedback.history (feedback t)))).seq in
  print_s [%message (selected t : int) (first : int)];
  let t = run t " vM vM" in
  (* Refocusing follows the newest again. *)
  print_s [%sexp (selected t : int)];
  [%expect {|
    1
    (("selected t" 6) (first 6))
    205
    |}]
;;
