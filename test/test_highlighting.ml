open! Core
open Ches_core
open Ches_app
open Ches_highlight
module Provider = Ches_highlight_ocaml.Provider

let text source =
  Text_buffer.of_string source
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;
let create ?path source = Controller.create (Editor.create ?path ~cell_width:Cell_width.f (text source))
let input t input =
  let old_source = Text_buffer.to_string (Editor.text (Controller.editor t)) in
  let t, _, status = Controller.handle_input t input in
  assert (Controller.Status.equal status Running);
  let new_source = Text_buffer.to_string (Editor.text (Controller.editor t)) in
  (match Edit.between ~old_source ~new_source with
   | None -> assert (String.equal old_source new_source)
   | Some edit ->
     let replacement = String.sub new_source ~pos:edit.start_byte
         ~len:(edit.new_end_byte - edit.start_byte) in
     [%test_result: string]
       (String.prefix old_source edit.start_byte ^ replacement ^ String.drop_prefix old_source edit.old_end_byte)
       ~expect:new_source;
     let point source offset : Edit.point =
       let lines = String.split (String.prefix source offset) ~on:'\n' in
       { row = List.length lines - 1; column = String.length (List.last_exn lines) }
     in
     [%test_result: Edit.point] edit.start_point ~expect:(point old_source edit.start_byte);
     [%test_result: Edit.point] edit.old_end_point ~expect:(point old_source edit.old_end_byte);
     [%test_result: Edit.point] edit.new_end_point ~expect:(point new_source edit.new_end_byte));
  t
;;
let run t keys = List.fold (Key_notation.keys keys) ~init:t ~f:input
let source t = Text_buffer.to_string (Editor.text (Controller.editor t))
let count = Controller.highlight_parse_count
let snapshot t = snd (Controller.highlights t)

let current t =
  let key, snapshot = Controller.highlights t in
  assert (Snapshot.matches snapshot key);
  assert (Snapshot.Key.revision key = Editor.revision (Controller.editor t));
  let language = Snapshot.Key.language key in
  if Language.equal language Plain then (
    assert (Option.is_none (Controller.highlight_status t));
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges snapshot) ~expect:[])
  else (
    let provider = Provider.create ~language in
    let expected = Provider.highlight provider ~key ~source:(source t) in
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges snapshot)
      ~expect:(Snapshot.ranges expected.snapshot);
    assert (Option.equal Provider.Status.equal (Controller.highlight_status t) (Some expected.status));
    Provider.close provider)
;;

let with_dir f =
  let dir = Core_unix.mkdtemp "/tmp/opencode/ches-highlight-test.XXXXXX" in
  Exn.protect ~f:(fun () -> f dir) ~finally:(fun () ->
    Array.iter (Stdlib.Sys.readdir dir) ~f:(fun file -> Core_unix.unlink (dir ^/ file));
    Core_unix.rmdir dir)
;;

let%test_unit "case-sensitive detection, initial highlights and per-document identities" =
  List.iter
    [ None, Language.Plain; Some "f", Plain; Some "f.txt", Plain
    ; Some "f.ML", Plain; Some "f.Mli", Plain; Some "f.ml.bak", Plain
    ; Some "f.ml", Ocaml; Some "f.mli", Ocaml_interface
    ] ~f:(fun (path, language) ->
      assert (Language.equal (Language.of_path path) language);
      let t = create ?path (if Language.equal language Ocaml_interface then "val f : int -> int\n" else "let f x = x\n") in
      assert (count t = if Language.equal language Plain then 0 else 1);
      current t;
      Controller.close t);
  let first = create ~path:"same.ml" "let x = 1" in
  let second = create ~path:"same.ml" "let x = 1" in
  assert (not (Snapshot.Key.equal (fst (Controller.highlights first)) (fst (Controller.highlights second))));
  Controller.close first;
  Controller.close second
;;

let%test_unit "ordinary edits, undo and redo parse once per final changed revision" =
  let t = create ~path:"f.ml" "let x = \"é\"\n" in
  let original_snapshot = snapshot t in
  let original = Snapshot.ranges original_snapshot in
  let t = List.fold (Key_notation.keys "i <Esc>xui!<Esc>u<C-r>ijx<Esc>u") ~init:t ~f:(fun t event ->
    let revision = Editor.revision (Controller.editor t) in
    let before = count t in
    let previous = snapshot t in
    let t = input t event in
    assert (count t = before + if Editor.revision (Controller.editor t) = revision then 0 else 1);
    if Editor.revision (Controller.editor t) = revision then assert (phys_equal previous (snapshot t));
    current t;
    t)
  in
  (* Original snapshots never become mutable parser objects or shifted ranges. *)
  assert (not (List.is_empty original));
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges original_snapshot) ~expect:original;
  Controller.close t
