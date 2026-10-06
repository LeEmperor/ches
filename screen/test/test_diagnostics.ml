open! Core
module Feedback = Ches_error.Error
module Diagnostics = Feedback.Diagnostics

let finding ?(severity = Feedback.Severity.Error) ?line message : Diagnostics.Finding.t =
  { severity
  ; message
  ; location = Option.map line ~f:(fun line -> { Feedback.Problem.Location.line; column = 1 })
  }
;;

let receive ?revision ?(current = 0) ~source ~resource findings f =
  Feedback.apply
    f
    (Diagnostics_received
       { source; resource; revision; current_revision = current; findings })
;;

let show ?revision f =
  let collections = Diagnostics.collections (Feedback.diagnostics f) in
  if List.is_empty collections then print_endline "(no diagnostics)";
  List.iter collections ~f:(fun c ->
    let basis =
      match c.basis with
      | Reported r -> sprintf "rev %d" r
      | Arrived_at r -> sprintf "arrived at %d" r
    in
    let behind =
      match revision with
      | Some revision when Diagnostics.Collection.behind c ~revision -> " behind"
      | _ -> ""
    in
    printf
      "%s [%s] %s%s%s: %s\n"
      c.resource
      c.source
      basis
      behind
      (if c.session_ended then " session-ended" else "")
      (String.concat ~sep:"; " (List.map c.findings ~f:(fun f -> f.message))));
  List.iter (Feedback.problems f) ~f:(fun p ->
    printf
      "problem %s: %s%s\n"
      (Sexp.to_string (Feedback.Identity.sexp_of_t p.identity))
      p.text
      (if p.attention then " (attention)" else ""))
;;

let%expect_test "two sources on one file replace independently; empty clears one" =
  let f =
    Feedback.empty
    |> receive ~revision:1 ~source:"ocaml" ~resource:"a.ml" [ finding "type error" ]
    |> receive ~revision:1 ~source:"lint" ~resource:"a.ml" [ finding "long line" ]
    |> receive ~revision:1 ~source:"ocaml" ~resource:"b.ml" [ finding "unbound" ]
  in
  show f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 1: type error
    b.ml [ocaml] rev 1: unbound
    |}];
  let f =
    receive
      ~revision:2
      ~source:"ocaml"
      ~resource:"a.ml"
      [ finding "first"; finding "second" ]
      f
  in
  show f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 2: first; second
    b.ml [ocaml] rev 1: unbound
    |}];
  let f = receive ~revision:3 ~source:"ocaml" ~resource:"a.ml" [] f in
  show f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    b.ml [ocaml] rev 1: unbound
    |}];
  (* Diagnostics are not problems: no attention, no history. *)
  assert (List.is_empty (Feedback.problems f));
  assert (Option.is_none (Feedback.notification f));
  assert (List.is_empty (Feedback.History.entries (Feedback.history f)))
;;

