open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Local_command = Ches_tile.Local_command

let width = 80
let height = 16

(* A test-only view, installed through [Ui_state.create ~views] alone: a counter whose
   [reset] command exists only while it is above zero. Nothing in [Ui_state] or
   [Frame] names it. *)
module Counter = struct
  let id = View_id.of_string "counter"

  type t = { count : int } [@@deriving sexp_of]

  type action =
    | Increment
    | Reset

  let key = Type_equal.Id.create ~name:"counter" sexp_of_t

  let commands t =
    Local_command.create "increment" ~keys:[ Key.char '+' ] "Add one"
    :: (if t.count > 0
        then [ Local_command.create "reset" ~keys:[ Key.char 'r' ] "Reset to zero" ]
        else [])
  ;;

  let interpret t (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ key ] when Key.equal key (Key.char '+') -> Action Increment
    | [ key ] when Key.equal key (Key.char 'r') && t.count > 0 -> Action Reset
    | _ -> Unbound
  ;;

  let adapter : (t, action) View_registry.Adapter.t =
    { spec = Ches_tile.Spec.read_only id ~title:"Counter"
    ; key
    ; fit = (fun t _ ~rows:_ ~width:_ -> t)
    ; leave = Fn.id
    ; text_view = (fun _ -> None)
    ; interpret
    ; escape = (fun _ -> None)
    ; hint = "Counter: + adds, r resets"
    ; perform =
        (fun t controller ~rows:_ ~width:_ action ->
          match action with
          | Increment -> { count = t.count + 1 }, View_registry.Outcome.create controller
          | Reset ->
            ( { count = 0 }
            , View_registry.Outcome.create controller ~notice:(`Show "Counter reset") ))
    ; commands
    ; render =
        (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
          { title = sprintf "Counter: %d" t.count
          ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
          ; body = [ Tile_text.row Status (String.make t.count '*') ~width ]
          })
    }
  ;;
end

let create () =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view Counter.id)
         ; leader_v 'X', View (Toggle_view Counter.id)
         ; leader_v 'y', View (Run_view_command { view = Counter.id; command = "reset" })
         ; leader_v 'u', View (Focus_view (View_id.of_string "unknown"))
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path:"a" "first\nsecond")) in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ View_registry.Entry.install ~placement:Band Counter.adapter { count = 0 } ]
    (Controller.create
       ~keymap_config:{ Keymap.Config.default with normal = bindings }
       editor)
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)
let count t = (Option.value_exn (View_registry.find (Ui_state.views t) Counter.key)).count

let message t =
  Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)
;;

let show t =
  printf "focused %s, count %d, notice %s\n" (focused t) (count t)
    (Option.value (Ui_state.capture_notice t) ~default:"(none)")
;;

let screen t = Frame.to_string (Frame.render t ~width ~height)

let help t =
  match Ui_state.help t with
  | None -> print_endline "no help"
  | Some help ->
    List.iter (Help_tile.commands help) ~f:(fun command ->
      printf "%-8s %s\n" (Local_command.keys_hum command) command.description)
;;

let palette_ids ?(limit = 3) t =
  let palette = Palette_tile.palette (Option.value_exn (Ui_state.palette t)) in
  List.iter (List.take (Ches_palette.Palette.results palette) limit) ~f:(fun result ->
    print_endline
      (Ches_palette.Catalog.Id.to_string (Ches_palette.Catalog.Entry.id result.item)))
;;

let%expect_test "an installed view is allocated, focused, routed, rendered and toggled generically" =
  let t = create () in
  let w = Ui_state.workspace t ~width ~height in
  print_s [%sexp (List.map w.minors ~f:(fun p -> p.id) : Workspace.Pane_id.t list)];
  [%expect {| ((Minor counter)) |}];
  let t = run t " vx++" in
  show t;
  [%expect {| focused counter, count 2, notice (none) |}];
  print_endline (List.nth_exn (String.split_lines (screen t)) 11);
  [%expect {| ╭─ Counter: 2 ─────────────────────────────────────────────────────────────────╮| |}];
  (* Unbound keys give the adapter's hint; the leader still reaches workspace commands. *)
  let t = run t "z" in
  show t;
  [%expect {| focused counter, count 2, notice Counter: + adds, r resets |}];
  (* Layout feedback names the view, from its spec's title. *)
  let t = run t "<Tab> vX" in
  printf "%s; %s; %b\n" (focused t) (message t) (Ui_state.view_visible t Counter.id);
  [%expect {| document; Counter hidden; false |}];
  (* Focusing shows it again, with its state kept; again returns. *)
  let t = run t " vx" in
  printf "%s; %s; %d\n" (focused t) (message t) (count t);
  [%expect {| counter; Counter focused; 2 |}];
  let t = run t " vx" in
  show t;
  [%expect {| focused document, count 2, notice (none) |}];
  let t = run t " vu" in
  printf "%s; %s\n" (focused t) (message t);
  [%expect {| document; View unknown unavailable |}]
;;

let%expect_test "? lists the focused view's local commands for its state; closing returns to it" =
  let t = run (create ()) " vx?" in
  show t;
  help t;
  [%expect
    {|
    focused help, count 0, notice (none)
    +        Add one
    |}];
  let t = run t "q+?" in
  show t;
  help t;
  [%expect
    {|
    focused help, count 1, notice (none)
    +        Add one
    r        Reset to zero
    |}];
  print_endline
    (String.concat ~sep:"\n" (List.take (List.drop (String.split_lines (screen t)) 5) 5));
  [%expect
    {|
    │                                                                              │|
    │                       ╭─ Counter keys ───────────────╮                       │|
    │                       │ +  Add one                   │                       │|
    │                       │ r  Reset to zero             │                       │|
    ╰───────────────────────╰─ 0 above, 0 below ───────────╯───────────────────────╯|
    |}];
  (* Keys are not the view's while help is open; Escape and Tab also return. *)
  let t = run t "+" in
  show t;
  [%expect {| focused help, count 1, notice Read-only help: j/k scroll; q, ? or Escape closes |}];
  let t = run t "<Esc>" in
  show t;
  let t = run t "?<Tab>" in
  show t;
  [%expect
    {|
    focused counter, count 1, notice (none)
    focused counter, count 1, notice (none)
    |}];
  (* Hiding the view under its help closes the help and returns to the document. *)
  let t = run t "? vX" in
  show t;
  help t;
  [%expect
    {|
    focused document, count 1, notice (none)
    no help
    |}]
;;

let%expect_test "the palette lists the focused view's commands first and runs them there" =
  let t = run (create ()) " vx+ cc" in
  palette_ids t;
  [%expect
    {|
    local.counter.increment
    local.counter.reset
    file.save
    |}];
  (* Local entries carry the view's title and their keys as shortcuts. *)
  print_endline (List.nth_exn (String.split_lines (screen t)) 3);
  [%expect {| ││ > Counter: Add one                                                       + ││| |}];
  let t = run t "<CR>" in
  show t;
  [%expect {| focused counter, count 2, notice (none) |}];
  (* A query can pick one; it runs exactly as its keys would. *)
  let t = run t " ccreset<CR>" in
  show t;
  [%expect {| focused counter, count 0, notice Counter reset |}];
  (* From help, the palette still targets the help's view. *)
  let t = run t "? cc" in
  palette_ids ~limit:1 t;
  [%expect {| local.counter.increment |}];
  let t = run t "<CR>" in
  show t;
  [%expect {| focused counter, count 1, notice (none) |}];
  (* Other commands, and closing, return to the document as before. *)
  let t = run t " cc<Esc>" in
  show t;
  [%expect {| focused document, count 1, notice (none) |}];
  let t = run t " cc" in
  palette_ids ~limit:1 t;
  [%expect {| file.save |}]
;;

let%expect_test "a local command by name is refused unless its view is focused and declares it" =
  let t = run (create ()) " vy" in
  printf "%s; %s\n" (focused t) (message t);
  [%expect {| document; Counter is not focused; nothing ran |}];
  (* [reset] is only declared above zero. *)
  let t = run t " vx vy" in
  show t;
  [%expect {| focused counter, count 0, notice Counter: reset unavailable here; nothing ran |}];
  let t = run t "+ vy" in
  show t;
  [%expect {| focused counter, count 0, notice Counter reset |}]
;;

let%expect_test "built-in views declare state-dependent local commands" =
  let t =
    Ui_state.create ~tiles_visible:false ~report:Report_tile.demo
      (Ui_state.controller (Helpers.ui ~path:"a" "first"))
  in
  let t = run t " vD?" in
  help t;
  [%expect
    {|
    e        Open details
    y y      Copy the selected item
    j        Select next item
    k        Select previous item
    g g      Select first item
    G        Select last item
    Ctrl-d   Select half a page down
    Ctrl-u   Select half a page up
    |}];
  let t = run t "<Esc>e?" in
  help t;
  [%expect
    {|
    e        Close details
    j        Move down a row
    k        Move up a row
    w        Move to the next word
    b        Move to the previous word
    g g      Move to the first row
    G        Move to the last row
    v        Start Visual selection
    V        Start linewise Visual selection
    y y      Copy the cursor's line
    |}];
  (* The palette over the report keeps its details open and runs a command there. *)
  let t = run t "<Esc> cc" in
  assert (Report_tile.details (Option.value_exn (Ui_state.report t)));
  palette_ids ~limit:2 t;
  [%expect
    {|
    local.demo-report.toggle-details
    local.demo-report.cursor-down
    |}];
  let t = run t "<CR>" in
  printf "%s %b\n" (focused t) (Report_tile.details (Option.value_exn (Ui_state.report t)));
  [%expect {| demo-report false |}];
  let t = run t "<Tab> vm vM?" in
  help t;
  [%expect
    {|
    e        Open details
    X        Clear the history (active problems stay)
    y y      Copy the selected item
    j        Select next item
    k        Select previous item
    g g      Select first item
    G        Select last item
    Ctrl-d   Select half a page down
    Ctrl-u   Select half a page up
    |}];
  let t = run t "<Esc><Tab> vo?" in
  print_endline (focused t);
  List.iter
    (List.take (Help_tile.commands (Option.value_exn (Ui_state.help t))) 4)
    ~f:(fun command -> print_endline command.name);
  [%expect
    {|
    help
    inspect
    acknowledge
    jump
    copy-item
    |}]
;;

let%expect_test "? keeps its meaning in the editor and in text-input floats" =
  let t = run (create ()) "?sec" in
  print_s
    [%sexp
      (Keymap.search_preview (Controller.keymap (Ui_state.controller t)) : string option)];
  [%expect {| (sec) |}];
  let t = run t "<Esc> cc?" in
  print_endline (focused t);
  print_endline (Ches_palette.Palette.query (Palette_tile.palette (Option.value_exn (Ui_state.palette t))));
  [%expect
    {|
    palette
    ?
    |}]
;;
