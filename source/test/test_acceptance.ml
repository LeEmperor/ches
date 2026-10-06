(* Phase 9 acceptance, driven through the synthetic producer: two sources on one file,
   empty replacement, out-of-order versions, edits while computing, bursts,
   disconnect/restart, and hidden views. The interactive checker is one source, like
   ocamllsp; scripts provide several sources and unversioned lists. *)
open! Core
open! Async
open Ches_source
module H = Harness

let synthetic ~time ~root = Synthetic.start ~time_source:time ~root ()

let scripted steps ~time ~root:_ = Synthetic.Script.play ~time_source:time steps

let%expect_test "starting sends the initial text; both checks merge into one list" =
  let t = H.create ~text:"let x = 1\nlet y = ERROR\n(* TODO *)\n" ~source:synthetic () in
  H.send_requests t;
  let%bind () = H.advance t 399 in
  H.rows t;
  [%expect {| (no rows) |}];
  let%bind () = H.advance t 1 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:2:1: synthetic error: the line contains ERROR
    warning [synthetic] a.ml:3:1: synthetic warning: unfinished TODO
    |}];
  let%bind () = H.advance t 400 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:2:1: synthetic error: the line contains ERROR
    error [synthetic] a.ml:2:1: synthetic build error: ERROR does not compile
    warning [synthetic] a.ml:3:1: synthetic warning: unfinished TODO
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  (* Problems are hidden throughout: hidden views still receive (only drawing stops). *)
  print_s [%message (Ches_screen.Ui_state.problems_visible t.ui : bool)];
  H.status t;
  [%expect
    {|
    ("Ches_screen.Ui_state.problems_visible t.ui" false)
    [4 problems: Space v e]
    |}];
  return ()
;;

let%expect_test "unsaved fixes clear the edit check only; saving rebuilds" =
  let t = H.create ~text:"ERROR\nok\n" ~source:synthetic () in
  H.send_requests t;
  let%bind () = H.advance t 800 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:1:1: synthetic error: the line contains ERROR
    error [synthetic] a.ml:1:1: synthetic build error: ERROR does not compile
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  (* Delete the ERROR line: the edit check finds nothing, but the build has not seen
     the change (no save), so its finding stays in the merged list. That list describes
     the current revision, so it is not dimmed, as with ocamllsp and dune. *)
  H.keys t "dd";
  let%bind () = H.advance t 400 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:1:1: synthetic build error: ERROR does not compile
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  H.keys t " w";
  let%bind () = H.advance t 800 in
  H.rows t;
  [%expect
    {| warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened |}];
  return ()
;;

