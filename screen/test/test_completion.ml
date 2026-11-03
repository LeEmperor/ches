open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers
module M = Ches_completion.Model

let text t = Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller t)))
let editor t = Controller.editor (Ui_state.controller t)
let press t s = run t (keys s)
let labels t = List.map (Ui_state.completion_candidates t) ~f:(fun c -> c.M.Candidate.label)
let has_menu t = not (List.is_empty (labels t))
let describe t =
  print_s [%sexp (text t : string), (labels t : string list), (Editor.mode (editor t) : Mode.t)]
;;

let%expect_test "automatic buffer menu, original-slot cycling, wrap, Enter and one undo" =
  let initial = "\nalpha alpine" in
  let t = press (ui initial) "ia" in
  assert (has_menu t);
  let t = press t "l" in
  describe t;
  show ~width:32 ~height:6 t;
  let t = press t "<Tab>" in
  describe t;
  let t = press t "<Tab>" in
  describe t;
  let t = press t "<Tab>" in
  describe t;
  let t = run t [ Key Ches_input.Key.Shift_tab ] in
  describe t;
  let t = press t "<CR>" in
  describe t;
  assert (Mode.equal (Editor.mode (editor t)) Insert);
  assert (String.equal (text (press t "<Esc>u")) initial);
  [%expect {|
    ( "al\
     \nalpha alpine" (alpha alpine) Insert)
    ╭─ f.txt ──────────────────────╮|
    │  al                          │|
    │  al> alpha   [buffer]        │|
    │      alpine  [buffer]        │|
    ╰──────────────────────────────╯|
     INSERT  f.txt [+]          1:3 |
    cursor: 5,1 Bar
    ( "alpha\
     \nalpha alpine" (alpha alpine) Insert)
    ( "alpine\
     \nalpha alpine" (alpha alpine) Insert)
    ( "alpha\
     \nalpha alpine" (alpha alpine) Insert)
    ( "alpine\
     \nalpha alpine" (alpha alpine) Insert)
    ( "alpine\
     \nalpha alpine" () Insert)
    |}]
;;

let%expect_test "first Shift-Tab installs; Escape accepts and ordinary typing starts fresh" =
  let t = press (ui "\nalpha alpine") "ial" in
  let t = run t [ Key Ches_input.Key.Shift_tab ] in
  assert (String.equal (text t) "alpha\nalpha alpine");
  let escaped = press t "<Esc>" in
  assert (String.equal (text escaped) (text t));
  assert (Mode.equal (Editor.mode (editor escaped)) Normal);
  assert (not (has_menu escaped));
  let typed = press t "x" in
  assert (String.equal (text typed) "alphax\nalpha alpine");
  assert (not (has_menu typed));
  (* No choices retains normal soft-tab and newline behavior. *)
  assert (String.equal (text (press (ui "") "iz<Tab><CR>")) "z \n");
  [%expect {| |}]
;;

let%expect_test "Enter installs an untouched selection without newline; editing refreshes suggestions" =
  let initial = "\nalpha alpine" in
  let t = press (ui initial) "ial<CR>" in
  assert (String.equal (text t) "alpha\nalpha alpine");
  assert (Mode.equal (Editor.mode (editor t)) Insert && not (has_menu t));
  assert (String.equal (text (press t "<Esc>u")) initial);
  let t = press (ui initial) "ialx<C-h>" in
  assert (String.equal (text t) "al\nalpha alpine" && has_menu t);
  [%expect {| |}]
;;

let%expect_test "palette toggles automatic suggestions and independent ghost rendering" =
  let t = ui "\nalpha alpine" in
  assert (Ui_state.completion_enabled t);
  assert (not (Ui_state.completion_ghost_enabled t));
  let t = press t " cccompletion.toggle<CR>ial" in
  assert (not (Ui_state.completion_enabled t));
  assert (not (has_menu t));
  let t = press t "<Esc>u cccompletion.toggle<CR> cccompletion.ghost<CR>ial" in
  assert (Ui_state.completion_enabled t);
  assert (Ui_state.completion_ghost_enabled t);
  assert (has_menu t);
  let before = text t, Editor.revision (editor t) in
  show ~width:32 ~height:6 t;
  assert ([%equal: string * int] before (text t, Editor.revision (editor t)));
  [%expect {|
    ╭─ f.txt ──────────────────────╮|
    │  alpha                       │|
    │  al> alpha   [buffer]        │|
    │      alpine  [buffer]        │|
    ╰──────────────────────────────╯|
     INSERT  f.txt [+]          1:3 |
    cursor: 5,1 Bar
    |}]
;;

let attached ?(path = "/completion-test.ml") initial =
  Ui_state.create ~tiles_visible:false ~source_attached:true
    (Controller.create (Editor.create ~path ~cell_width:Cell_map.width
      (Text_buffer.of_string initial |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
       |> Result.ok_or_failwith)))
;;

let request t =
  let t, requests = Ui_state.take_source_requests t in
  t, List.find_map_exn requests ~f:(function
    | Ches_error.Source_request.Complete request -> Some request | _ -> None)
;;

let candidate (request : M.Request.t) ?(additional = []) label : M.Candidate.t =
  { id = label; source = Lsp "test"; label; detail = Some "server"; filter_text = label
  ; sort_text = label
  ; primary = { start = request.fallback_start; stop = request.fallback_stop; text = label }
  ; additional; cursor = String.length label; snippet = None }
;;

let reply t (request : M.Request.t) candidates =
  run t [ Source (Completion { token = request.token; source = "test"; candidates; incomplete = false }) ]
;;

let finish_words (r : Ui_state.word_index_request) =
  let builder = M.Buffer_words.Builder.create ?before:r.before r.text in
  let rec loop () = match M.Buffer_words.Builder.step builder ~budget:16384 with
    | None -> loop () | Some words -> words in
  loop ()
;;

let pump_words t =
  match snd (Ui_state.take_word_index_request t) with
  | None -> t
  | Some r -> Ui_state.receive_word_index t r (finish_words r)
;;

let%expect_test "cold large words are deferred, providers immediate, eventual no-server menu and stale guards" =
  let large = "\nalpha alpine\n" ^ String.concat (List.init 20000 ~f:(fun _ -> "padding\n")) in
  let snippets = press (ui ~path:"module.sv" large) "iaff" in
  assert (Option.is_some (snd (Ui_state.take_word_index_request snippets)));
  assert (List.exists (Ui_state.completion_candidates snippets) ~f:(fun c ->
    M.Candidate.equal_source c.source Snippet));
  let t, bytes = M.Buffer_words.For_testing.measure (fun () -> press (ui large) "ial") in
  assert (bytes = 0 && not (has_menu t));
  let _, pending = Ui_state.take_word_index_request t in
  let pending = Option.value_exn pending in
  let words = finish_words pending in
  let ready = Ui_state.receive_word_index t pending words in
  assert (List.mem (labels ready) "alpha" ~equal:String.equal);
  let newer = press t "p" in
  assert (not (has_menu (Ui_state.receive_word_index newer pending words)));
  let dismissed = press t "<Esc>" in
  assert (not (has_menu (Ui_state.receive_word_index dismissed pending words)));
  let closed, did_close = Ui_state.close_current dismissed ~width:80 ~height:24 ~force:true in
  assert did_close;
  assert (phys_equal closed (Ui_state.receive_word_index closed pending words));
  let server, req = request (press (attached large) "ial") in
  let _, pending = Ui_state.take_word_index_request server in
  let pending = Option.value_exn pending in
  let server = reply server req [candidate req "algebra"] in
  assert (List.equal String.equal (labels server) ["algebra"]);
  let installed = press server "<Tab>" in
  let frozen = Ui_state.receive_word_index installed pending (finish_words pending) in
  assert (List.equal String.equal (labels frozen) ["algebra"]);
  print_endline "deferred words, immediate LSP, eventual words and guards passed";
  [%expect {| deferred words, immediate LSP, eventual words and guards passed |}]
