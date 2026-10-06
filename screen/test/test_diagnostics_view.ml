open! Core
open Ches_core
open Ches_screen
open Helpers
module Feedback = Ches_error.Error
module Source_event = Ches_error.Source_event
module Controller = Ches_app.Controller

let width = 80
let height = 16
let run t s = Helpers.run ~width ~height t (keys s)
let feedback t = Controller.feedback (Ui_state.controller t)
let editor t = Controller.editor (Ui_state.controller t)

let source t event = Helpers.run ~width ~height t [ Source event ]

let finding ?(severity = Feedback.Severity.Error) line message
  : Feedback.Diagnostics.Finding.t
  =
  { severity; message; location = Some { line; column = 1 } }
;;

let diagnostics ?revision ?(source = "ocaml") ?(resource = "a.ml") findings =
  Source_event.Diagnostics { source; resource; revision; findings }
;;

let create () = ui ~path:"a.ml" "let x = 1\nlet y = x +\nlet z = 3\n"

(* The rows as the problems view lists them: selection marker, dimming, description. *)
let rows t =
  let selected =
    (Ui_state.problem_navigation t ~width ~height).selected
  in
  List.iter
    (Problems_tile.entries
       (Ui_state.problems_tile t)
       (feedback t)
       ~document:(Problems_tile.document (Ui_state.problems_tile t) (editor t)))
    ~f:(fun (row : Problems.Row.t) ->
      let stale =
        match row.kind with
        | Finding { stale = true; _ } -> "~"
        | Finding _ | Problem _ -> " "
      in
      let mark =
        if Option.exists selected ~f:(Problems.Key.equal row.key) then ">" else " "
      in
      printf "%s%s %s\n" mark stale (Problems.description row))
;;

let message t =
  Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)
;;

let%expect_test "problems first, then findings by file, severity, and position" =
  let t =
    create ()
    |> fun t ->
    Ui_state.update_feedback
      t
      ~width
      ~height
      (Failed ({ source = "file"; kind = Save; resource = "a.ml" }, Error, "save failed"))
    |> fun t ->
    source
      t
      (diagnostics
         ~revision:0
         [ finding ~severity:Warning 1 "unused x"; finding 3 "type error"; finding 2 "syntax" ])
    |> fun t ->
    source
      t
      (diagnostics ~source:"lint" [ finding ~severity:Warning 1 "long line" ])
    |> fun t -> source t (diagnostics ~resource:"0.ml" ~revision:4 [ finding 9 "elsewhere" ])
  in
  rows t;
  [%expect
    {|
    >  error [file] a.ml: save failed
       error [ocaml] 0.ml:9:1: elsewhere
       error [ocaml] a.ml:2:1: syntax
       error [ocaml] a.ml:3:1: type error
       warning [lint] a.ml:1:1: long line
       warning [ocaml] a.ml:1:1: unused x
    |}];
  (* Findings count, but only the save failure takes attention. *)
  print_endline (message t);
  let t = run t "<Esc>" in
  print_endline (message t);
  [%expect
    {|
    [6 problems] save failed
    [6 problems: Space v e]
    |}];
  let t = run t " vf" in
  rows t;
  [%expect
    {|
    >  error [file] a.ml: save failed
       error [ocaml] a.ml:2:1: syntax
       error [ocaml] a.ml:3:1: type error
       warning [lint] a.ml:1:1: long line
       warning [ocaml] a.ml:1:1: unused x
    |}]
;;

