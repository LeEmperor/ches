open! Core
open Ches_input
open Ches_palette

let normal : Catalog.Context.t = { mode = Normal }

(* A binding table shaped like [Bindings.default]: its direct Editor and View
   targets, plus targets that are not complete actions. [Bindings] does not expose
   its table, so tests supply one. *)
let bindings =
  let leader = Key.char ' ' in
  let keys s = String.to_list s |> List.map ~f:Key.char in
  let editor s (command : Ches_core.Command.t) = keys s, Bindings.Target.Editor command in
  let view c (command : View_command.t) =
    [ leader; Key.char 'v'; Key.char c ], Bindings.Target.View command
  in
  [ keys "d", Bindings.Target.Delete_operator
  ; keys "/", Search_prompt { forward = true }
  ; keys "j", Move Down
  ; editor "u" Undo
  ; [ Ctrl 'r' ], Editor Redo
  ; editor " w" Save
  ; editor " q" Quit
  ; editor " Q" Force_quit
  ; view 'c' Toggle_centered
  ; view 'h' (Shift (-2))
  ; view 'l' (Shift 2)
  ; view 'H' (Shift (-10))
  ; view 'L' (Shift 10)
  ; view '-' (Adjust_width (-10))
  ; view '+' (Adjust_width 10)
  ; view '=' (Adjust_width 10)
  ; view 'n' Toggle_absolute_numbers
  ; view 'N' Toggle_relative_numbers
  ; view 's' Toggle_smear
  ; view 'r' Reset
  ]
;;

let%expect_test "the test binding table is valid" =
  ignore (Bindings.create bindings |> Or_error.ok_exn : Bindings.t)
;;

let shortcuts action =
  Shortcut.sequences bindings action
  |> List.map ~f:Shortcut.to_string_hum
  |> String.concat ~sep:", "
;;

let%expect_test "the default catalog, with shortcuts derived from bindings" =
  List.iter (Catalog.entries Catalog.default) ~f:(fun entry ->
    printf
      "%-30s %-38s %s\n"
      (Catalog.Id.to_string (Catalog.Entry.id entry))
      (Catalog.Entry.title entry)
      (shortcuts (Catalog.Entry.action entry)));
  [%expect
    {|
    file.save                      Save file                              Space w
    app.quit                       Quit                                   Space q
    app.quit-discarding-changes    Quit, discarding unsaved changes       Space Q
    edit.undo                      Undo                                   u
    edit.redo                      Redo                                   Ctrl-r
    view.toggle-absolute-numbers   Toggle absolute line numbers           Space v n
    view.toggle-relative-numbers   Toggle relative line numbers           Space v N
    view.toggle-centered           Toggle centered layout                 Space v c
    view.toggle-smear              Toggle animated smear cursor           Space v s
    view.reset-layout              Reset layout                           Space v r
    view.move-tile-left-2          Move document tile left by 2 columns   Space v h
    view.move-tile-right-2         Move document tile right by 2 columns  Space v l
    view.move-tile-left-10         Move document tile left by 10 columns  Space v H
    view.move-tile-right-10        Move document tile right by 10 columns Space v L
    view.narrow-tile-10            Narrow document tile by 10 columns     Space v -
    view.widen-tile-10             Widen document tile by 10 columns      Space v +, Space v =
    workspace.toggle-status        Toggle status tile
    workspace.status-left          Move status tile left
    workspace.status-right         Move status tile right
    workspace.status-above         Move status tile above
    workspace.status-below         Move status tile below
    workspace.shrink-status        Shrink status tile by 2
    workspace.grow-status          Grow status tile by 2
    workspace.toggle-zen           Toggle zen mode
    problems.toggle                Toggle problems tile
    problems.focus                 Focus problems
    problems.toggle-filter         Toggle problems filter (workspace / current document)
    problems.inspect               Inspect next problem
    history.toggle                 Toggle notification history
    history.focus                  Focus notification history
    report.toggle                  Toggle demo report
    report.focus                   Focus demo report
    source.restart                 Restart diagnostic source
    document.lines                 Search current document lines
    |}]
;;

let%expect_test "shortcuts ignore targets that are not complete actions" =
  print_endline (shortcuts (Editor (Delete_lines 1)));
  print_endline (shortcuts (Editor (Search { query = None; forward = true; count = 1; whole_word = false })));
  [%expect {| |}]
;;