;;

let%expect_test "word delivery preserves source selection and warm typing does bounded local work" =
  let large = "\nalpha alpine\n" ^ String.make 1000000 ' ' in
  let t, req = request (press (attached large) "ial") in
  let pending = snd (Ui_state.take_word_index_request t) |> Option.value_exn in
  let t = reply t req [candidate req "alpine"] in
  let t = Ui_state.receive_word_index t pending (finish_words pending) in
  assert (List.equal String.equal (labels t) ["alpine"; "alpha"]);
  assert (Option.is_none (snd (Ui_state.take_word_index_request t)));
  let installed = press t "<Tab>" in
  assert (String.is_prefix (text installed) ~prefix:"alpine\n");
  let t, visited = M.Buffer_words.For_testing.measure (fun () -> press t "p") in
  assert (visited < 256);
  assert (List.mem (labels t) "alpha" ~equal:String.equal);
  assert (Option.is_none (snd (Ui_state.take_word_index_request t)));
  [%expect {| |}]
;;

let%expect_test "late base delivery cannot replace a newer cached snapshot" =
  let t = press (ui ("\nalpha alpine\n" ^ String.make 100000 ' ')) "ial" in
  let old = snd (Ui_state.take_word_index_request t) |> Option.value_exn in
  let t = press t "p" in
  let fresh = snd (Ui_state.take_word_index_request t) |> Option.value_exn in
  let t = Ui_state.receive_word_index t fresh (finish_words fresh) in
  let t = Ui_state.receive_word_index t old (finish_words old) in
  let t, visited = M.Buffer_words.For_testing.measure (fun () -> press t "<C-n>") in
  assert (visited = 0);
  assert (List.mem (labels t) "alpha" ~equal:String.equal);
  [%expect {| |}]
;;

let%expect_test "closing a buffer prunes the completed index without a host round trip" =
  let weak = Stdlib.Weak.create 1 in
  let build_and_close () =
    let t = press (ui ("\nalpha alpine\n" ^ String.make 100000 ' ')) "ial" in
    let pending = snd (Ui_state.take_word_index_request t) |> Option.value_exn in
    let words = finish_words pending in
    Stdlib.Weak.set weak 0 (Some words);
    let t = Ui_state.receive_word_index t pending words |> fun t -> press t "<Esc>" in
    let closed, did_close = Ui_state.close_current t ~width:80 ~height:24 ~force:true in
    assert did_close;
    closed in
  let closed = build_and_close () in
  Stdlib.Gc.full_major ();
  assert (not (Stdlib.Weak.check weak 0));
  assert (Option.is_none (snd (Ui_state.take_word_index_request closed)));
  [%expect {| |}]
;;

let%expect_test "LSP Insert replies are immediate; stale replies ignored; installed order frozen" =
  let t, old = request (press (attached "") "ial") in
  let t = reply t old [ candidate old "alpha" ] in
  assert (has_menu t);
  let t = press t "p" in
  let t, fresh = request t in
  assert (fresh.token.request > old.token.request);
  let t = reply t old [ candidate old "alien" ] in
  assert (not (has_menu t));
  let t = reply t fresh [ candidate fresh "alphabet"; candidate fresh "alpine" ] in
  let t = press t "<Tab>" in
  let before = labels t in
  let t = reply t fresh [ candidate fresh "alps" ] in
  assert ([%equal: string list] before (labels t));
  let t = press t "<Tab><CR>" in
  describe t;
  let t = reply t fresh [ candidate fresh "alps" ] in
  assert (not (has_menu t));
  assert (String.equal (text (press t "<Esc>u")) "");
  [%expect {| (alpine () Insert) |}]
;;

let%expect_test "additional edits are deferred, only final choice applies, cursor and undo stay atomic" =
  let initial = "\n" in
  let t, req = request (press (attached initial) "ial") in
  let t = reply t req
    [ candidate req ~additional:[ { start = 3; stop = 3; text = "first import\n" } ] "alpha"
    ; candidate req ~additional:[ { start = 3; stop = 3; text = "chosen import\n" } ] "alpine" ] in
  let t = press t "<Tab><Tab>" in
  assert (String.equal (text t) "alpine\n");
  let t = press t "!" in
  assert (String.equal (text t) "alpine!\nchosen import\n");
  assert (Editor.cursor (editor t) = 7);
  assert (String.equal (text (press t "<Esc>u")) initial);
  [%expect {| |}]
;;

let%expect_test "paste, block insert, jk and terminal-toggle prefixes keep ownership" =
  let t = press (ui "\nalpha alpine") "ial<Tab>jk" in
  assert (Mode.equal (Editor.mode (editor t)) Normal);
  assert (String.equal (text t) "alpha\nalpha alpine");
  let t = run (press (ui "\nalpha alpine") "i") (paste "al") in
  assert (not (has_menu t));
  let t = run (press (ui "\nalpha alpine") "ial<Tab>") (paste "jk<Tab>") in
  assert (String.equal (text t) "alphajk\t\nalpha alpine");
  assert (not (has_menu t));
  let t = press (ui "alpha\nalpine") "<C-v>jIal" in
  assert (not (List.is_empty (Editor.block_insert_points (editor t))));
  assert (not (has_menu t));
  let t = press (ui "\nalpha alpine") "ial<Tab> /" in
  assert (Ui_state.terminal_visible t);
  assert (String.equal (text t) "alpha\nalpha alpine");
  assert (not (has_menu t));
  [%expect {| |}]
;;

