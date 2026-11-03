open! Core
open Ches_core
open Ches_completion.Model

let text s = Text_buffer.of_string s |> Result.ok |> Option.value_exn
let token = { Token.resource = "/example.ml"; generation = 3; revision = 0; request = 1 }
let start s at =
  let base = text s in
  start ~token ~text:base ~cursor:at ~words:(Buffer_words.create base) ~limit:100
  |> Option.value_exn |> fst
;;
let candidate ?(additional = []) ?filter_text id ~start ~stop inserted =
  { Candidate.id; source = Lsp "test"; label = id; detail = None
  ; filter_text = Option.value filter_text ~default:inserted; sort_text = id
  ; primary = { Text_edit.start; stop; text = inserted }; additional
  ; cursor = String.length inserted }
;;
let reply t candidates = receive t { Reply.token; source = "test"; candidates; incomplete = false }
let apply t base revision p =
  let result = Text_edit.apply base (edits p) |> Or_error.ok_exn in
  assert (Text_buffer.is_boundary result (cursor p));
  applied t p ~revision, result
;;
let string = Text_buffer.to_string

let%test_unit "cycles primary only; finalize adds only selected extras and ends session" =
  let base = text "f\n" in
  let a = candidate "a" ~start:0 ~stop:1 "foo" in
  let b = candidate "b" ~start:0 ~stop:1 "foobar"
    ~additional:[ { start = 2; stop = 2; text = "import B" } ] in
  let t = reply (start "f\n" 1) [ a; b ] in
  let p = plan t Previous |> Option.value_exn in
  let t, current = apply t base 1 p in
  assert (String.equal (string current) "foo\n");
  let p = plan t Next |> Option.value_exn in
  let t, current = apply t current 2 p in
  assert (String.equal (string current) "foobar\n");
  let p = finalize t |> Option.value_exn in
  let t, current = apply t current 3 p in
  assert (String.equal (string current) "foobar\nimport B");
  assert (cursor p = 6);
  assert (Option.is_none (finalize t));
  assert (Option.is_none (plan t Next))
;;

let%test_unit "full candidate finalization remaps extras before primary and different cycle ranges" =
  let base = text "x\nfz" in
  let a = candidate "a" ~start:2 ~stop:3 "foo" in
  let b = candidate "b" ~filter_text:"f replacement" ~start:2 ~stop:4 "bar"
    ~additional:[ { start = 0; stop = 0; text = "import\n" } ] in
  let t = reply (start "x\nfz" 3) [ a; b ] in
  let t, current = apply t base 1 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "x\nfooz");
  let t, current = apply t current 2 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "x\nbar");
  let p = Option.value_exn (finalize t) in
  let _, current = apply t current 3 p in
  assert (String.equal (string current) "import\nx\nbar");
  assert (cursor p = Text_buffer.length current)
;;

let%test_unit "stale replies and plans, frozen menu, wrap and reverse" =
  let t = reply (start "f" 1)
    [ candidate "a" ~start:0 ~stop:1 "foo"; candidate "b" ~start:0 ~stop:1 "far" ] in
  let stale = receive t { Reply.token = { token with request = 2 }; source = "test"
                        ; candidates = []; incomplete = false } in
  assert (phys_equal stale t);
  let p = Option.value_exn (plan t Next) in
  let t, current = apply t (text "f") 1 p in
  assert (Exn.does_raise (fun () -> ignore (applied t p ~revision:2 : t)));
  assert (matches t ~revision:1 ~cursor:3);
  assert (not (matches t ~revision:0 ~cursor:3));
  assert (phys_equal (reply t []) t);
  let t, current = apply t current 2 (Option.value_exn (plan t Previous)) in
  assert (String.equal (string current) "far");
  let _, current = apply t current 3 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "foo")
;;

let%test_unit "invalid UTF boundaries, overlap and inserted cursor are rejected" =
  let bad_boundary = candidate "a" ~filter_text:"é" ~start:1 ~stop:2 "x" in
  let bad_overlap = candidate "b" ~filter_text:"é" ~start:0 ~stop:2 "x"
    ~additional:[ { start = 0; stop = 0; text = "oops" } ] in
  let bad_cursor = { (candidate "c" ~filter_text:"é" ~start:0 ~stop:2 "🐹") with cursor = 1 } in
  let t = reply (start "é" 2) [ bad_boundary; bad_overlap; bad_cursor ] in
  assert (List.is_empty (candidates t));
  assert (Option.is_none (plan t Next))
;;

let%test_unit "dedup executable edits prefers LSP and ghost is conservative" =
  let t = start "foo f" 5 in
  assert (String.equal (Option.value_exn (ghost t)).text "oo");
  let c = candidate "lsp" ~start:4 ~stop:5 "foo" in
  let t = reply t [ c ] in
  assert (List.length (candidates t) = 1);
  assert (Candidate.equal_source (Option.value_exn (selected t)).source (Lsp "test"));
  let t = reply t [ { c with additional = [ { start = 0; stop = 0; text = "import\n" } ] } ] in
  assert (Option.is_none (ghost t))