;;

let%test_unit "literal multiline paste, block edits and block paste get fresh whole-source ranges" =
  let t = create ~path:"f.ml" "let a = 1\nlet b = 2\n" in
  let t = run t "i" in
  let before = count t in
  let t = input t (Ches_input.Keymap.Input.Paste "(* outer\n (* inner *) *)\n") in
  assert (count t = before + 1);
  current t;
  let t = run t "<Esc>gg3j0<C-v>jI <Esc>" in
  current t;
  let t = run t "gg<C-v>jlyp" in
  current t;
  let t = run t "u<C-r>" in
  current t;
  assert (Controller.For_testing.highlight_incremental_count t = count t - 1);
  Controller.close t
;;

let%test_unit "load/create/save/reload preserve bytes and cache freshness" =
  with_dir (fun dir ->
    let path = dir ^/ "f.ml" in
    let original = "let f x = \"é\" (* nested (* comment *) *)\n" in
    Out_channel.write_all path ~data:original;
    let t = Controller.open_file ~cell_width:Cell_width.f path |> Or_error.ok_exn in
    assert (count t = 1);
    current t;
    let before = count t in
    let cached = snapshot t in
    let t = run t " w" in
    assert (count t = before && phys_equal cached (snapshot t));
    [%test_result: string] (In_channel.read_all path) ~expect:original;
    let revision = Editor.revision (Controller.editor t) in
    let t = run t ":e!<CR>" in
    assert (count t = before + 1);
    assert (Controller.For_testing.highlight_incremental_count t = 0);
    assert (Editor.revision (Controller.editor t) = revision + 1);
    assert (not (phys_equal cached (snapshot t)));
    current t;
    Out_channel.write_all path ~data:"let disk = 42\n";
    let t = run t ":e!<CR>" in
    current t;
    [%test_result: string] (source t) ~expect:"let disk = 42\n";
    assert (not (Editor.is_dirty (Controller.editor t)));
    Core_unix.unlink path;
    let before = count t in
    let cached = snapshot t in
    let t = run t ":e!<CR>" in
    assert (count t = before && phys_equal cached (snapshot t));
    assert (match Editor.message (Controller.editor t) with Some (Error _) -> true | _ -> false);
    Controller.close t;
    let path = dir ^/ "new.mli" in
    let t = Controller.open_file ~cell_width:Cell_width.f path |> Or_error.ok_exn in
    assert (count t = 1 && not (Editor.is_dirty (Controller.editor t)));
    let t = run t "ival f : int -> int<CR><Esc>" in
    current t;
    let before = count t in
    let saved = source t in
    let t = run t " w" in
    assert (count t = before && not (Editor.is_dirty (Controller.editor t)));
    [%test_result: string] (In_channel.read_all path) ~expect:saved;
    Controller.close t)
;;

let%test_unit "language association changes invalidate equal-revision caches" =
  let t = create ~path:"f.ml" "let f x = x\n" in
  let revision = Editor.revision (Controller.editor t) in
  let old_key, old_snapshot = Controller.highlights t in
  let t = Controller.For_testing.with_highlight_language t Ocaml_interface in
  assert (count t = 2);
  assert (not (Snapshot.Key.equal old_key (fst (Controller.highlights t))));
  assert (Snapshot.matches old_snapshot old_key);
  current t;
  let t = Controller.For_testing.with_highlight_language t Plain in
  assert (count t = 2);
  current t;
  let t = run t "i <Esc>" in
  assert (count t = 2);
  current t;
  let t = Controller.For_testing.with_highlight_language t Ocaml in
  assert (count t = 3 && Editor.revision (Controller.editor t) > revision);
  current t;
  Controller.close t
;;