let%expect_test "menu stays bounded on tiny panes and above a bottom-line cursor" =
  let t = press (ui "alpha alpine\n") "Gial" in
  List.iter [ 1, 1; 4, 2; 10, 4; 32, 6 ] ~f:(fun (width, height) ->
    let frame = Frame.render t ~width ~height in
    assert (List.length frame.rows = height);
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
  let above = Frame.render t ~width:32 ~height:3 in
  let top = List.hd_exn above.rows |> List.map ~f:(fun s -> s.Span.text) |> String.concat in
  assert (String.is_substring top ~substring:"> alpha  [buffer]");
  assert ((Option.value_exn above.cursor).y = 1);
  show ~width:32 ~height:4 t;
  [%expect {|
      alpha alpine                  |
      al                            |
        > alpha  [buffer]           |
     INSERT  f.txt [+]          2:3 |
    cursor: 4,1 Bar
    |}]
;;

let%expect_test "source dispatch flushes the snapshot first, cancels superseded work, and triggers punctuation" =
  let completion_requests requests = List.filter requests ~f:(function
    | Ches_error.Source_request.Query _ | Cancel_query _ -> false
    | _ -> true) in
  let t = press (attached "") "ia" in
  let t, requests = Ui_state.take_source_requests t in
  let req = match completion_requests requests with
    | [ Document_opened opened; Document_changed changed; Complete req ] ->
      assert (String.equal opened.resource req.token.resource);
      assert (opened.generation = req.token.generation);
      assert (changed.revision = req.token.revision && String.equal changed.text "a");
      req
    | _ -> failwith "Completion must follow its captured document snapshot" in
  let t = press t "p" in
  let t, requests = Ui_state.take_source_requests t in
  assert (match completion_requests requests with
    | [ Document_changed changed; Cancel_completion old; Complete fresh ] ->
      changed.revision = fresh.token.revision && M.Token.equal old req.token
    | _ -> false);
  let t = press t "." in
  let _, dot = request t in
  assert (M.Request.equal_trigger dot.trigger (Character "."));
  assert (dot.cursor = dot.fallback_start);
  [%expect {| |}]
;;

let%expect_test "buffer switch and reopen invalidate old tokens even at matching revisions" =
  let t, req = request (press (attached "") "ial") in
  let original = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t = reply t req [ candidate req "alpha" ] |> fun t -> press t "<Tab>" in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_other_completion__.ml"
    |> Or_error.ok_exn in
  let t = reply t req [ candidate req "alien" ] in
  assert (String.equal (text t) "" && not (has_menu t));
  let t = Ui_state.activate_buffer t ~width:40 ~height:8 original |> Or_error.ok_exn in
  assert (String.equal (text t) "alpha" && not (has_menu t));
  let t = reply t req [ candidate req "alien" ] in
  assert (not (has_menu t));
  let t, closed = Ui_state.close_current t ~width:40 ~height:8 ~force:true in
  assert closed;
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 req.token.resource |> Or_error.ok_exn in
  let t, fresh = request (press t "ial") in
  assert (fresh.token.generation <> req.token.generation);
  let t = reply t { fresh with token = { fresh.token with generation = req.token.generation } }
    [ candidate fresh "alien" ] in
  assert (not (has_menu t));
  let t = reply t fresh [ candidate fresh "alpha" ] in
  assert (has_menu t);
  [%expect {| |}]
;;

let%expect_test "finalization precedes Enter, Escape, movement, paste, toggle and buffer change" =
  let make () =
    let t, req = request (press (attached "\n") "ial") in
    let t = reply t req [ candidate req
      ~additional:[ { start = 3; stop = 3; text = "import\n" } ] "alpha" ] in
    press t "<Tab>" in
  List.iter [ "<CR>"; "<Esc>"; "<C-t>"; " /" ] ~f:(fun key ->
    let t = press (make ()) key in
    assert (String.is_substring (text t) ~substring:"import\n");
    assert (not (has_menu t)));
  let t = make () in
  let t = run t (paste "!") in
  assert (String.equal (text t) "alpha!\nimport\n");
  let t = make () in
  let id = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_completion_finalize__.ml"
    |> Or_error.ok_exn in
  let t = Ui_state.activate_buffer t ~width:40 ~height:8 id |> Or_error.ok_exn in
  assert (String.equal (text t) "alpha\nimport\n");
  (* View scrolling owns Insert-mode movement; finalization must happen first. *)
  let t = press (make ()) "<C-e>" in
  assert (String.is_substring (text t) ~substring:"import\n");
  [%expect {| |}]
;;

let%expect_test "Unicode prefixes use characters, completion cycles and undo preserve UTF-8" =
  let initial = "\néclair école" in
  let t = run (press (ui initial) "i") [ Key (Ches_input.Key.Char (Uchar.of_scalar_exn 0xe9)) ] in
  assert (has_menu t);
  let t = press t "c" in
  assert (has_menu t);
  let t = press t "<Tab><Tab><CR>" in
  assert (String.equal (text t) "école\néclair école");
  assert (String.equal (text (press t "<Esc>u")) initial);
  [%expect {| |}]
;;

let%expect_test "a hostile server label cannot break frame width or add rows" =
  let t, req = request (press (attached "") "ial") in
  let c = { (candidate req "alpha") with label = "wide 界\t\027\nlabel" } in
  let t = reply t req [ c ] in
  let frame = Frame.render t ~width:22 ~height:5 in
  assert (List.length frame.rows = 5);
  List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = 22));
  let cursor = Option.value_exn frame.cursor in
  assert (Frame.Cursor.equal_shape cursor.shape Bar);
  [%expect {| |}]
;;

let%expect_test "additional edits before the primary relocate the insertion cursor before typing" =
  let t, req = request (press (attached "\n") "Gial") in
  let t = reply t req [ candidate req
    ~additional:[ { start = 0; stop = 0; text = "import\n" } ] "alpha" ] in
  let t = press t "<Tab>" in
  assert (String.equal (text t) "\nalpha");
  let t = press t "!" in
  assert (String.equal (text t) "import\n\nalpha!");
  assert (Editor.cursor (editor t) = String.length (text t));
  assert (String.equal (text (press t "<Esc>u")) "\n");
  [%expect {| |}]
;;

let%expect_test "buffer and LSP contributions merge; rejected edits never reach the editor" =
  let t, req = request (press (attached "\nalpha") "ial") in
  let invalid = { (candidate req "alien") with
    primary = { start = 0; stop = 99999; text = "bad" } } in
  let t = reply t req [ candidate req "alpine"; invalid ] in
  assert ([%equal: string list] (labels t) [ "alpine"; "alpha" ]);
  let t = press t "<Tab><CR>" in
  (* The pre-existing buffer selection survives the asynchronous merge. *)
  assert (String.equal (text t) "alpha\nalpha");
  assert (not (has_menu t));
  [%expect {| |}]
;;

let%expect_test "different primary ranges finalize both-sided edits, synchronize, and undo/redo as one insertion" =
  let initial = "header\nalz\nfooter" in
  let t, req = request (press (attached initial) "jlliX<C-h>") in
  assert (String.equal (text t) initial);
  let short = { (candidate req "a-short") with filter_text = "alpha" } in
  let full = { (candidate req "b-full") with
    filter_text = "alphabet"
    ; primary = { start = req.fallback_start; stop = req.fallback_stop + 1; text = "alphabet" }
    ; cursor = 8
    ; additional = [ { start = 0; stop = 6; text = "import\nheader" }
                   ; { start = String.length initial; stop = String.length initial; text = "\nend" } ] } in
  let t = reply t req [ short; full ] in
  let t = press t "<Tab><Tab>" in
  assert (String.equal (text t) "header\nalphabet\nfooter");
  let t, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function
    | Document_changed changed -> String.equal changed.text (text t)
      && changed.revision = Editor.revision (editor t)
    | _ -> false));
  let t = press t "<CR>!" in
  let final = "import\nheader\nalphabet!\nfooter\nend" in
  assert (String.equal (text t) final && not (has_menu t));
  let t, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function
    | Document_changed changed -> String.equal changed.text final
      && changed.revision = Editor.revision (editor t)
    | _ -> false));
  let t = press t "<Esc>u" in
  assert (String.equal (text t) initial);
  let t = press t "<C-r>" in
  assert (String.equal (text t) final);
  [%expect {| |}]
;;

let%expect_test "Ctrl-n manually invokes with auto off, one character and empty prefix" =
  let t = press (ui "\nalpha alpine") " cccompletion.toggle<CR>i" in
  assert (not (Ui_state.completion_enabled t));
  let t = press t "<C-n>" in
  assert (String.equal (text t) "\nalpha alpine");
  assert ([%equal: string list] (labels t) [ "alpha"; "alpine" ]);
  let t = press (ui "\nalpha alpine") " cccompletion.toggle<CR>ia<C-n>" in
  assert (has_menu t);
  let t = press t "<Tab><Tab><CR>!" in
  assert (String.equal (text t) "alpine!\nalpha alpine");
  assert (not (has_menu t));
  (* Normal Ctrl-n retains its keymap behavior and does not invoke completion. *)
  assert (not (has_menu (press (ui "alpha alpine") "<C-n>")));
  (* This LSP-only empty-prefix fixture should not also offer bundled OCaml templates. *)
  let t, req = request (press (attached ~path:"/completion-test.txt" "")
      " cccompletion.toggle<CR>i<C-n>") in
  assert (req.cursor = 0 && req.fallback_start = 0);
  let t = reply t req [ candidate req "alpha" ] |> fun t -> press t "<CR>" in
  assert (String.equal (text t) "alpha");
  [%expect {| |}]
