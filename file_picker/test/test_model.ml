open! Core
open Ches_file_picker.Model

let candidate ?(root = "/project") path =
  Candidate.create ~root ~relative_path:path |> Or_error.ok_exn
;;

let result candidate : Query_result.t = { candidate; score = 0; positions = [] }

let snapshot (status : Discovery.status) candidates : Discovery.t =
  { request = { run_id = Run_id.of_int 1; root = "/project" }; candidates; status }
;;

let%test_unit "lazy alignment is byte- and count-bounded and returns uncached oversized positions exactly" =
  let candidates = List.init 3 ~f:(fun i -> candidate (sprintf "abcdefghijklmnopqrstuvwx%d.ml" i)) in
  let identities = Result_index.Identity.Builder.create () in
  List.iter candidates ~f:(Result_index.Identity.Builder.append identities);
  let identity = Result_index.Identity.Builder.finish identities in
  let builder = Result_index.Builder.create () in
  List.iteri candidates ~f:(fun ordinal candidate ->
    Result_index.Builder.append_scored builder ~ordinal ~candidate ~score:10);
  let align c = if String.is_suffix (Candidate.relative_path c) ~suffix:"2.ml"
    then List.range 0 26 else List.range 0 10 in
  let index = Result_index.Builder.finish builder ~identity ~align ~alignment_byte_limit:512 in
  let model = with_result_index (create ~token:() ~discovery:(snapshot Partial candidates)) ~query:"x" index in
  ignore (result_at model 0 : Query_result.t option);
  assert (For_testing.alignment_cache_size model = 1 && For_testing.alignment_cache_bytes model <= 512);
  ignore (result_at model 1 : Query_result.t option);
  assert (For_testing.alignment_cache_size model = 1); (* bytes evict before the count cap *)
  let before = For_testing.alignment_count model in
  ignore (result_at model 0 : Query_result.t option);
  assert (For_testing.alignment_count model = before + 1);
  let bytes = For_testing.alignment_cache_bytes model in
  let oversized = Option.value_exn (result_at model 2) in
  [%test_eq: int list] oversized.positions (List.range 0 26);
  ignore (result_at model 2 : Query_result.t option);
  assert (For_testing.alignment_count model = before + 3);
  assert (For_testing.alignment_cache_bytes model = bytes && For_testing.alignment_cache_size model = 1)
;;

let%test_unit "chunk builder transfers ownership and indexes boundary positions without a final corpus copy" =
  let builder = Result_index.Builder.create () in
  let candidates = List.init 257 ~f:(fun n -> candidate (sprintf "%03d.ml" n)) in
  List.iter candidates ~f:(fun c -> Result_index.Builder.append builder (result c));
  let index = Result_index.Builder.finish builder in
  assert (Result_index.length index = 257);
  assert (Result.is_error (Or_error.try_with (fun () ->
    Result_index.Builder.append builder (result (candidate "late.ml")))));
  let t = with_result_index
    (create ~token:() ~discovery:(snapshot Partial candidates)) ~query:"" index in
  List.iter [ 0; 127; 128; 255; 256 ] ~f:(fun position ->
    let t = select_index t position in
    assert (Option.equal Int.equal (selected_index t) (Some position));
    [%test_eq: string]
      (Option.value_exn (selected_result t) |> fun (r : Query_result.t) -> Candidate.relative_path r.candidate)
      (sprintf "%03d.ml" position));
  assert (not (For_testing.results_forced t));
  [%test_eq: int] (List.length (result_slice t ~start:125 ~length:6)) 6;
  [%test_eq: int] (List.length (results t)) 257;
  assert (For_testing.results_forced t && phys_equal (results t) (results t))
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
  [%test_eq: int option] (selected_index t) (Some 1);
  let t = with_results t ~query:"m" [ result c; result a; result b ] in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id b));
  [%test_eq: int] (result_count t) 3;
  [%test_eq: int option] (selected_index t) (Some 2);
  [%test_eq: string list]
    (List.map (result_slice t ~start:1 ~length:100) ~f:(fun r -> Candidate.path r.candidate))
    [ "/project/a/main.ml"; "/project/b/main.ml" ];
  assert (Option.is_none (result_at t (-1)) && Option.is_none (result_at t 3));
  assert (phys_equal (results t) (results t)); (* compatibility list is cached *)
  assert (phys_equal t (select_index t 3));
  [%test_eq: string] (query t) "m";
  let t = select t (Candidate.id (candidate "not-a-result")) in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id b));
  let t = with_results t ~query:"c" [ result c; result a ] in
  [%test_eq: Candidate.Id.t option] (selected t) (Some (Candidate.id c));
  [%test_eq: int option] (selected_index t) (Some 0);
  let t = with_results t ~query:"none" [] in
  assert (Option.is_none (selected t));
  assert (Option.is_none (selected_index t) && result_count t = 0);
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