let%expect_test "older reported revisions are dropped, equal ones replace, even after an \
                 empty clear"
  =
  let f =
    Feedback.empty
    |> receive ~revision:5 ~source:"ocaml" ~resource:"a.ml" [ finding "at five" ]
    |> receive ~revision:4 ~source:"ocaml" ~resource:"a.ml" [ finding "late four" ]
  in
  show f;
  [%expect {| a.ml [ocaml] rev 5: at five |}];
  let f = receive ~revision:5 ~source:"ocaml" ~resource:"a.ml" [ finding "five again" ] f in
  show f;
  [%expect {| a.ml [ocaml] rev 5: five again |}];
  let f =
    f
    |> receive ~revision:6 ~source:"ocaml" ~resource:"a.ml" []
    |> receive ~revision:5 ~source:"ocaml" ~resource:"a.ml" [ finding "late five" ]
  in
  show f;
  [%expect {| (no diagnostics) |}];
  (* Behind is relative to the caller's current revision. *)
  let f = receive ~revision:7 ~source:"ocaml" ~resource:"a.ml" [ finding "seven" ] f in
  show ~revision:7 f;
  show ~revision:8 f;
  [%expect
    {|
    a.ml [ocaml] rev 7: seven
    a.ml [ocaml] rev 7 behind: seven
    |}]
;;

let%expect_test "unversioned snapshots record the revision they arrived at" =
  let f =
    Feedback.empty
    |> receive ~current:3 ~source:"lint" ~resource:"a.ml" [ finding "first" ]
  in
  show ~revision:3 f;
  show ~revision:4 f;
  [%expect
    {|
    a.ml [lint] arrived at 3: first
    a.ml [lint] arrived at 3 behind: first
    |}];
  let f = receive ~current:4 ~source:"lint" ~resource:"a.ml" [ finding "second" ] f in
  show ~revision:4 f;
  [%expect {| a.ml [lint] arrived at 4: second |}]
;;

let%expect_test "stop keeps findings and warns in history; restart clears the stop" =
  let stats f =
    let d = Feedback.diagnostics f in
    printf
      "stopped=%b history=%d\n"
      (Diagnostics.stopped d ~source:"ocaml")
      (List.length (Feedback.History.entries (Feedback.history f)))
  in
  let f =
    Feedback.empty
    |> receive ~revision:1 ~source:"ocaml" ~resource:"a.ml" [ finding "type error" ]
    |> receive ~revision:1 ~source:"lint" ~resource:"a.ml" [ finding "long line" ]
    |> fun f ->
    Feedback.apply f (Source_stopped { source = "ocaml"; root = "/w"; reason = "exit 2" })
  in
  show f;
  stats f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 1 session-ended: type error
    stopped=true history=1
    |}];
  (* A late snapshot from the dead session is still session-ended. *)
  let f = receive ~revision:2 ~source:"ocaml" ~resource:"a.ml" [ finding "late" ] f in
  show f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 2 session-ended: late
    |}];
  let f =
    Feedback.apply f (Source_stopped { source = "ocaml"; root = "/w"; reason = "exit 2" })
  in
  show f;
  stats f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 2 session-ended: late
    stopped=true history=1
    |}];
  let f = Feedback.apply f (Source_started { source = "ocaml"; root = "/w" }) in
  show f;
  stats f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 2 session-ended: late
    stopped=false history=1
    |}];
  let f = receive ~revision:3 ~source:"ocaml" ~resource:"a.ml" [ finding "fresh" ] f in
  show f;
  [%expect
    {|
    a.ml [lint] rev 1: long line
    a.ml [ocaml] rev 3: fresh
    |}];
  List.iter (Feedback.History.entries (Feedback.history f)) ~f:(fun e ->
    print_s [%sexp (e : Feedback.History.Entry.t)]);
  [%expect
    {|
    ((seq 1)
     (event
      (Notified
       ((source ocaml) (scope ()) (severity Warning)
        (text "ocaml stopped: exit 2 (Space v R to restart)") (history true))))
     (count 2))
    |}]
;;

let%expect_test "a stop is a one-off warning, not a problem; unavailable is history only" =
  let notification f =
    print_endline
      (Option.value_map (Feedback.notification f) ~default:"(none)" ~f:(fun n ->
         sprintf
           "%s %s"
           (Sexp.to_string (Feedback.Severity.sexp_of_t n.severity))
           n.text))
  in
  let history f =
    List.iter (Feedback.History.entries (Feedback.history f)) ~f:(fun e ->
      print_s [%sexp (e.event : Feedback.History.Event.t)])
  in
  let f =
    Feedback.apply
      Feedback.empty
      (Source_stopped { source = "ocamllsp"; root = "/w"; reason = "exit 2" })
  in
  notification f;
  [%expect {| Warning ocamllsp stopped: exit 2 (Space v R to restart) |}];
  (* The next command clears it, as any notification; nothing waits for Escape. *)
  let f = Feedback.apply f Command_completed in
  notification f;
  show f;
  [%expect
    {|
    (none)
    (no diagnostics)
    |}];
  (* A restart that finds no server leaves the earlier stop, and its marker, in place. *)
  let f =
    Feedback.apply
      (Feedback.apply f Clear_history)
      (Source_unavailable
         { source = "ocamllsp"; root = "/w"; reason = "ocamllsp not found on PATH" })
  in
  notification f;
  history f;
  print_s [%sexp (Feedback.Diagnostics.stopped (Feedback.diagnostics f) ~source:"ocamllsp" : bool)];
  [%expect
    {|
    (none)
    (Notified
     ((source ocamllsp) (scope ()) (severity Error)
      (text "ocamllsp unavailable: ocamllsp not found on PATH") (history true)))
    true
    |}]
;;
