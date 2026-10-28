open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Ask = View_registry.Ask
module Popup = Ches_vcs.Popup

let width = 80
let height = 16

(* A test-only view that asks with a popup: a kiln. [c] asks the "Fire" popup
   (declining performs [Cancelled]), [C] the same popup with no cancel action. Its
   actions log what they were given; nothing in [Ui_state] names it. *)
module Kiln = struct
  let id = View_id.of_string "kiln"

  type t = { log : string list (** Newest first. *) } [@@deriving sexp_of]

  type action =
    | Ask of { cancel : bool }
    | Fire of string list
    | Bisque of string list
    | Cancelled

  let key = Type_equal.Id.create ~name:"kiln" sexp_of_t

  let popup =
    Popup.create ~title:"Fire"
      ~switches:
        [ { key = 'n'; flag = "--no-glaze"; description = "No glaze"; group = None }
        ; { key = 'h'; flag = "--hot"; description = "Fire hot"; group = Some "heat" }
        ; { key = 'l'; flag = "--low"; description = "Fire low"; group = Some "heat" }
        ]
      ~actions:
        [ { key = 'f'; description = "Fire"; run = (fun ~enabled -> Fire enabled) }
        ; { key = 'b'; description = "Bisque"; run = (fun ~enabled -> Bisque enabled) }
        ]
    |> Or_error.ok_exn
  ;;

  let interpret _ (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ Char c ] ->
      (match Uchar.to_char c with
       | Some 'c' -> Action (Ask { cancel = true })
       | Some 'C' -> Action (Ask { cancel = false })
       | _ -> Unbound)
    | _ -> Unbound
  ;;

  let perform t controller ~context:_ ~rows:_ ~width:_ action =
    let outcome ?notice ?ask () = View_registry.Outcome.create ?notice ?ask controller in
    let log line = { log = line :: t.log }, outcome ~notice:(`Show line) () in
    match action with
    | Ask { cancel } ->
      ( t
      , outcome
          ~ask:(Ask.Popup { popup; cancel = Option.some_if cancel Cancelled })
          () )
    | Fire flags -> log (String.concat ~sep:" " ("fire" :: flags))
    | Bisque flags -> log (String.concat ~sep:" " ("bisque" :: flags))
    | Cancelled -> log "cancelled"
  ;;

  let adapter : (t, action) View_registry.Adapter.t =
    { spec = Ches_tile.Spec.read_only id ~title:"Kiln"
    ; key
    ; fit = (fun t _ ~rows:_ ~width:_ -> t)
    ; leave = Fn.id
    ; text_view = (fun _ -> None)
    ; interpret
    ; escape = (fun _ -> None)
    ; hint = "Kiln: c fires"
    ; perform
    ; commands =
        (fun _ -> [ Ches_tile.Local_command.create "fire" ~keys:[ Key.char 'c' ] "Fire" ])
    ; signal = (fun _ _ -> None)
    ; text_area = (fun _ ~rows:_ ~width:_ -> None)
    ; label = (fun _ -> None)
    ; render =
        (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
          { title = "Kiln"
          ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
          ; body = [ Tile_text.row Status (String.concat ~sep:"; " (List.rev t.log)) ~width ]
          })
    }
  ;;
end

let create () =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view Kiln.id)
         ; leader_v 'X', View (Toggle_view Kiln.id)
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path:"a" "first\nsecond")) in
  Ui_state.create ~tiles_visible:false
    ~views:[ View_registry.Entry.install ~placement:Band Kiln.adapter { log = [] } ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run ?(width = width) ?(height = height) t keys =
  Helpers.run ~width ~height t (Helpers.keys keys)
;;

let log t =
  String.concat ~sep:"; "
    (List.rev (Option.value_exn (View_registry.find (Ui_state.views t) Kiln.key)).log)
;;

let show ?(width = width) ?(height = height) t =
  let float =
    match Ui_state.popup t with
    | None -> "no popup"
    | Some popup ->
      let state = Popup_tile.state popup in
      sprintf "popup [%s]%s" (String.concat ~sep:" " state.enabled)
        (if state.dash then " dash" else "")
  in
  printf "%s; focused %s; log [%s]; pending %b; notice %s\n" float
    (View_id.to_string (Ui_state.focused_view t ~width ~height))
    (log t)
    (Option.is_some (View_registry.asking (Ui_state.views t) Kiln.id))
    (Option.value (Ui_state.capture_notice t) ~default:"(none)")
;;

(* The float's rows as drawn (the popup's, or help's over it), and the cursor line. *)
let float_rows ?(width = width) ?(height = height) t =
  let layout =
    Option.first_some
      (Ui_state.help_layout t ~width ~height)
      (Ui_state.popup_layout t ~width ~height)
  in
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  (* Only the float's cells: the rows around it name the build sandbox. *)
  let cut line ~x ~width =
    let column = ref 0 in
    Array.fold (Cell_map.glyphs line) ~init:"" ~f:(fun text (glyph : Cell_map.Glyph.t) ->
      let at = !column in
      column := at + glyph.width;
      if at >= x && at < x + width then text ^ glyph.text else text)
  in
  Option.iter layout ~f:(fun (layout : Tile_shell.Layout.t) ->
    let outer = layout.outer in
    List.iter (List.take (List.drop lines outer.y) outer.height) ~f:(fun line ->
      print_endline (cut line ~x:outer.x ~width:outer.width)));
  print_endline (List.last_exn lines)
;;

let message t = Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)

let%expect_test "the popup opens over the view: title, switches, actions in columns" =
  let t = run (create ()) " vxc" in
  show t;
  float_rows t;
  [%expect
    {|
    popup []; focused popup; log []; pending true; notice (none)
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │   -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰──────────────────────────────╯
    cursor: none
    |}];
  (* Narrow: one action per row. Short: the rows that fit; help lists the rest. *)
  let t = Helpers.run ~width:24 ~height t [ Resize ] in
  float_rows ~width:24 t;
  let t = Helpers.run ~width ~height:7 t [ Resize ] in
  float_rows ~height:7 t;
  [%expect
    {|
    ╭─ Fire ─────────────╮
    │ Switches           │
    │   -n  No glaze (-> │
    │   -h  Fire hot (-> │
    │   -l  Fire low (-> │
    │ Actions            │
    │   f  Fire          │
    │   b  Bisque        │
    ╰────────────────────╯
    cursor: none
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │   -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    ╰──────────────────────────────╯
    cursor: none
    |}]
;;

let%expect_test "- then a switch key toggles it; a group keeps one; an action answers with them" =
  let t = run (create ()) " vxc-" in
  show t;
  float_rows t;
  [%expect {|
    popup [] dash; focused popup; log []; pending true; notice (none)
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │   -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰─ Pending: - ─────────────────╯
    cursor: none
    |}];
  let t = run t "n-h" in
  show t;
  float_rows t;
  [%expect {|
    popup [--no-glaze --hot]; focused popup; log []; pending true; notice (none)
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │ * -n  No glaze (--no-glaze)  │
    │ * -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰──────────────────────────────╯
    cursor: none
    |}];
  (* [-l] enables low and disables hot, its group's other; [-n] again disables it. *)
  let t = run t "-l-n" in
  show t;
  let t = run t "f" in
  show t;
  [%expect {|
    popup [--low]; focused popup; log []; pending true; notice (none)
    no popup; focused kiln; log [fire --low]; pending false; notice fire --low
    |}];
  (* Switches are not remembered: the next opening starts with none. *)
  let t = run t "c-hb" in
  show t;
  let t = run t "c" in
  show t;
  [%expect {|
    no popup; focused kiln; log [fire --low; bisque --hot]; pending false; notice bisque --hot
    popup []; focused popup; log [fire --low; bisque --hot]; pending true; notice (none)
    |}]
;;

let%expect_test "Escape clears a pending dash, then declines; q, Tab and Ctrl-c decline" =
  let t = run (create ()) " vxc-n-" in
  show t;
  let t = run t "<Esc>" in
  show t;
  let t = run t "<Esc>" in
  show t;
  [%expect {|
    popup [--no-glaze] dash; focused popup; log []; pending true; notice (none)
    popup [--no-glaze]; focused popup; log []; pending true; notice (none)
    no popup; focused kiln; log [cancelled]; pending false; notice cancelled
    |}];
  List.iter [ "q"; "<Tab>"; "<C-c>" ] ~f:(fun decline ->
    let t = run t ("c" ^ decline) in
    show t);
  [%expect {|
    no popup; focused kiln; log [cancelled; cancelled]; pending false; notice cancelled
    no popup; focused kiln; log [cancelled; cancelled]; pending false; notice cancelled
    no popup; focused kiln; log [cancelled; cancelled]; pending false; notice cancelled
    |}];
  (* Declining a popup that names no cancel action runs nothing. *)
  let t = run t "Cq" in
  show t;
  [%expect {| no popup; focused kiln; log [cancelled]; pending false; notice (none) |}]
;;

let%expect_test "an unbound key shows a hint in the footer and answers nothing" =
  let t = run (create ()) " vxcx" in
  show t;
  float_rows t;
  [%expect {|
    popup []; focused popup; log []; pending true; notice x is unbound; ? lists keys
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │   -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰─ x is unbound; ? lists keys ─╯
    cursor: none
    |}];
  let t = run t "-x" in
  show t;
  let t = run t "<CR>" in
  show t;
  [%expect {|
    popup []; focused popup; log []; pending true; notice -x is unbound; ? lists keys
    popup []; focused popup; log []; pending true; notice Press a listed key; - then a key toggles a switch; ? lists the keys, q closes
    |}];
  (* The next key clears the hint. *)
  let t = run t "-" in
  show t;
  [%expect {| popup [] dash; focused popup; log []; pending true; notice (none) |}]
;;

let%expect_test "? opens help over the popup; closing it returns to the popup as it was" =
  let t = run (create ()) " vxc-n?" in
  show t;
  float_rows t;
  print_endline
    (Option.value_map (Ui_state.help t) ~default:"no help" ~f:(fun help ->
       View_id.to_string (Help_tile.origin help)));
  [%expect {|
    popup [--no-glaze]; focused help; log []; pending true; notice (none)
    ╭─ Fire keys ──────────────────╮
    │ -n  No glaze (--no-glaze)    │
    │ -h  Fire hot (--hot)         │
    │ -l  Fire low (--low)         │
    │ f   Fire                     │
    │ b   Bisque                   │
    ╰─ 0 above, 0 below ───────────╯
    cursor: none
    popup
    |}];
  let t = run t "q" in
  show t;
  float_rows t;
  [%expect {|
    popup [--no-glaze]; focused popup; log []; pending true; notice (none)
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │ * -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰──────────────────────────────╯
    cursor: none
    |}];
  let t = run t "?<Esc>f" in
  show t;
  [%expect {| no popup; focused kiln; log [fire --no-glaze]; pending false; notice fire --no-glaze |}]
;;

let%expect_test "leader workspace keys work over the popup; paste is rejected" =
  (* [Space v ?] toggles hotkey hints; the popup stays, its footer shows them. *)
  let t = run (create ()) " vxc v?" in
  show t;
  float_rows t;
  [%expect {|
    popup []; focused popup; log []; pending true; notice (none)
    ╭─ Fire ───────────────────────╮
    │ Switches                     │
    │   -n  No glaze (--no-glaze)  │
    │   -h  Fire hot (--hot)       │
    │   -l  Fire low (--low)       │
    │ Actions                      │
    │   f  Fire       b  Bisque    │
    ╰─ - switch  ? help  q close ──╯
    cursor: none
    |}];
  let t = Helpers.run ~width ~height t (Helpers.paste "f") in
  show t;
  [%expect {| popup []; focused popup; log []; pending true; notice Popup: read-only; paste ignored |}];
  (* Hiding the view from the popup withdraws it: nothing runs. *)
  let t = run t " vX" in
  show t;
  [%expect {| no popup; focused document; log []; pending false; notice Fire closed; nothing ran |}]
;;

let%expect_test "a popup that cannot fit is refused; one that loses its room or is left is withdrawn" =
  let t = run ~width:19 (create ()) " vxc" in
  show ~width:19 t;
  [%expect {| no popup; focused kiln; log []; pending false; notice Fire cannot fit; needs at least 20 columns and 4 rows; nothing ran |}];
  let t = run (create ()) " vxc-n" in
  let t = Helpers.run ~width:19 ~height t [ Resize ] in
  show ~width:19 t;
  [%expect {| no popup; focused kiln; log []; pending false; notice Fire closed; nothing ran |}];
  (* The palette replaces it (one float at a time); so does it over help. *)
  let t = run (create ()) " vxc cc" in
  show t;
  let t = run (create ()) " vxc? cc" in
  show t;
  printf "help %b\n" (Option.is_some (Ui_state.help t));
  [%expect {|
    no popup; focused palette; log []; pending false; notice (none)
    no popup; focused palette; log []; pending false; notice (none)
    help false
    |}];
  (* Help over a popup that loses its room goes with it. *)
  let t = run (create ()) " vxc?" in
  let t = Helpers.run ~width:19 ~height t [ Resize ] in
  show ~width:19 t;
  printf "help %b\n" (Option.is_some (Ui_state.help t));
  [%expect {|
    no popup; focused kiln; log []; pending false; notice Fire closed; nothing ran
    help false
    |}]
;;

let%expect_test "[Space s t] typed in help or a popup over a view moves that view" =
  let t = run (create ()) " vx? st" in
  show t;
  print_endline (message t);
  printf "placement %s\n"
    (Sexp.to_string
       [%sexp (View_registry.placement (Ui_state.views t) Kiln.id : View_registry.Placement.t option)]);
  [%expect {|
    no popup; focused kiln; log []; pending false; notice Kiln in tab strip
    Kiln in tab strip
    placement (Tab)
    |}];
  let t = run t "c sb" in
  show t;
  print_endline (message t);
  printf "placement %s\n"
    (Sexp.to_string
       [%sexp (View_registry.placement (Ui_state.views t) Kiln.id : View_registry.Placement.t option)]);
  [%expect {|
    popup []; focused popup; log []; pending true; notice Kiln in bottom band
    Kiln in tab strip
    placement (Band)
    |}];
  (* Over the popup's help, too. *)
  let t = run t " vxc? sh" in
  show t;
  print_endline (message t);
  [%expect {|
    no popup; focused document; log []; pending false; notice Fire closed; nothing ran
    Kiln closed
    |}]
;;

let%expect_test "an enabled switch is marked and styled; the dash shows in the footer" =
  let popup = Popup_tile.create ~origin:Kiln.id (Popup.map Kiln.popup ~f:(fun _ -> ())) in
  let popup =
    match Popup_tile.press popup '-' with
    | `Updated popup -> popup
    | `Choose _ | `Unbound _ -> assert false
  in
  let show popup =
    let content = Popup_tile.render popup ~width:30 ~rows:8 in
    printf "footer %S\n" (Option.value_map content.footer ~default:"" ~f:(fun l -> l.text));
    List.iter content.body ~f:(fun row ->
      print_endline
        (String.concat
           (List.map (Span.merge row) ~f:(fun (span : Span.t) ->
              sprintf "[%s]%s" (Style.to_string_hum span.style) (String.rstrip span.text)))))
  in
  show popup;
  let popup =
    match Popup_tile.press popup 'h' with
    | `Updated popup -> popup
    | `Choose _ | `Unbound _ -> assert false
  in
  show popup;
  [%expect {|
    footer "Pending: -"
    [Hint]Switches[Status]
    [Status]  -n  No glaze (--no-glaze)
    [Status]  -h  Fire hot (--hot)
    [Status]  -l  Fire low (--low)
    [Hint]Actions[Status]
    [Status]  f  Fire       b  Bisque
    footer ""
    [Hint]Switches[Status]
    [Status]  -n  No glaze (--no-glaze)
    [Pending]* -h  Fire hot (--hot)[Status]
    [Status]  -l  Fire low (--low)
    [Hint]Actions[Status]
    [Status]  f  Fire       b  Bisque
    |}]
;;
