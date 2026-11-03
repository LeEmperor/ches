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

let attached initial =
  Ui_state.create ~tiles_visible:false ~source_attached:true
    (Controller.create (Editor.create ~path:"/completion-test.ml" ~cell_width:Cell_map.width
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
  let t = press (attached "") "ia" in
  let t, requests = Ui_state.take_source_requests t in
  let req = match requests with
    | [ Document_opened opened; Document_changed changed; Complete req ] ->
      assert (String.equal opened.resource req.token.resource);
      assert (opened.generation = req.token.generation);
      assert (changed.revision = req.token.revision && String.equal changed.text "a");
      req
    | _ -> failwith "Completion must follow its captured document snapshot" in
  let t = press t "p" in
  let t, requests = Ui_state.take_source_requests t in
  assert (match requests with
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
  let t, req = request (press (attached "") " cccompletion.toggle<CR>i<C-n>") in
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
        |> List.filter ~f:(fun span -> Style.equal span.Span.style (Mode Insert)) in
      assert (not (List.is_empty selected));
      assert (String.is_suffix (List.last_exn selected).text ~suffix:" ")));
  [%expect {| |}]
;;

let%expect_test "whole-buffer index updates and survives buffer switches without leaking words" =
  let initial = "\n" ^ String.make 70000 ' ' ^ "\nzephyr zeta" in
  let t = press (ui initial) "ize" in
  assert (List.mem (labels t) "zephyr" ~equal:String.equal);
  let t, scanned = M.Buffer_words.For_testing.measure (fun () -> press t "p<C-h>") in
  assert (scanned < 128);
  let original = Session.active_id (Ui_state.session t) |> Option.value_exn in
  let t = press t "<CR>!<Esc>" in
  let t, _ = Ui_state.open_file t ~width:40 ~height:8 "/__ches_completion_cache_other__.ml"
    |> Or_error.ok_exn in
  let t = press t "ize" in
  assert (not (has_menu t));
  let t, scanned = M.Buffer_words.For_testing.measure (fun () ->
    let t = Ui_state.activate_buffer t ~width:40 ~height:8 original |> Or_error.ok_exn in
    press t "0ize") in
  assert (scanned < 256);
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