let%expect_test "edits while computing: one check of the newest text, dimmed once behind" =
  let t = H.create ~text:"ok\n" ~source:synthetic () in
  H.send_requests t;
  let%bind () = H.advance t 800 in
  H.keys t "OERROR<Esc>";
  let%bind () = H.advance t 200 in
  (* Still within the first check's delay: these edits join it, so the one check
     describes the newest revision and is not dimmed. *)
  H.keys t "ATODO<Esc>";
  let%bind () = H.advance t 200 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:1:1: synthetic error: the line contains ERROR
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  (* Typing after the check ran dims it until the next one. *)
  H.keys t "x";
  H.rows t;
  [%expect
    {|
    ~ error [synthetic] a.ml:1:1: synthetic error: the line contains ERROR
      warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  let%bind () = H.advance t 400 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:1:1: synthetic error: the line contains ERROR
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  return ()
;;

let finding line message : Ches_error.Error.Diagnostics.Finding.t =
  { severity = Error; message; location = Some { line; column = 1 } }
;;

let%expect_test "two sources on one file: an empty list clears only its own source" =
  let t =
    H.create
      ~text:"abc\n"
      ~source:(fun ~time ~root ->
        let resource = Filename.concat root "a.ml" in
        let snapshot ?revision source findings : Synthetic.Script.step =
          Emit (Diagnostics { source; resource; revision; findings })
        in
        let ms n : Synthetic.Script.step = Wait (Time_ns.Span.of_int_ms n) in
        scripted
          [ snapshot ~revision:0 "lsp" [ finding 1 "from lsp" ]
          ; snapshot "lint" [ finding 1 "from lint, unversioned" ]
          ; ms 10
          ; snapshot ~revision:1 "lsp" []
          ]
          ~time
          ~root)
      ()
  in
  let%bind () = H.advance t 0 in
  H.rows t;
  [%expect
    {|
      error [lint] a.ml:1:1: from lint, unversioned
      error [lsp] a.ml:1:1: from lsp
    |}];
  (* An edit dims both: the unversioned list from the first edit after it arrived. *)
  H.keys t "x";
  H.rows t;
  [%expect
    {|
    ~ error [lint] a.ml:1:1: from lint, unversioned
    ~ error [lsp] a.ml:1:1: from lsp
    |}];
  let%bind () = H.advance t 10 in
  H.rows t;
  [%expect {| ~ error [lint] a.ml:1:1: from lint, unversioned |}];
  return ()
;;

let%expect_test "out-of-order versions: an older revision never replaces a newer one" =
  let t =
    H.create
      ~text:"abc\n"
      ~source:(fun ~time ~root ->
        let snapshot revision message : Synthetic.Script.step =
          Emit
            (Diagnostics
               { source = "lsp"
               ; resource = Filename.concat root "a.ml"
               ; revision = Some revision
               ; findings = [ finding 1 message ]
               })
        in
        scripted
          [ Wait (Time_ns.Span.of_int_ms 10)
          ; snapshot 2 "from revision 2"
          ; Wait (Time_ns.Span.of_int_ms 10)
          ; snapshot 1 "from revision 1, late"
          ]
          ~time
          ~root)
      ()
  in
  H.keys t "xx";
  print_s [%message (Ches_core.Editor.revision (H.editor t) : int)];
  let%bind () = H.advance t 10 in
  H.rows t;
  let%bind () = H.advance t 10 in
  H.rows t;
  [%expect
    {|
    ("Ches_core.Editor.revision (H.editor t)" 2)
      error [lsp] a.ml:1:1: from revision 2
      error [lsp] a.ml:1:1: from revision 2
    |}];
  return ()
;;

let%expect_test "disconnect and restart" =
  let t = H.create ~text:"ERROR\n" ~source:synthetic () in
  H.send_requests t;
  let%bind () = H.advance t 800 in
  H.keys t " vK";
  let%bind () = H.advance t 0 in
  H.rows t;
  H.status t;
  [%expect
    {|
      error [synthetic] <root>: Checker stopped: killed by Space v K (synthetic crash)
    ~ error [synthetic stopped] a.ml:1:1: synthetic error: the line contains ERROR
    ~ error [synthetic stopped] a.ml:1:1: synthetic build error: ERROR does not compile
    ~ warning [synthetic stopped] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    [4 problems] Checker stopped: killed by Space v K (synthetic crash)
    |}];
  (* Stopped sources ignore edits; a restart clears the stopped marker and checks the
     newest text again; kept findings stay dimmed until replaced. *)
  H.keys t "<Esc>dd";
  let%bind () = H.advance t 1000 in
  H.rows t;
  [%expect
    {|
      error [synthetic] <root>: Checker stopped: killed by Space v K (synthetic crash)
    ~ error [synthetic stopped] a.ml:1:1: synthetic error: the line contains ERROR
    ~ error [synthetic stopped] a.ml:1:1: synthetic build error: ERROR does not compile
    ~ warning [synthetic stopped] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  H.keys t " vR";
  let%bind () = H.advance t 0 in
  H.rows t;
  [%expect
    {|
    ~ error [synthetic] a.ml:1:1: synthetic error: the line contains ERROR
    ~ error [synthetic] a.ml:1:1: synthetic build error: ERROR does not compile
    ~ warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  let%bind () = H.advance t 800 in
  H.rows t;
  [%expect
    {|
    error [synthetic] a.ml:1:1: synthetic build error: ERROR does not compile
    warning [synthetic] synthetic_other.ml:3:1: synthetic build warning: unused value in a file you have not opened
    |}];
  return ()
;;

let%expect_test "a burst reaches the UI as one snapshot per collection, in bounded batches" =
  let burst =
    Synthetic.Script.burst ~source:"lsp" ~snapshots:1000 ~resources:100 ~findings:5
  in
  let t =
    H.create
      ~source:(fun ~time ~root ->
        scripted (List.map burst ~f:(fun event -> Synthetic.Script.Emit event)) ~time ~root)
      ()
  in
  let dropped = Source.dropped t.source in
  let batches = H.deliver t in
  print_s [%message (dropped : int) (batches : int list)];
  H.status t;
  [%expect
    {|
    ((dropped 900) (batches (64 36)))
    [500 problems: Space v e]
    |}];
  return ()
;;