;;

let%expect_test "manual Ctrl-n at an empty slot offers buffer words without LSP and undoes atomically" =
  let initial = "\nzebra alpha Beta éclair" in
  let t = press (ui initial) "i" in
  assert (not (has_menu t));
  let t = press t "<C-n>" in
  assert (String.equal (text t) initial);
  assert ([%equal: string list] (labels t) [ "Beta"; "alpha"; "zebra"; "éclair" ]);
  let t, requests = Ui_state.take_source_requests t in
  assert (not (List.exists requests ~f:(function Complete _ -> true | _ -> false)));
  let t = press t "<Tab>" in
  assert (String.equal (text t) "Beta\nzebra alpha Beta éclair");
  let t = press t "<Tab><CR>" in
  assert (String.equal (text t) "alpha\nzebra alpha Beta éclair");
  assert (Mode.equal (Editor.mode (editor t)) Insert && not (has_menu t));
  let t = press t "<Esc>u" in
  assert (String.equal (text t) initial);
  let t = press t "<C-r>" in
  assert (String.equal (text t) "alpha\nzebra alpha Beta éclair");
  [%expect {| |}]
;;

let%expect_test "manual completion leaves terminal Ctrl-n and block insert ownership intact" =
  let module Terminal = Ches_terminal.Model in
  let t = run ~width:80 ~height:24 (ui "alpha alpine") (keys " /") in
  let t, _ = Ui_state.take_terminal_requests t in
  let key = { Terminal.code = Char (Uchar.of_char 'n')
            ; modifiers = { Terminal.no_modifiers with ctrl = true } } in
  let t = run ~width:80 ~height:24 t [ Terminal_key key ] in
  let _, requests = Ui_state.take_terminal_requests t in
  assert (List.equal Terminal.equal_request requests [ Terminal.Key key ]);
  assert (not (has_menu t) && String.equal (text t) "alpha alpine");
  let t = press (ui "alpha\nalpine") "<C-v>jI<C-n>" in
  assert (not (has_menu t));
  assert (not (List.is_empty (Editor.block_insert_points (editor t))));
  [%expect {| |}]
;;

let frame_text t ~width ~height =
  let frame = Frame.render t ~width ~height in
  List.map frame.rows ~f:(fun row -> List.map row ~f:(fun s -> s.Span.text) |> String.concat)
  |> String.concat ~sep:"\n"
;;

let%expect_test "menu identifies providers and safely renders signature metadata" =
  let t, req = request (press (attached "\nalpha") "ial") in
  let t = reply t req [ { (candidate req "alpine") with detail = Some "(x: int) -> string" } ] in
  let rendered = frame_text t ~width:80 ~height:8 in
  assert (String.is_substring rendered ~substring:"alpine  [LSP]  (x: int) -> string");
  assert (String.is_substring rendered ~substring:"alpha   [buffer]");
  (* Equal source columns for wide, multibyte, and combining labels. The
     selection marker occupies its own two cells regardless of label width. *)
  let unicode = reply t req
    [ { (candidate req "alpine") with label = "界"; detail = None }
    ; { (candidate req "alps") with label = "é"; detail = None }
    ; { (candidate req "altar") with label = "é"; detail = None } ] in
  let rendered = frame_text unicode ~width:80 ~height:8 in
  assert (String.is_substring rendered ~substring:"  界     [LSP]");
  assert (String.is_substring rendered ~substring:"  é      [LSP]");
  assert (String.is_substring rendered ~substring:"  é      [LSP]");
  let t = reply t req [ { (candidate req "alpine") with
    detail = Some ("界\t\027\n" ^ String.make 10000 'x') } ] in
  let t = press t "<Tab><Tab>" in
  assert (String.equal (Option.value_exn (Ui_state.completion_selected t)).label "alpine");
  List.iter [ 4; 18; 80 ] ~f:(fun width ->
    let frame = Frame.render t ~width ~height:6 in
    assert (List.length frame.rows = 6);
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width));
    if width >= 18 then (
      let selected = List.concat frame.rows
         |> List.filter ~f:(fun span -> match span.Span.style with
           | Completion { selected = true; _ } -> true | _ -> false) in
      assert (not (List.is_empty selected));
      assert (String.is_suffix (List.last_exn selected).text ~suffix:" ")));
  [%expect {| |}]
;;

let%expect_test "whole-buffer index updates and survives buffer switches without leaking words" =
  let initial = "\n" ^ String.make 70000 ' ' ^ "\nzephyr zeta" in
  let t = press (ui initial) "ize" |> pump_words in
  assert (List.mem (labels t) "zephyr" ~equal:String.equal);
  let t, scanned = M.Buffer_words.For_testing.measure (fun () -> press t "p<C-h>") in
  assert (scanned <= 2 * 16384);
  let t = pump_words t in
  let original = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t = press t "<CR>!<Esc>" in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_completion_cache_other__.ml"
    |> Or_error.ok_exn in
  let t = press t "ize" in
  assert (not (has_menu t));
  let t, scanned = M.Buffer_words.For_testing.measure (fun () ->
    let t = Ui_state.activate_buffer t ~width:40 ~height:8 original |> Or_error.ok_exn in
    press t "0ize") in
  assert (scanned <= 2 * 16384);
  let t = pump_words t in
  assert (has_menu t);
  let t = press t "<Esc>" in
  let t, closed = Ui_state.close_current t ~width:40 ~height:8 ~force:true in
  assert closed;
  let t = press t "<Esc>0i<C-n>" in
  assert (not (List.mem (labels t) "zephyr" ~equal:String.equal));
  [%expect {| |}]
;;

let metadata t (req : M.Request.t) items =
  run t [ Source (Completion_metadata { token = req.token; source = "test"; items }) ]
;;

let info ?revision ?additional ?(resolvable = true) candidate_id : Ches_error.Completion_info.t =
  { candidate_id; kind = Some 3; documentation = Some "Function documentation\nsecond line"
  ; detail = Some "(value: int) -> string"; resolvable; additional; revision }
;;

let resolve_request t candidate_id =
  let t, requests = Ui_state.take_source_requests t in
  let revision = List.find_map_exn requests ~f:(function
    | Ches_error.Source_request.Resolve_completion request when String.equal request.candidate_id candidate_id ->
      Some request.revision
    | _ -> None) in
  t, revision
;;

let resolvable () =
  let t, req = request (press (attached "\n") "ial") in
  let t = reply t req [ candidate req "alpha"; candidate req "alpine" ] in
  let t = metadata t req [ info "alpha"; info "alpine" ] in
  t, req
;;

let completion_spans t ~width =
  (Frame.render t ~width ~height:12).rows
  |> List.map ~f:(List.filter ~f:(fun span -> match span.Span.style with
    | Completion _ -> true | _ -> false))
  |> List.filter ~f:(fun row -> not (List.is_empty row))
;;

let part_text rows ~selected part =
  List.concat rows |> List.filter ~f:(fun span ->
    Style.equal span.Span.style (Style.completion ~selected part))
  |> List.map ~f:(fun span -> span.Span.text) |> String.concat
;;

