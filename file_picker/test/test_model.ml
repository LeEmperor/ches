open! Core
open Ches_file_picker.Model

let candidate ?(root = "/project") path =
  Candidate.create ~root ~relative_path:path |> Or_error.ok_exn
;;

let result candidate : Query_result.t = { candidate; score = 0; positions = [] }

let snapshot (status : Discovery.status) candidates : Discovery.t =
  { request = { run_id = Run_id.of_int 1; root = "/project" }; candidates; status }
;;

let%test_unit "candidate path bytes and safe display stay separate" =
  let raw = "dir/a\n\t\027\127\194\133\255\\xFF-é" in
  let c = candidate ~root:"/project///" raw in
  [%test_eq: string] (Candidate.relative_path c) raw;
  [%test_eq: string] (Candidate.path c) ("/project/" ^ raw);
  [%test_eq: string] (Candidate.Id.to_string (Candidate.id c)) (Candidate.path c);
  [%test_eq: string]
    (Candidate.display_path c)
    "dir/a\\x0A\\x09\\x1B\\x7F\\xC2\\x85\\xFF\\\\xFF-é";
  assert (Stdlib.String.is_valid_utf_8 (Candidate.display_path c));
  assert (not (String.equal (Candidate.display_path (candidate "\255"))
                 (Candidate.display_path (candidate "\\xFF"))));
  [%test_eq: string] (Candidate.path (candidate ~root:"/" "a b")) "/a b"
;;

let%test_unit "reject invalid lexical paths without accessing the filesystem" =
  List.iter [ ""; "/a"; "a/"; "a//b"; "."; "../a"; "a/../b"; "a/./b"; "a\000b" ]
    ~f:(fun relative_path ->
      assert (Or_error.is_error (Candidate.create ~root:"/project" ~relative_path)));
  List.iter [ ""; "project"; "/a\000b" ] ~f:(fun root ->
    assert (Or_error.is_error (Candidate.create ~root ~relative_path:"a")));
  ignore (candidate ~root:"/does-not-exist" "missing" : Candidate.t)
;;

let%test_unit "selection is identity based across ranking and incremental results" =
  let a = candidate "a/main.ml" in
  let b = candidate "b/main.ml" in
  let c = candidate "c.ml" in
  assert (not (Candidate.Id.equal (Candidate.id a) (Candidate.id b)));
  let t = create ~token:7 ~discovery:(snapshot Partial [ a; b ]) in
  assert (Option.is_none (accept t));
  let t = with_results t ~query:"main" [ result a; result b ] in
  let t = select t (Candidate.id b) in
  let t = with_results t ~query:"m" [ result c; result b; result a ] in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id b));
  [%test_eq: string] (query t) "m";
  let t = select t (Candidate.id (candidate "not-a-result")) in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id b));
  let t = with_results t ~query:"c" [ result c; result a ] in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id c));
  let t = with_results t ~query:"none" [] in
  assert (Option.is_none (selected t));
  assert (Option.is_none (accept t))
;;

let%test_unit "discovery states distinguish loading empty partial failure and truncation" =
  let c = candidate "a" in
  List.iter
    [ Discovery.Loading, []; Partial, [ c ]; Complete { truncated = false }, []
    ; Complete { truncated = true }, [ c ]; Failed "rg unavailable", [ c ]; Cancelled, []
    ]
    ~f:(fun (status, candidates) ->
      let t = create ~token:() ~discovery:(snapshot status candidates) in
      assert (Discovery.equal_status (discovery t).status status);
      assert (Run_id.equal (discovery t).request.run_id (Run_id.of_int 1));
      assert (not (Run_id.equal (discovery t).request.run_id (Run_id.of_int 2)));
      assert (Option.is_none (accept t)))
;;

let%test_unit "fake consumer receives exactly one raw existing-path intent; cancel emits none" =
  let c = candidate "unsafe\n\255.ml" in
  let make () =
    create ~token:"invoking-session" ~discovery:(snapshot (Complete { truncated = false }) [ c ])
    |> fun t -> with_results t ~query:"" [ result c ]
  in
  let active = ref (Some (make ())) in
  let requests = ref [] in
  let consume (request : string Request.t) = requests := request :: !requests in
  let enter () =
    match !active with
    | None -> ()
    | Some t ->
      Option.iter (accept t) ~f:(fun request ->
        active := None;
        consume request)
  in
  enter ();
  enter ();
  let request = List.hd_exn !requests in
  [%test_eq: int] (List.length !requests) 1;
  [%test_eq: string] request.token "invoking-session";
  [%test_eq: string] request.path ("/project/unsafe\n\255.ml");
  active := Some (make ());
  active := None;
  enter ();
  [%test_eq: int] (List.length !requests) 1
;;
