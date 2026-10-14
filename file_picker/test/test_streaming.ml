open! Core
open Ches_file_picker
module I = Interaction
module D = Model.Discovery
let candidate path = Model.Candidate.create ~root:"/project" ~relative_path:path |> Or_error.ok_exn
let initial () = D.Update.initial { run_id = Model.Run_id.of_int 1; root = "/project" }
let create update =
  let t = I.create ~token:() ~discovery:{ D.request = update.D.Update.request; candidates = []; status = Loading } in
  assert (I.install_update t update); t
let drain t =
  let turns = ref 0 in
  while I.busy t do
    incr turns; assert (!turns < 2000);
    let scored = I.scored_count t and indexed = I.indexed_count t in
    I.work t ~budget:7;
    assert (I.scored_count t - scored <= 7 && I.indexed_count t - indexed <= 7)
  done
let check t update =
  let candidates = D.Candidates.to_list update.D.Update.candidates in
  [%test_eq: string]
    (Sexp.to_string [%sexp (Model.results (I.model t) : Model.Query_result.t list)])
    (Sexp.to_string [%sexp (Test_search.oracle (I.query t) candidates : Model.Query_result.t list)])

let%test_unit "unchanged streaming query scores/prepares each candidate once, publishing sorted persistent partial sets" =
  let update = ref (initial ()) in
  let t = create !update in
  I.update t (Paste "model");
  let compiles = I.compiled_count t in
  for batch = 0 to 15 do
    let additions = List.init 16 ~f:(fun i -> candidate (sprintf "dir_%04d/model.ml" (255 - batch * 16 - i))) in
    update := D.Update.append !update ~status:Partial additions;
    assert (I.install_update t !update);
    drain t;
    assert (I.prepared_count t = (batch + 1) * 16 && I.scored_count t = (batch + 1) * 16);
    assert (Model.result_count (I.model t) = (batch + 1) * 16);
    assert (not (D.Candidates.materialized !update.candidates));
    assert (I.compiled_count t = compiles)
  done;
  let selected = Model.selected (I.model t) in
  let scored = I.scored_count t in
  update := D.Update.append !update ~status:(Complete { truncated = true }) [];
  assert (I.install_update t !update && not (I.busy t));
  assert (I.scored_count t = scored);
  [%test_eq: Model.Candidate.Id.t option] (Model.selected (I.model t)) selected;
  check t !update
;;

let%test_unit "arrivals do not restart an unfinished rank; edits restart only scoring, retaining intake and preparation" =
  let u0 = initial () in let t = create u0 in
  I.update t (Paste "m");
  let u1 = D.Update.append u0 ~status:Partial
    (List.init 80 ~f:(fun i -> candidate (sprintf "d%03d/model.ml" i))) in
  assert (I.install_update t u1);
  I.work t ~budget:5;
  assert (I.prepared_count t = 5 && I.scored_count t = 5 && I.busy t);
  let u2 = D.Update.append u1 ~status:Partial [ candidate "0/model.ml"; candidate "界/模型.ml" ] in
  assert (I.install_update t u2);
  drain t;
  assert (I.prepared_count t = 82 && I.scored_count t = 82);
  I.update t (Paste "o"); I.work t ~budget:5;
  let before = I.scored_count t in
  I.update t (Paste "del");
  let u3 = D.Update.append u2 ~status:(Failed "partial failure") [ candidate "odd/line\nmodel.ml" ] in
  assert (I.install_update t u3);
  let calls = ref 0 in
  I.accept t ~release:(fun () -> incr calls) ~consume:(fun _ -> incr calls);
  assert (!calls = 0);
  drain t;
  assert (I.prepared_count t = 83 && I.scored_count t - before = 83);
  check t u3;
  assert (not (I.install_update t u2));
  assert (not (I.install_update t { u3 with request = { u3.request with run_id = Model.Run_id.of_int 2 } }));
  I.cancel t ~release:ignore;
  assert (not (I.install_update t u3));
  let reopened = create (initial ()) in
  assert (not (I.install_update reopened u3))
;;

let%test_unit "cached or narrowed queries include additions, reject old completed sets, and keep old published models immutable" =
  let u0 = initial () in let t = create u0 in
  I.update t (Paste "mod");
  let u1 = D.Update.append u0 ~status:Partial
    [ candidate "z/model.ml"; candidate "b/model.ml"; candidate "a/model.ml"; candidate "x/runner.txt" ] in
  assert (I.install_update t u1); drain t;
  let old = I.model t in
  let expected = Model.results old in
  let scored = I.scored_count t in
  I.update t (Paste "el"); I.work t ~budget:1;
  let u2 = D.Update.append u1 ~status:Partial [ candidate "0/model.ml" ] in
  assert (I.install_update t u2 && I.cache_entries t = 0);
  drain t;
  assert (I.scored_count t - scored = 4); (* three old survivors + new candidate *)
  check t u2;
  [%test_eq: string]
    (Sexp.to_string [%sexp (Model.results old : Model.Query_result.t list)])
    (Sexp.to_string [%sexp (expected : Model.Query_result.t list)]);
  I.update t Delete_word; drain t; I.update t (Paste "model");
  assert (I.busy t);
  let u3 = D.Update.append u2 ~status:(Complete { truncated = false }) [ candidate "00/model.ml" ] in
  let before = I.scored_count t in
  assert (I.install_update t u3);
  drain t;
  assert (I.scored_count t - before = 1); (* pending reuse extends its complete tree *)
  check t u3;
  I.update t Delete_word; drain t;
  let names = Model.results (I.model t) |> List.map ~f:(fun r -> Model.Candidate.relative_path r.Model.Query_result.candidate) in
  [%test_eq: string list] names [ "0/model.ml"; "00/model.ml"; "a/model.ml"; "b/model.ml"; "x/runner.txt"; "z/model.ml" ]
;;