let%test_unit "completion parts retain prefix during cycling and separate source, detail and docs" =
  let t, _ = resolvable () in
  List.iter [t; press t "<Tab>"; press t "<Tab><Tab>"] ~f:(fun t ->
    let rows = completion_spans t ~width:80 in
    assert (String.equal (Ui_state.completion_prefix t) "al");
    assert (String.equal (part_text rows ~selected:true Match) ">al");
    assert (String.equal (part_text rows ~selected:false Match) "al");
    assert (String.equal (part_text rows ~selected:true Source) "[LSP]");
    assert (String.equal (part_text rows ~selected:true Detail) "(value: int) -> string");
    assert (String.equal (part_text rows ~selected:false Documentation)
      "Function documentationsecond line");
    List.iter rows ~f:(fun row ->
      assert (Span.total_width row = Span.total_width (List.hd_exn rows));
      let last = List.last_exn row in
      assert (String.is_suffix last.text ~suffix:" ");
      match last.style with
      | Completion { part = Padding; selected } ->
        List.iter row ~f:(fun span -> match span.Span.style with
          | Completion c -> assert (Bool.equal selected c.selected)
          | _ -> assert false)
      | _ -> assert false))
;;

let%test_unit "buffer, LSP and local snippet providers use the source part on selected rows" =
  let lsp, _ = resolvable () in
  List.iter [press (ui "\nalpha alpine") "ial", "[buffer]";
             lsp, "[LSP]";
             press (ui ~path:"module.sv" "") "iaff", "[snippet]"]
    ~f:(fun (t, source) ->
      let rows = completion_spans t ~width:80 in
      assert (String.equal (part_text rows ~selected:true Source) source);
      assert (String.is_prefix (part_text rows ~selected:true Match) ~prefix:">"))
;;

let%test_unit "filterText alone never highlights a mismatching label, including escaped controls" =
  let t, req = request (press (attached "") "ial") in
  List.iter ["different"; "a\027label"; "界 label"] ~f:(fun label ->
    let c = { (candidate req "alpha") with label } in
    let t = reply t req [c] in
    let rows = completion_spans t ~width:80 in
    assert (String.equal (part_text rows ~selected:true Match) ">");
    assert (String.is_empty (part_text rows ~selected:false Match)))
;;

let%test_unit "Unicode prefix spans retain whole combining cells and clip wide glyphs safely" =
  List.iter ["é", "éclair"; "e", "éclair"; "界", "界面"] ~f:(fun (prefix, label) ->
    let t = press (attached "") "i" in
    (* Paste leaves a clean Unicode slot; manual completion captures its prefix. *)
    let t, req = request (run t (paste prefix) |> fun t -> press t "<C-n>") in
    let t = reply t req [candidate req label] in
    let rows = completion_spans t ~width:80 in
    let expected = if String.equal prefix "e" then ">é" else ">" ^ prefix in
    assert (String.equal (part_text rows ~selected:true Match) expected);
    List.iter [4; 5; 7; 12; 18] ~f:(fun width ->
      let frame = Frame.render t ~width ~height:8 in
      List.iter frame.rows ~f:(fun row ->
        assert (Span.total_width row = width);
        List.iter row ~f:(fun span ->
          assert (Result.is_ok (Text_buffer.of_string span.Span.text))))))
;;

let%test_unit "matching labels with escaped suffixes preserve cell widths and selected clipping styles" =
  let t, req = request (press (attached "") "ial") in
  List.iter ["al\027́pha"; "al\t́pha"; "al界́pha"] ~f:(fun label ->
    let c = { (candidate req label) with detail = Some "界́\027\tvalue" } in
    let t = reply t req [c] in
    let rows = completion_spans t ~width:80 in
    assert (String.equal (part_text rows ~selected:true Match) ">al");
    let rendered = part_text rows ~selected:true Label in
    if String.is_substring label ~substring:"\027" then (
      assert (String.is_substring rendered ~substring:"^[pha");
      assert (not (String.is_substring rendered ~substring:"́")));
    (* Exercise clipping in the marker, label, inter-column padding, provider,
       detail and the final padding cell, including partial wide glyphs. *)
    List.iter (List.range 3 61) ~f:(fun width ->
      let rows = completion_spans t ~width in
      List.iter rows ~f:(fun row ->
        List.iter row ~f:(fun span ->
          assert (span.Span.width = Cell_map.total_width (Cell_map.glyphs span.text));
          match span.style with
          | Completion { selected = true; _ } -> ()
          | _ -> assert false);
        let last = List.last_exn row in
        assert (Style.equal last.style (Style.completion ~selected:true Padding));
        assert (String.is_suffix last.text ~suffix:" "))))
;;

let%expect_test "metadata is immediate, lazy resolve follows selection, and resolved imports wait for acceptance" =
  let t, req = resolvable () in
  let rendered = frame_text t ~width:80 ~height:10 in
  assert (String.is_substring rendered ~substring:"Function documentation");
  assert (String.is_substring rendered ~substring:"(value: int) -> string");
  List.iter [ 4; 16; 80 ] ~f:(fun width ->
    let frame = Frame.render t ~width ~height:5 in
    assert (List.length frame.rows = 5);
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
  let t, before = resolve_request t "alpha" in
  assert (before = Editor.revision (editor t));
  let t = press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  assert (revision = Editor.revision (editor t) && revision > before);
  (* A resolve captured before primary insertion is stale. *)
  let extras = [ { Text_edit.start = 3; stop = 3; text = "import\n" } ] in
  let t = metadata t req [ info ~revision:before ~additional:extras "alpha" ] in
  assert (String.equal (text t) "alpha\n");
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "alpha\n");
  let t = press t "<CR>" in
  assert (String.equal (text t) "alpha\nimport\n" && not (has_menu t));
  assert (String.equal (text (press t "<Esc>u")) "\n");
  let t, req = resolvable () in
  let t = press t "<Tab><Tab>" in
  let t, revision = resolve_request t "alpine" in
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "alpine\n");
  let t = metadata t req [ info ~revision ~additional:extras "alpine" ] in
  let t = press t "<CR>" in
  assert (String.equal (text t) "alpine\nimport\n");
  [%expect {| |}]
;;

let%expect_test "known additional edits finalize immediately even while resolve is pending" =
  let t, req = request (press (attached "\n") "ial") in
  let extras = [ { Text_edit.start = 3; stop = 3; text = "known import\n" } ] in
  let t = reply t req [ candidate req ~additional:extras "alpha" ] in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<CR>" in
  assert (String.equal (text t) "alpha\nknown import\n");
  let before = text t in
  let t = metadata t req [ info ~revision:(Editor.revision (editor t))
    ~additional:[ { Text_edit.start = 3; stop = 3; text = "late\n" } ] "alpha" ] in
  assert (String.equal before (text t));
  [%expect {| |}]
;;

let%expect_test "nonblocking acceptance applies a resolve only to its exact unchanged accepted snapshot" =
  let accept () =
    let t, req = request (press (attached "\n") "Gial") in
    let t = reply t req [ candidate req "alpha" ] in
    let t = metadata t req [ info "alpha" ] in
    let t = press t "<CR>" in
    let t, revision = resolve_request t "alpha" in
    assert (not (has_menu t) && String.equal (text t) "\nalpha");
    t, req, revision in
  let extras = [ { Text_edit.start = 0; stop = 0; text = "import\n" } ] in
  let t, req, revision = accept () in
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "import\n\nalpha");
  assert (Editor.cursor (editor t) = 13);
  assert (String.equal (text (press t "!<Esc>u")) "\n");
  List.iter [ "!"; "<Esc>"; "<C-h>"; "<C-n>" ] ~f:(fun key ->
    let t, req, revision = accept () in
    let t = press t key in
    let before = text t in
    let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
    assert (String.equal (text t) before));
  let t, req, revision = accept () in
  let original = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_late_resolve__.ml" |> Or_error.ok_exn in
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "");
  let t = Ui_state.activate_buffer t ~width:40 ~height:8 original |> Or_error.ok_exn in
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "\nalpha");
  [%expect {| |}]