let%test_unit "provider failure caches current empty highlights, never overwrites feedback, and retries on change" =
  with_dir (fun dir ->
    let path = dir ^/ "missing" ^/ "f.ml" in
    let t = create ~path "let x = 1\n" in
    let old_key, old_snapshot = Controller.highlights t in
    Controller.For_testing.fail_next_highlight t;
    let t = run t "i <Esc>" in
    let key, failed = Controller.highlights t in
    assert (not (Snapshot.Key.equal key old_key));
    assert (Snapshot.matches failed key && Snapshot.matches old_snapshot old_key);
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges failed) ~expect:[];
    assert (match Controller.highlight_status t with Some (Plain (Parsing _)) -> true | _ -> false);
    let before = count t in
    let t = run t " w" in
    let feedback = Editor.message (Controller.editor t) in
    assert (match feedback with Some (Error _) -> true | _ -> false);
    let t = run t "Z" in
    assert (count t = before && phys_equal failed (snapshot t));
    assert (Option.equal Editor.Message.equal (Editor.message (Controller.editor t)) feedback);
    let t = run t "i <Esc>" in
    assert (count t = before + 1);
    current t;
    Controller.close t)
;;

let%test_unit "acceptance: malformed mixed-width sources preserve save bytes, undo and dirty state" =
  with_dir (fun dir ->
    List.iter [ "mixed.ml"; "mixed.mli"; "mixed.txt" ] ~f:(fun name ->
      let path = dir ^/ name in
      (* Deliberately no final LF; display escapes must never leak into saved text. *)
      let original = "(*\té á 界 \001\194\133\226\128\174*)\nlet x = \"unterminated" in
      let inserted = "(* outer\n (* inner *) *)\n" in
      Out_channel.write_all path ~data:original;
      let t = Controller.open_file ~cell_width:Cell_width.f path |> Or_error.ok_exn in
      let initial_revision = Editor.revision (Controller.editor t) in
      let initial_parses = count t in
      assert (not (Editor.is_dirty (Controller.editor t)));
      current t;
      let t = run t "i" |> fun t -> input t (Ches_input.Keymap.Input.Paste inserted)
              |> fun t -> run t "<Esc>" in
      let edited = inserted ^ original in
      [%test_result: string] (source t) ~expect:edited;
      assert (Editor.is_dirty (Controller.editor t));
      current t;
      let t = run t "u" in
      [%test_result: string] (source t) ~expect:original;
      assert (not (Editor.is_dirty (Controller.editor t)));
      current t;
      let t = run t "<C-r>" in
      [%test_result: string] (source t) ~expect:edited;
      assert (Editor.is_dirty (Controller.editor t));
      current t;
      assert (Editor.revision (Controller.editor t) = initial_revision + 3);
      let before_save = count t in
      assert (before_save = initial_parses + if String.is_suffix name ~suffix:".txt" then 0 else 3);
      let t = run t " w" in
      [%test_result: string] (In_channel.read_all path) ~expect:edited;
      assert (count t = before_save && not (Editor.is_dirty (Controller.editor t)));
      let t = run t "u" in
      [%test_result: string] (source t) ~expect:original;
      assert (Editor.is_dirty (Controller.editor t));
      let t = run t "<C-r>" in
      assert (not (Editor.is_dirty (Controller.editor t)));
      current t;
      Controller.close t))
;;

let%test_unit "acceptance: provider fallback does not block a successful save or undo" =
  with_dir (fun dir ->
    let path = dir ^/ "fallback.ml" in
    let original = "let x = \"é界\"\n" in
    Out_channel.write_all path ~data:original;
    let t = Controller.open_file ~cell_width:Cell_width.f path |> Or_error.ok_exn in
    Controller.For_testing.fail_next_highlight t;
    let t = run t "i <Esc>" in
    assert (match Controller.highlight_status t with Some (Plain (Parsing _)) -> true | _ -> false);
    let failed = snapshot t in
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges failed) ~expect:[];
    let before = count t in
    let t = run t " w" in
    [%test_result: string] (In_channel.read_all path) ~expect:(" " ^ original);
    assert (not (Editor.is_dirty (Controller.editor t)));
    assert (count t = before && phys_equal failed (snapshot t));
    assert (match Editor.message (Controller.editor t) with Some (Info _) -> true | _ -> false);
    let t = run t "u" in
    [%test_result: string] (source t) ~expect:original;
    assert (Editor.is_dirty (Controller.editor t));
    current t;
    let t = run t "<C-r>" in
    assert (not (Editor.is_dirty (Controller.editor t)));
    current t;
    Controller.close t)
;;