;;

let%test_unit "LSP prefix filtering precedes menu limit and is case-sensitive" =
  let nonmatches = List.init 100 ~f:(fun i ->
    candidate (sprintf "assign%d" i) ~start:0 ~stop:2 "assign") in
  let logic = candidate "logic" ~start:0 ~stop:2 "logic" in
  let uppercase = candidate "Logic" ~start:0 ~stop:2 "Logic" in
  let t = reply (start "lo" 2) (nonmatches @ [ uppercase; logic ]) in
  assert (List.equal Candidate.equal (candidates t) [ logic ]);
  assert (String.equal (Option.value_exn (ghost t)).text "gic");
  let _, current = apply t (text "lo") 1 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "logic")
;;

let%test_unit "filter text overrides label and edit range for the original prefix" =
  let accepted = candidate "display name" ~filter_text:"logic" ~start:0 ~stop:7 "replacement" in
  let rejected = candidate "logic" ~filter_text:"assign" ~start:5 ~stop:7 "logic" in
  let t = reply (start "obj. lo" 7) [ rejected; accepted ] in
  assert (List.equal Candidate.equal (candidates t) [ accepted ])
;;

let%test_unit "filtered LSP menu remains frozen while cycling original-prefix matches" =
  let logic = candidate "logic" ~start:0 ~stop:2 "logic" in
  let local = candidate "local" ~start:0 ~stop:2 "local" in
  let t = reply (start "lo" 2) [ logic; local ] in
  let t, current = apply t (text "lo") 1 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "local");
  let late = candidate "logarithm" ~start:0 ~stop:2 "logarithm" in
  assert (phys_equal (reply t [ late ]) t);
  let t, current = apply t current 2 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "logic");
  let _, current = apply t current 3 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "local")
;;

let%test_unit "empty prefix after punctuation accepts all filter texts" =
  let assign = candidate "assign" ~start:4 ~stop:4 "assign" in
  let logic = candidate "logic" ~filter_text:"" ~start:4 ~stop:4 "logic" in
  let t = reply (start "obj." 4) [ logic; assign ] in
  assert (List.equal Candidate.equal (List.take (candidates t) 2) [ assign; logic ]);
  [%test_eq: string list] (List.map (candidates t) ~f:(fun c -> c.Candidate.label))
    [ "assign"; "logic"; "obj" ];
  (* The selected buffer word survives arrival of server candidates. *)
  let t, current = apply t (text "obj.") 1 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "obj.obj");
  let t, current = apply t current 2 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "obj.assign");
  let _, current = apply t current 3 (Option.value_exn (plan t Next)) in
  assert (String.equal (string current) "obj.logic")
;;

let%test_unit "LSP inspection bound and final menu cap still apply" =
  let nonmatch = candidate "assign" ~start:0 ~stop:2 "assign" in
  let logic = candidate "logic" ~start:0 ~stop:2 "logic" in
  let t = reply (start "lo" 2) (List.init 1000 ~f:(fun _ -> nonmatch) @ [ logic ]) in
  assert (List.is_empty (candidates t));
  let matches = List.init 101 ~f:(fun i ->
    let word = sprintf "lo%03d" i in
    candidate word ~start:0 ~stop:2 word) in
  let t = reply (start "lo" 2) (List.rev matches) in
  assert (List.equal Candidate.equal (candidates t) (List.take matches 100))
;;

let%test_unit "whole-buffer words, UTF prefix, lexical order regardless of proximity" =
  let base = text "fox f far" in
  let words = Buffer_words.create base in
  let items = Buffer_words.candidates words ~text:base ~cursor:5 ~limit:2 in
  assert (List.equal String.equal (List.map items ~f:(fun c -> c.Candidate.label)) [ "far"; "fox" ]);
  let base = text "far filler filler fox f" in
  let items = Buffer_words.candidates (Buffer_words.create base) ~text:base
      ~cursor:(Text_buffer.length base) ~limit:1 in
  assert (List.equal String.equal (List.map items ~f:(fun c -> c.Candidate.label)) [ "far" ]);
  let base = text "éclair é" in
  let items = Buffer_words.candidates (Buffer_words.create base) ~text:base ~cursor:10 ~limit:1 in
  assert (String.equal (List.hd_exn items).primary.text "éclair");
  let base = text (String.make 70000 'a' ^ " alpha a") in
  let items = Buffer_words.candidates (Buffer_words.create base) ~text:base
      ~cursor:(Text_buffer.length base) ~limit:100 in
  assert (List.equal String.equal (List.map items ~f:(fun c -> c.Candidate.label))
    [ String.make 70000 'a'; "alpha" ]);
  assert (Option.is_none (Ches_completion.Model.start ~token ~text:base ~cursor:5000
      ~words:(Buffer_words.create base) ~limit:100))
;;