;;

module Snippet = Ches_completion.Snippet

let snippet_candidate ?(additional = []) req syntax =
  let snippet = Snippet.parse syntax |> Or_error.ok_exn in
  let expanded = Snippet.text snippet in
  { (candidate req ~additional "alpha") with
    primary = { start = req.fallback_start; stop = req.fallback_stop; text = expanded }
  ; cursor = String.length expanded; snippet = Some snippet }
;;

let snippet_menu ?(initial = "") ?(prefix = "ial") ?(additional = []) syntax =
  let t, req = request (press (attached initial) prefix) in
  reply t req [ snippet_candidate ~additional req syntax ], req
;;

let active t = not (List.is_empty (Ui_state.snippet_ranges t))

let%expect_test "demo palette command inserts at the Normal cursor and uses live linked fields with one undo" =
  let initial = "préTAIL" in
  let t = press (ui initial) "lll ccInsert demo snippet<CR>" in
  assert (Mode.equal (Editor.mode (editor t)) Insert && active t && not (has_menu t));
  assert (String.equal (text t) "préassign signal = value;\n// mirror: signal\nTAIL");
  assert (Editor.cursor (editor t) = String.length "préassign signal");
  assert ([%equal: Snippet.range list] (Ui_state.snippet_ranges t)
    [{ start = 11; stop = 17 }; { start = 38; stop = 44 }]);
  let t = press t "bus" in
  assert (String.equal (text t) "préassign bus = value;\n// mirror: bus\nTAIL");
  let t = press t "<Tab>" in
  assert (Editor.cursor (editor t) = String.length "préassign bus = value");
  let t = run t [ Key Ches_input.Key.Shift_tab ] in
  assert (Editor.cursor (editor t) = String.length "préassign bus");
  let t = press t "<Tab>42<Tab>" in
  assert (not (active t));
  assert (Editor.cursor (editor t) = String.length "préassign bus = 42;\n// mirror: bus\n");
  let final = text t in
  let t = press t "<Esc>u" in
  assert (String.equal (text t) initial && not (active t));
  let t = press t "<C-r>" in
  assert (String.equal (text t) final && not (active t));
  [%expect {| |}]
;;

let%expect_test "demo command also works on an empty file and does not request a server" =
  List.iter [ui ""; attached ""] ~f:(fun t ->
    let t = press t " ccdevelopment.insert-demo-snippet<CR>" in
    assert (active t && Editor.cursor (editor t) = 13);
    let _, requests = Ui_state.take_source_requests t in
    assert (not (List.exists requests ~f:(function
      | Ches_error.Source_request.Complete _ | Resolve_completion _ -> true | _ -> false)));
    assert (String.equal (text (press t "<Esc>u")) ""));
  [%expect {| |}]
;;

let%expect_test "demo is absent over directory and read-only views; block Insert cannot open its palette" =
  let directory = Ui_state.create ~tiles_visible:false
      (Controller.create ~kind:Directory (Editor.create ~path:"/tmp"
        ~cell_width:Cell_map.width Text_buffer.empty)) in
  let report = Ui_state.create ~report:Report_tile.demo ~tiles_visible:true
      (Controller.create (Editor.create ~path:"/demo.txt" ~cell_width:Cell_map.width Text_buffer.empty))
      |> fun t -> press t " vD" in
  List.iter [directory; report] ~f:(fun t ->
    let before = text t, Editor.revision (editor t) in
    let t = press t " ccInsert demo snippet" in
    let palette = Ui_state.palette t |> Option.value_exn |> Palette_tile.palette in
    assert (List.is_empty (Ches_palette.Palette.results palette));
    let t = press t "<CR><Esc>" in
    assert ([%equal: string * int] before (text t, Editor.revision (editor t)));
    assert (not (active t)));
  let t = press (ui "abc\ndef") "<C-v>jI" in
  assert (not (List.is_empty (Editor.block_insert_points (editor t))));
  let opened = press t " cc" in
  assert (Option.is_none (Ui_state.palette opened));
  assert (not (String.is_substring (text opened) ~substring:"assign") && not (active opened));
  let t = press (ui "") " cccompletion.toggle<CR> ccInsert demo snippet<CR>" in
  assert (not (Ui_state.completion_enabled t) && active t);
  [%expect {| |}]
;;

let%expect_test "snippet Enter does not activate when resolved edits cannot finalize" =
  let t, req = snippet_menu "${1:default}/$1" in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  let t = metadata t req [ info ~revision
    ~additional:[ { Text_edit.start = 0; stop = 99999; text = "import\n" } ] "alpha" ] in
  let t = press t "<CR>" in
  assert (String.equal (text t) "default/default" && not (has_menu t));
  assert (not (active t));
  assert (String.equal (text (press t "X")) "default/defaultX");
  assert (String.equal (text (press t "<Esc>u")) "");
  (* A resolved empty edit list is a successful no-op, and must still activate. *)
  let t, req = snippet_menu "${1:default}/$1" in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  let t = metadata t req [ info ~revision ~additional:[] "alpha" ] in
  assert (active (press t "<CR>"));
  [%expect {| |}]
;;

let%expect_test "snippet Backspace respects soft-tab stops and field boundaries" =
  let make syntax = fst (snippet_menu syntax) |> fun t -> press t "<CR>" in
  let t = press (make "${1:default}/$1") "X  <BS>" in
  assert (String.equal (text t) "X /X " && active t);
  let t = press t " <BS>" in
  assert (String.equal (text t) "X /X " && active t);
  let t = press (make "(${1:default})/$1") "X  <BS>" in
  assert (String.equal (text t) "(X)/X" && active t);
  let undone = press t "<Esc>u" in
  assert (String.equal (text undone) "" && not (active undone));
  let redone = press undone "<C-r>" in
  assert (String.equal (text redone) "(X)/X" && not (active redone));
  (* A soft-tab deletion extending outside the field cancels before normal handling. *)
  let t = press (make " ${1:default}/$1") " <BS>" in
  assert (String.equal (text t) "/ " && not (active t));
  [%expect {| |}]
;;

let%expect_test "snippet Enter handoff selects defaults; cycling and ordinary acceptance never activate" =
  let make () = fst (snippet_menu "fn(${1:default}, $1)$0") in
  let t = press (make ()) "<Tab>" in
  assert (String.equal (text t) "fn(default, default)" && not (active t));
  let t = press t "<Tab>" in
  assert (String.equal (text t) "fn(default, default)" && not (active t));
  let t = press t "<CR>" in
  assert (active t && not (has_menu t));
  assert (Editor.cursor (editor t) = 10);
  assert ([%equal: Snippet.range list] (Ui_state.snippet_ranges t)
    [ { start = 3; stop = 10 }; { start = 12; stop = 19 } ]);
  let typed = press (press (make ()) "<Tab>") "!" in
  assert (String.equal (text typed) "fn(default, default)!" && not (active typed));
  let direct = press (make ()) "<CR>" in
  assert (active direct && String.equal (text direct) "fn(default, default)");
  [%expect {| |}]
;;