let%expect_test "findings dim while behind, other files never; stopped sources are marked" =
  let t =
    create ()
    |> fun t ->
    source t (diagnostics ~revision:0 [ finding 2 "syntax" ])
    |> fun t ->
    source t (diagnostics ~source:"lint" [ finding ~severity:Warning 1 "long line" ])
    |> fun t -> source t (diagnostics ~resource:"b.ml" ~revision:0 [ finding 1 "other" ])
  in
  rows t;
  [%expect
    {|
    >  error [ocaml] a.ml:2:1: syntax
       warning [lint] a.ml:1:1: long line
       error [ocaml] b.ml:1:1: other
    |}];
  let t = run t "x" in
  rows t;
  [%expect
    {|
    >~ error [ocaml] a.ml:2:1: syntax
     ~ warning [lint] a.ml:1:1: long line
       error [ocaml] b.ml:1:1: other
    |}];
  (* The versioned source catches up; the unversioned one catches up on arrival. *)
  let revision = Editor.revision (editor t) in
  let t =
    source t (diagnostics ~revision [ finding 2 "syntax" ])
    |> fun t -> source t (diagnostics ~source:"lint" [])
  in
  rows t;
  [%expect
    {|
    >  error [ocaml] a.ml:2:1: syntax
       error [ocaml] b.ml:1:1: other
    |}];
  let t = source t (Stopped { source = "ocaml"; root = "/w"; reason = "exit 2" }) in
  rows t;
  print_endline (message t);
  [%expect
    {|
       error [ocaml] /w: Checker stopped: exit 2
    >~ error [ocaml stopped] a.ml:2:1: syntax
     ~ error [ocaml stopped] b.ml:1:1: other
    [3 problems] Checker stopped: exit 2
    |}];
  let t = source t (Started { source = "ocaml"; root = "/w" }) in
  rows t;
  [%expect
    {|
    >~ error [ocaml] a.ml:2:1: syntax
     ~ error [ocaml] b.ml:1:1: other
    |}];
  let t = source t (diagnostics ~revision [ finding 2 "syntax" ]) in
  rows t;
  [%expect
    {|
    >  error [ocaml] a.ml:2:1: syntax
     ~ error [ocaml] b.ml:1:1: other
    |}];
  (* The dimmed row is drawn in the muted style. *)
  let t = run t " vb" in
  let screen = Frame.to_string_styled (Frame.render t ~width ~height) in
  print_endline
    (List.filter (String.split_lines screen) ~f:(String.is_substring ~substring:"b.ml")
     |> String.concat ~sep:"\n");
  [%expect {| Border[│] Status[ ] Stale[error [ocaml] b.ml:1:1: other] Status[                                                ] Border[│] |}]
;;

let%expect_test "selection follows a moved finding, else keeps its position" =
  let t =
    create ()
    |> fun t ->
    source
      t
      (diagnostics
         ~revision:0
         [ finding 1 "first"; finding 2 "second"; finding 3 "third" ])
    |> fun t -> run t " vojj"
  in
  rows t;
  [%expect
    {|
       error [ocaml] a.ml:1:1: first
       error [ocaml] a.ml:2:1: second
    >  error [ocaml] a.ml:3:1: third
    |}];
  (* A line inserted above: the checker reports the same findings one line down, plus a
     new one, so the selected finding's index changes but its line text does not. *)
  let t =
    run t "<Tab>ggOnew<Esc> vo"
    |> fun t ->
    source
      t
      (diagnostics
         ~revision:(Editor.revision (editor t))
         [ finding 1 "fresh"; finding 2 "first"; finding 3 "second"; finding 4 "third" ])
  in
  rows t;
  [%expect
    {|
       error [ocaml] a.ml:1:1: fresh
       error [ocaml] a.ml:2:1: first
       error [ocaml] a.ml:3:1: second
    >  error [ocaml] a.ml:4:1: third
    |}];
  (* The selected finding goes: the row now at its position, clamped to the last. *)
  let t = source t (diagnostics ~revision:9 [ finding 2 "first"; finding 3 "second" ]) in
  rows t;
  [%expect
    {|
       error [ocaml] a.ml:2:1: first
    >  error [ocaml] a.ml:3:1: second
    |}];
  (* Findings cannot be acknowledged; Enter jumps to one. *)
  let t = run t "a" in
  print_endline (Option.value (Ui_state.capture_notice t) ~default:"");
  let t = run t "k<CR>" in
  print_s [%sexp (Editor.cursor (editor t) : int)];
  [%expect
    {|
    Diagnostics are not acknowledged
    4
    |}]
;;

let%expect_test "lists that arrive during Insert wait until it ends; stops do not" =
  let t =
    create ()
    |> fun t -> source t (diagnostics ~revision:0 [ finding 1 "old" ]) |> fun t -> run t "ix"
  in
  let t =
    source t (diagnostics ~revision:1 [ finding 1 "newer" ])
    |> fun t ->
    source t (diagnostics ~revision:1 [ finding 1 "newest" ])
    |> fun t -> source t (diagnostics ~source:"lint" [ finding 2 "unversioned" ])
  in
  rows t;
  [%expect {| >~ error [ocaml] a.ml:1:1: old |}];
  let t = run t "y" in
  let t = source t (Stopped { source = "dune"; root = "/w"; reason = "gone" }) in
  rows t;
  [%expect
    {|
       error [dune] /w: Checker stopped: gone
    >~ error [ocaml] a.ml:1:1: old
    |}];
  let t = run t "<Esc>" in
  rows t;
  [%expect
    {|
       error [dune] /w: Checker stopped: gone
    >~ error [ocaml] a.ml:1:1: newest
     ~ error [lint] a.ml:2:1: unversioned
    |}]
;;