(* The top few results for [query], with title matches marked. *)
let search ?(context = normal) ?(limit = 3) query =
  Catalog.search Catalog.default context ~query
  |> Fn.flip List.take limit
  |> List.iter ~f:(fun (result : Catalog.result) ->
    let title = Catalog.Entry.title result.item in
    let marked = Marked.mark title (Catalog.title_positions result) in
    printf "%-30s %s\n" (Catalog.Id.to_string (Catalog.Entry.id result.item)) marked)
;;

let%expect_test "the plan's example queries find the relative line-number toggle" =
  List.iter [ "rel num"; "rln"; "gutter relative" ] ~f:(fun query ->
    printf "%s:\n" query;
    search ~limit:1 query);
  [%expect
    {|
    rel num:
    view.toggle-relative-numbers   Toggle [rel]ative line [num]bers
    rln:
    view.toggle-relative-numbers   Toggle [r]elative [l]ine [n]umbers
    gutter relative:
    view.toggle-relative-numbers   Toggle [relative] line numbers
    |}]
;;

let%expect_test "keyword and ID matches" =
  (* A keyword-only match highlights nothing in the title. *)
  search "gutter";
  [%expect
    {|
    view.toggle-absolute-numbers   Toggle absolute line numbers
    view.toggle-relative-numbers   Toggle relative line numbers
    |}];
  (* [rnu] also matches the title loosely, but the exact keyword scores higher, so
     the title is not highlighted. *)
  search ~limit:1 "rnu";
  [%expect {| view.toggle-relative-numbers   Toggle relative line numbers |}];
  search ~limit:1 "write";
  [%expect {| file.save                      Save file |}];
  search ~limit:2 "smear";
  [%expect {| view.toggle-smear              Toggle animated [smear] cursor |}]
;;

let%expect_test "realistic queries" =
  search "save";
  [%expect {|
    file.save                      [Save] file
    app.quit-discarding-changes    Quit, discarding un[save]d changes
    workspace.status-above         Move [s]tatus tile [a]bo[ve]
    |}];
  search "quit";
  [%expect
    {|
    app.quit                       [Quit]
    app.quit-discarding-changes    [Quit], discarding unsaved changes
    |}];
  search "widen";
  [%expect {| view.widen-tile-10             [Widen] document tile by 10 columns |}];
  search "tile left";
  [%expect
    {|
    view.move-tile-left-2          Move document [tile] [left] by 2 columns
    view.move-tile-left-10         Move document [tile] [left] by 10 columns
    workspace.status-left          Move status [tile] [left]
    |}];
  search "zzzz";
  [%expect {| |}]
;;

let%expect_test "empty query lists available commands in catalog order" =
  search ~limit:4 "";
  [%expect
    {|
    file.save                      Save file
    app.quit                       Quit
    app.quit-discarding-changes    Quit, discarding unsaved changes
    edit.undo                      Undo
    |}]
;;

let%expect_test "unavailable commands are not listed" =
  search ~context:{ mode = Insert } "";
  search ~context:{ mode = Insert } "save";
  [%expect {| |}];
  let catalog =
    Catalog.create
      [ Catalog.Entry.create ~id:"a.normal" ~title:"Normal only" (Editor Undo)
      ; Catalog.Entry.create
          ~id:"a.anywhere"
          ~title:"Anywhere"
          ~available:(fun _ -> true)
          (Editor Redo)
      ]
    |> Or_error.ok_exn
  in
  Catalog.search catalog { mode = Insert } ~query:""
  |> List.iter ~f:(fun (result : Catalog.result) ->
    print_endline (Catalog.Entry.title result.item));
  [%expect {| Anywhere |}]
;;

let%expect_test "find by ID" =
  let show id =
    Catalog.find Catalog.default (Catalog.Id.of_string id)
    |> Option.map ~f:Catalog.Entry.title
    |> [%sexp_of: string option]
    |> print_s
  in
  show "edit.redo";
  show "edit.missing";
  [%expect
    {|
    (Redo)
    ()
    |}]
;;

let%expect_test "create rejects malformed and duplicate IDs and empty titles" =
  let entry id title = Catalog.Entry.create ~id ~title (Editor Undo) in
  Catalog.create
    [ entry "a.one" "One"
    ; entry "a.one" "One again"
    ; entry "Bad ID" "Bad"
    ; entry "" "Empty"
    ; entry "a.two" "  "
    ]
  |> [%sexp_of: _ Or_error.t]
  |> print_s;
  [%expect
    {|
    (Error
     ("Invalid command catalog"
      ("Malformed ID: \"Bad ID\"" "Malformed ID: \"\"" "Duplicate ID: a.one"
       "Empty title: a.two")))
    |}]
;;