let%expect_test "snippet Unicode replacement and subsequent edits mirror atomically in one insert undo" =
  let t, _ = snippet_menu "(${1:default}:$1:${2:next})$0" in
  let t = press t "<CR>" in
  let t = run t [ Key (Ches_input.Key.Char (Uchar.of_scalar_exn 0x754c)) ] in
  assert (String.equal (text t) "(界:界:next)");
  assert (Editor.cursor (editor t) = 4 && active t && not (has_menu t));
  let t = run t [ Key (Ches_input.Key.Char (Uchar.of_scalar_exn 0xe9)) ] in
  assert (String.equal (text t) "(界é:界é:next)");
  let t = press t "<BS>" in
  assert (String.equal (text t) "(界:界:next)" && active t);
  let t = press t "<Tab>X" in
  assert (String.equal (text t) "(界:界:X)");
  let final = text t in
  let t = press t "<Esc>" in
  assert (not (active t) && Mode.equal (Editor.mode (editor t)) Normal);
  let t = press t "u" in
  assert (String.equal (text t) "");
  assert (String.equal (text (press t "<C-r>")) final);
  [%expect {| |}]
;;

let%test_unit "snippet movement clears defaults, respects Unicode, endpoints and outside cancellation" =
  let make syntax = fst (snippet_menu syntax) |> fun t -> press t "<CR>" in
  let t = make "(${1:界é})/$1" in
  let revision = Editor.revision (editor t) in
  let t = press t "<Left>" in
  assert (Editor.cursor (editor t) = 4 && active t);
  assert (Editor.revision (editor t) = revision);
  let t = press t "X" in
  assert (String.equal (text t) "(界Xé)/界Xé" && active t);
  let t = press t "<Right><Right>" in
  assert (not (active t) && Editor.cursor (editor t) = String.length "(界Xé)");
  let t = make "${1:界é}/$1" |> fun t -> press t "<Home>X" in
  assert (String.equal (text t) "X界é/X界é" && active t);
  let t = press t "<End>!" in
  assert (String.equal (text t) "X界é!/X界é!" && active t);
  let t = make "prefix ${1:界é}\nsuffix" |> fun t -> press t "<Home>" in
  assert (Editor.cursor (editor t) = 0 && not (active t));
  let t = make "${1:界é}\nsuffix" |> fun t -> press t "<End>X" in
  assert (String.equal (text t) "界éX\nsuffix" && active t)
;;

let%test_unit "choice cycling, custom mirrored edits, field keys and undo" =
  let t = fst (snippet_menu "${1|界,é,edge|}/$1/${2:next}$0") |> fun t -> press t "<CR>" in
  assert ([%equal: string list option] (Ui_state.snippet_choices t) (Some ["界"; "é"; "edge"]));
  let t = press t "<C-e>" in
  assert (String.equal (text t) "é/é/next" && active t);
  let t = press t "<C-y>" in
  assert (String.equal (text t) "界/界/next");
  let t = press t "<Tab><S-Tab>custom" in
  assert (String.equal (text t) "custom/custom/next" && active t);
  let t = press t "<C-e>" in
  assert (active t && not (String.is_substring (text t) ~substring:"custom"));
  let final = text t in
  let t = press t "<Esc>u" in
  assert (String.equal (text t) "" && not (active t));
  assert (String.equal (text (press t "<C-r>")) final)
;;

let%test_unit "Insert navigation without snippets uses current line and Unicode boundaries" =
  let t = press (ui "界é\nnext") "i<End><Left>X<Home>Y" in
  assert (String.equal (text t) "Y界Xé\nnext");
  assert (Mode.equal (Editor.mode (editor t)) Insert && not (active t))
;;

let%test_unit "movement inside snippet retains the insertion undo group" =
  let t = fst (snippet_menu "(${1:界é})/$1$0") |> fun t -> press t "<CR>" in
  let t = press t "X<Left>Y<Right>Z" in
  assert (String.equal (text t) "(YXZ)/YXZ" && active t);
  let final = text t in
  let t = press t "<Esc>u" in
  assert (String.equal (text t) "" && not (active t));
  let t = press t "<C-r>" in
  assert (String.equal (text t) final && not (active t))
;;

let%test_unit "ordinary Insert movement retains ordinary undo boundaries" =
  let t = press (ui "界é") "iX<Right>Y<Esc>u" in
  assert (String.equal (text t) "X界é" && not (active t));
  let t = press t "u" in
  assert (String.equal (text t) "界é");
  let t = press t "<C-r><C-r>" in
  assert (String.equal (text t) "X界Yé" && not (active t))
;;

let%test_unit "navigation replays held terminal shortcuts before moving and clears escape state" =
  let make () = fst (snippet_menu "(${1:default})/$1/${2:next}")
      |> fun t -> press t "<CR>" in
  let at ms = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms ms) in
  let timed t keys = run t (List.mapi keys ~f:(fun i key ->
    Ui_state.Input.Key_at { key; at = at (Float.of_int (i * 10)) })) in
  let t = timed (make ()) [Ches_input.Key.char '7'; Ches_input.Key.char ' '; Left] in
  assert (String.equal (text t) "(7 )/7 /next" && active t);
  assert (Editor.cursor (editor t) = 2 && not (Ui_state.toggle_key_pending t));
  let t = press t "X" in
  assert (String.equal (text t) "(7X )/7X /next" && active t);
  let t = timed (make ()) [Ches_input.Key.char ' '; Tab] in
  assert (String.equal (text t) "( )/ /next" && active t);
  assert (not (Ui_state.toggle_key_pending t));
  let t = press t "X" in
  assert (String.equal (text t) "( )/ /X");
  let t = press (make ()) "j<Left>k" in
  assert (String.equal (text t) "(kj)/kj/next" && active t);
  assert (Mode.equal (Editor.mode (editor t)) Insert)
;;

let%expect_test "snippet numbered navigation reselects defaults, Shift-Tab, and final cursor exits" =
  let t, _ = snippet_menu "${2:two}/${1:one}/$1$0!" in
  let t = press t "<CR>X<Tab>Y" in
  assert (String.equal (text t) "Y/X/X!");
  let t = run t [ Key Ches_input.Key.Shift_tab ] in
  let t = press t "Z" in
  assert (String.equal (text t) "Y/Z/Z!");
  let t = press t "<Tab><Tab>" in
  assert (not (active t) && Editor.cursor (editor t) = 5);
  let t = press t "?" in
  assert (String.equal (text t) "Y/Z/Z?!");
  let t, _ = snippet_menu "left$0right" in
  let t = press t "<CR>!" in
  assert (String.equal (text t) "left!right" && not (active t));
  [%expect {| |}]
;;

let%expect_test "snippet Delete and Backspace replace defaults and cancel before crossing field boundaries" =
  let make () = fst (snippet_menu "(${1:界é})/$1") |> fun t -> press t "<CR>" in
  List.iter [ "<Del>"; "<BS>"; "<C-h>" ] ~f:(fun key ->
    let t = press (make ()) key in
    assert (String.equal (text t) "()/" && active t));
  let t = press (make ()) "X<Del>" in
  assert (String.equal (text t) "(X/X" && not (active t));
  let t = press (make ()) "X<BS><BS>" in
  assert (String.equal (text t) ")/" && not (active t));
  let t = press (make ()) "<C-t>" in
  assert (not (active t));
  [%expect {| |}]
;;

let%expect_test "snippet terminal prefix timeout replays every held key through the field editor" =
  let t, _ = snippet_menu "${1:default}/$1" in
  let t = press t "<CR>" in
  let at ms = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms ms) in
  let t = run t [ Key_at { key = Ches_input.Key.char '7'; at = at 0. }
                ; Key_at { key = Ches_input.Key.char ' '; at = at 100. }
                ; Toggle_tick (at 300.) ] in
  assert (String.equal (text t) "7 /7 " && active t);
  let t = press t "x" in
  assert (String.equal (text t) "7 x/7 x" && active t);
  [%expect {| |}]
;;

let%expect_test "snippet safe cancellation for paste, newline, buffer change, control command and terminal toggle" =
  let make () = fst (snippet_menu "${1:default}/$1$0") |> fun t -> press t "<CR>" in
  let t = run (make ()) (paste "界<CR>jk") in
  assert (String.equal (text t) "default界\njk/default" && not (active t) && not (has_menu t));
  let t = press (make ()) "<CR>" in
  assert (String.equal (text t) "default\n/default" && not (active t));
  let t = press (make ()) "<C-n>" in
  assert (not (active t));
  let _, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function Complete _ -> true | _ -> false));
  let t = press (make ()) " /" in
  assert (Ui_state.terminal_visible t && not (active t));
  assert (String.equal (text t) "default/default");
  let t = make () in
  let original = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_snippet_other__.ml" |> Or_error.ok_exn in
  assert (not (active t));
  let t = Ui_state.activate_buffer t ~width:40 ~height:8 original |> Or_error.ok_exn in
  assert (String.equal (text t) "default/default" && not (active t));
  [%expect {| |}]
;;

let%expect_test "snippet jk escape mirrors its deletion and a failed terminal prefix loses no keys" =
  let make () = fst (snippet_menu "${1:default}/$1$0") |> fun t -> press t "<CR>" in
  let t = press (make ()) "jk" in
  assert (String.equal (text t) "/" && not (active t));
  assert (Mode.equal (Editor.mode (editor t)) Normal);
  let t = press (make ()) " 7x" in
  assert (String.equal (text t) " 7x/ 7x" && active t);
  let t = press (make ()) "j<Tab>k" in
  assert (String.equal (text t) "j/jk");
  assert (Mode.equal (Editor.mode (editor t)) Insert);
  [%expect {| |}]
;;

let%expect_test "snippet known imports relocate fields and late resolve cannot edit an active session" =
  let extras = [ { Text_edit.start = 0; stop = 0; text = "import\n" } ] in
  let t, req = snippet_menu ~initial:"\n" ~prefix:"Gial" ~additional:extras "${1:default}/$1$0" in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  let t = press t "<CR>" in
  assert (String.equal (text t) "import\n\ndefault/default" && active t);
  assert ((List.hd_exn (Ui_state.snippet_ranges t)).start = 8);
  let t = metadata t req [ info ~revision
    ~additional:[ { Text_edit.start = 0; stop = 0; text = "late\n" } ] "alpha" ] in
  let t = press t "X" in
  assert (String.equal (text t) "import\n\nX/X" && active t);
  assert (String.equal (text (press t "<Esc>u")) "\n");
  (* An unresolved snippet does not install the normal deferred-acceptance path. *)
  let t, req = snippet_menu "${1:default}/$1" in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  let t = press t "<CR>" in
  let t, requests = Ui_state.take_source_requests t in
  assert (List.exists requests ~f:(function Cancel_completion token -> M.Token.equal token req.token | _ -> false));
  let t = metadata t req [ info ~revision ~additional:extras "alpha" ] in
  assert (String.equal (text t) "default/default" && active t);
  [%expect {| |}]
;;

let%expect_test "resolved imports known before snippet Enter relocate the expansion" =
  let t, req = snippet_menu ~initial:"\n" ~prefix:"Gial" "${1:default}/$1" in
  let t = metadata t req [ info "alpha" ] |> fun t -> press t "<Tab>" in
  let t, revision = resolve_request t "alpha" in
  let t = metadata t req [ info ~revision
    ~additional:[ { Text_edit.start = 0; stop = 0; text = "import\n" } ] "alpha" ] in
  let t = press t "<CR>界" in
  assert (String.equal (text t) "import\n\n界/界" && active t);
  [%expect {| |}]
;;

let%test_unit "choice hint is clipped by cells, nonfocus, and follows active fields" =
  let t = fst (snippet_menu "${1|界,é,edge|}/$1/${2:next}") |> fun t -> press t "<CR>" in
  List.iter [4; 18; 40; 80] ~f:(fun width ->
    let frame = Frame.render t ~width ~height:8 in
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
  let render t = Frame.render t ~width:80 ~height:8 |> Frame.to_string in
  let frame = Frame.render t ~width:80 ~height:8 in
  assert (String.is_substring (render t) ~substring:"Ctrl-e/y: 界 | é | edge");
  assert (Option.exists frame.cursor ~f:(fun cursor -> Frame.Cursor.equal_shape cursor.shape Bar));
  assert (not (has_menu t));
  assert (not (String.is_substring (render (press t "<Tab>")) ~substring:"Ctrl-e/y"));
  assert (not (String.is_substring (render (press t "<C-n>")) ~substring:"Ctrl-e/y"))
;;

let%test_unit "choice hint bounds alternatives before span rendering" =
  let syntax = "${1|a,b,c,d,e,f,g,h,NINTH," ^ String.make 30000 ',' ^ "|}" in
  let t = fst (snippet_menu syntax) |> fun t -> press t "<CR>" in
  let frame = Frame.render t ~width:120 ~height:8 in
  assert (active t);
  let rendered = Frame.to_string frame in
  assert (String.is_substring rendered ~substring:"Ctrl-e/y: a | b | c | d | e | f | g | h");
  assert (not (String.is_substring rendered ~substring:"NINTH"));
  List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = 120))
;;

let%test_unit "choice interactions preserve timed escape, prefix replay and paste routes" =
  let make () = fst (snippet_menu "${1|界,é|}/$1") |> fun t -> press t "<CR>" in
  let at ms = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms ms) in
  let t = run (make ()) [ Key_at { key = Ches_input.Key.char 'j'; at = at 0. }
                       ; Key_at { key = Ctrl 'e'; at = at 10. }
                       ; Key_at { key = Ches_input.Key.char 'k'; at = at 20. } ] in
  assert (String.equal (text t) "k/k" && active t && Mode.equal (Editor.mode (editor t)) Insert);
  let t = run (make ()) [ Key_at { key = Ches_input.Key.char 'j'; at = at 0. }
                       ; Key_at { key = Ches_input.Key.char 'k'; at = at 10. } ] in
  assert (String.equal (text t) "/" && not (active t));
  let t = run (make ()) [ Key_at { key = Ches_input.Key.char ' '; at = at 0. }
                       ; Key_at { key = Ctrl 'e'; at = at 10. }
                       ; Toggle_tick (at 300.) ] in
  assert (String.equal (text t) "界/界" && active t);
  let t = run (make ()) (paste "jk") in
  assert (String.equal (text t) "界jk/界" && not (active t));
  let t = press (make ()) " /" in
  assert (Ui_state.terminal_visible t && not (active t))
;;

let%expect_test "snippet active-field rendering preserves Unicode cells, mirrors and empty fields" =
  let t, _ = snippet_menu "(${1:界é})/$1/${2}" in
  let t = press t "<CR>" in
  List.iter [ 4; 18; 80 ] ~f:(fun width ->
    let frame = Frame.render t ~width ~height:6 in
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width)));
  let selected t =
    let frame = Frame.render t ~width:40 ~height:6 in
    List.concat frame.rows |> List.filter ~f:(fun span -> match span.Span.style with
      | Document { overlay = Some Selection; _ } -> true | _ -> false)
    |> List.map ~f:(fun span -> span.Span.text) |> String.concat in
  assert (String.equal (selected t) "界é界é");
  let t = press t "<Tab>" in
  assert (String.equal (selected t) " ");
  let t = press t "<Esc>" in
  assert (String.equal (selected t) "");
  let t, _ = snippet_menu "($1) trailing text" in
  let t = press t "<CR>" in
  assert (String.equal (selected t) ")");
  [%expect {| |}]
;;
