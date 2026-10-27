open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Ask = View_registry.Ask

let width = 80
let height = 16

(* A test-only view that asks: a shelf of names. [d] confirms deleting the last one
   (declining says so), [D] confirms clearing (declining names no action), [a] prompts
   for a name to add, and [r] prompts for a name and then confirms adding it. *)
module Shelf = struct
  let id = View_id.of_string "shelf"

  type t = { items : string list } [@@deriving sexp_of]

  type action =
    | Ask_delete
    | Ask_clear
    | Ask_add
    | Ask_review
    | Delete
    | Clear
    | Add of string
    | Review of string
    | Kept

  let key = Type_equal.Id.create ~name:"shelf" sexp_of_t

  let validate text =
    if String.is_empty text
    then Some "Name required"
    else if String.mem text ' '
    then Some "No spaces"
    else None
  ;;

  let interpret _ (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ Char c ] ->
      (match Uchar.to_char c with
       | Some 'd' -> Action Ask_delete
       | Some 'D' -> Action Ask_clear
       | Some 'a' -> Action Ask_add
       | Some 'r' -> Action Ask_review
       | _ -> Unbound)
    | _ -> Unbound
  ;;

  let perform t controller ~context:_ ~rows:_ ~width:_ action =
    let outcome ?notice ?ask () = View_registry.Outcome.create ?notice ?ask controller in
    let prompt ~accept =
      Ask.Prompt { title = "New name"; initial = ""; validate; accept; cancel = Some Kept }
    in
    match action with
    | Ask_delete ->
      ( t
      , outcome
          ~ask:
            (Ask.Confirm
               { title = "Delete"
               ; message =
                   sprintf "Delete %s from the shelf?" (Option.value (List.last t.items) ~default:"nothing")
               ; yes = Delete
               ; no = Some Kept
               })
          () )
    | Ask_clear ->
      t, outcome ~ask:(Ask.Confirm { title = "Clear"; message = "Clear the shelf?"; yes = Clear; no = None }) ()
    | Ask_add -> t, outcome ~ask:(prompt ~accept:(fun name -> Add name)) ()
    | Ask_review -> t, outcome ~ask:(prompt ~accept:(fun name -> Review name)) ()
    | Review name ->
      ( t
      , outcome
          ~ask:(Ask.Confirm { title = "Add"; message = sprintf "Add %s?" name; yes = Add name; no = Some Kept })
          () )
    | Delete -> { items = List.drop_last t.items |> Option.value ~default:[] }, outcome ~notice:(`Show "Deleted") ()
    | Clear -> { items = [] }, outcome ~notice:(`Show "Cleared") ()
    | Add name -> { items = t.items @ [ name ] }, outcome ~notice:(`Show ("Added " ^ name)) ()
    | Kept -> t, outcome ~notice:(`Show "Kept") ()
  ;;

  let adapter : (t, action) View_registry.Adapter.t =
    { spec = Ches_tile.Spec.read_only id ~title:"Shelf"
    ; key
    ; fit = (fun t _ ~rows:_ ~width:_ -> t)
    ; leave = Fn.id
    ; text_view = (fun _ -> None)
    ; interpret
    ; escape = (fun _ -> None)
    ; hint = "Shelf: d deletes, D clears, a adds, r reviews"
    ; perform
    ; commands =
        (fun _ -> [ Ches_tile.Local_command.create "delete" ~keys:[ Key.char 'd' ] "Delete the last" ])
    ; signal = (fun _ _ -> None)
    ; text_area = (fun _ ~rows:_ ~width:_ -> None)
    ; render =
        (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
          { title = "Shelf"
          ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
          ; body = [ Tile_text.row Status (String.concat ~sep:" " t.items) ~width ]
          })
    }
  ;;
end

let create () =
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ [ Key.char ' '; Key.char 'v'; Key.char 'x' ], Bindings.Target.View (Focus_view Shelf.id)
         ; [ Key.char ' '; Key.char 'v'; Key.char 'X' ], View (Toggle_view Shelf.id)
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path:"a" "first\nsecond")) in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ View_registry.Entry.install ~placement:Band Shelf.adapter { items = [ "ash"; "elm" ] } ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run ?(width = width) ?(height = height) t keys = Helpers.run ~width ~height t (Helpers.keys keys)
(* The float's rows and the cursor: the document title above them names the build
   sandbox. *)
let float_rows t =
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  List.iter (List.take (List.drop lines 6) 4 @ [ List.last_exn lines ]) ~f:print_endline
;;

let items t =
  String.concat ~sep:" " (Option.value_exn (View_registry.find (Ui_state.views t) Shelf.key)).items
;;

let show ?(width = width) ?(height = height) t =
  let float =
    match Ui_state.confirm t, Ui_state.prompt t with
    | Some confirm, _ -> sprintf "confirm %S" (Confirm_tile.message confirm)
    | None, Some prompt ->
      sprintf "prompt %S%s" (Prompt_tile.text prompt)
        (Option.value_map (Prompt_tile.error prompt) ~default:"" ~f:(sprintf " (error %S)"))
    | None, None -> "no float"
  in
  printf "%s; focused %s; items [%s]; pending %b; notice %s\n" float
    (View_id.to_string (Ui_state.focused_view t ~width ~height))
    (items t)
    (Option.is_some (View_registry.asking (Ui_state.views t) Shelf.id))
    (Option.value (Ui_state.capture_notice t) ~default:"(none)")
;;

let%expect_test "a confirmation opens over the view; only y performs its action" =
  let t = run (create ()) " vxd" in
  show t;
  float_rows t;
  [%expect {|
    confirm "Delete elm from the shelf?"; focused confirm; items [ash elm]; pending true; notice (none)
    │                       ╭─ Delete ─────────────────────╮                       │|
    │                       │ Delete elm from the shelf?   │                       │|
    │                       │ y yes   n no (default)       │                       │|
    ╰───────────────────────╰──────────────────────────────╯───────────────────────╯|
    cursor: none
    |}];
  (* Any other key, including Y, Enter and q, answers nothing. *)
  let t = run t "xY<CR>q" in
  show t;
  let t = run t "y" in
  show t;
  [%expect {|
    confirm "Delete elm from the shelf?"; focused confirm; items [ash elm]; pending true; notice y confirms; n or Escape cancels
    no float; focused shelf; items [ash]; pending false; notice Deleted
    |}];
  List.iter [ "n"; "<Esc>"; "<Tab>"; "<C-c>" ] ~f:(fun decline ->
    let t = run t ("d" ^ decline) in
    show t);
  [%expect {|
    no float; focused shelf; items [ash]; pending false; notice Kept
    no float; focused shelf; items [ash]; pending false; notice Kept
    no float; focused shelf; items [ash]; pending false; notice Kept
    no float; focused shelf; items [ash]; pending false; notice Kept
    |}];
  (* Declining a question that names no action runs nothing. *)
  let t = run t "Dn" in
  show t;
  let t = run t "Dy" in
  show t;
  [%expect {|
    no float; focused shelf; items [ash]; pending false; notice (none)
    no float; focused shelf; items []; pending false; notice Cleared
    |}]
;;

let%expect_test "a prompt edits a line, validates inline, and accepts or cancels" =
  let t = run (create ()) " vxa" in
  show t;
  [%expect {| prompt ""; focused prompt; items [ash elm]; pending true; notice (none) |}];
  (* Enter on invalid text keeps the prompt and shows why. *)
  let t = run t "<CR>" in
  show t;
  float_rows t;
  [%expect {|
    prompt "" (error "Name required"); focused prompt; items [ash elm]; pending true; notice (none)
    │         ╭─ New name ───────────────────────────────────────────────╮         │|
    │         │ >                                                        │         │|
    │         │ Name required                                            │         │|
    ╰─────────╰──────────────────────────────────────────────────────────╯─────────╯|
    cursor: 14,7 Bar
    |}];
  (* Every character is text, including the leader, q and ?; validation follows edits. *)
  let t = run t "q? x" in
  show t;
  let t = run t "<BS><BS><C-w>oak" in
  show t;
  let t = run t "<CR>" in
  show t;
  [%expect {|
    prompt "q? x" (error "No spaces"); focused prompt; items [ash elm]; pending true; notice (none)
    prompt "oak"; focused prompt; items [ash elm]; pending true; notice (none)
    no float; focused shelf; items [ash elm oak]; pending false; notice Added oak
    |}];
  List.iter [ "<Esc>"; "<Tab>"; "<C-c>" ] ~f:(fun cancel ->
    let t = run t ("afir" ^ cancel) in
    show t);
  [%expect {|
    no float; focused shelf; items [ash elm oak]; pending false; notice Kept
    no float; focused shelf; items [ash elm oak]; pending false; notice Kept
    no float; focused shelf; items [ash elm oak]; pending false; notice Kept
    |}]
;;

let%expect_test "a paste reaches the prompt as one sanitized line; the confirmation rejects it" =
  let t = run (create ()) " vxa" in
  let t = Helpers.run ~width ~height t (Helpers.paste "yew<Tab>tree") in
  show t;
  let t = run t "<C-w><BS>" in
  show t;
  [%expect {|
    prompt "yew tree" (error "No spaces"); focused prompt; items [ash elm]; pending true; notice (none)
    prompt "yew"; focused prompt; items [ash elm]; pending true; notice (none)
    |}];
  let t = run t "<Esc>d" in
  let t = Helpers.run ~width ~height t (Helpers.paste "y") in
  show t;
  [%expect {| confirm "Delete elm from the shelf?"; focused confirm; items [ash elm]; pending true; notice Confirm: read-only; paste ignored |}]
;;

let%expect_test "an answer's action may ask again" =
  let t = run (create ()) " vxrfir<CR>" in
  show t;
  let t = run t "y" in
  show t;
  let t = run t "rpine<CR>n" in
  show t;
  [%expect {|
    confirm "Add fir?"; focused confirm; items [ash elm]; pending true; notice (none)
    no float; focused shelf; items [ash elm fir]; pending false; notice Added fir
    no float; focused shelf; items [ash elm fir]; pending false; notice Kept
    |}]
;;

let%expect_test "a question that cannot fit is refused; one that loses its room is withdrawn" =
  (* 19 columns leave room for the shelf band but not the 20-column question. *)
  let t = run ~width:19 (create ()) " vxd" in
  show ~width:19 t;
  [%expect {| no float; focused shelf; items [ash elm]; pending false; notice Delete cannot fit; needs at least 20 columns and 4 rows; nothing ran |}];
  let t = run (create ()) " vxa" in
  let t = Helpers.run ~width:19 ~height t [ Resize ] in
  show ~width:19 t;
  [%expect {| no float; focused shelf; items [ash elm]; pending false; notice New name closed; nothing ran |}];
  let t = Helpers.run ~width ~height t [ Resize ] in
  let t = run t "y" in
  show t;
  [%expect {| no float; focused shelf; items [ash elm]; pending false; notice Shelf: d deletes, D clears, a adds, r reviews |}]
;;

let%expect_test "leaving the question another way withdraws it; nothing runs" =
  (* Hiding the view through a workspace key typed into the confirmation. *)
  let t = run (create ()) " vxd vX" in
  show t;
  [%expect {| no float; focused document; items [ash elm]; pending false; notice Delete closed; nothing ran |}];
  (* The palette replaces the float (one float at a time). *)
  let t = run (create ()) " vxd cc" in
  show t;
  [%expect {| no float; focused palette; items [ash elm]; pending false; notice (none) |}];
  let t = run t "<Esc>" in
  show t;
  [%expect {| no float; focused document; items [ash elm]; pending false; notice (none) |}]
;;

let%expect_test "closing the split view under its question: the feedback line says so" =
  (* [Space s c] typed into the confirmation closes the view, which withdraws the
     question; the view's notice cannot show in a footer, so the feedback line has it. *)
  let t = run (create ()) " vx ssd" in
  show t;
  let t = run t " sc" in
  show t;
  print_endline (Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text));
  [%expect
    {|
    confirm "Delete elm from the shelf?"; focused confirm; items [ash elm]; pending true; notice (none)
    no float; focused document; items [ash elm]; pending false; notice Delete closed; nothing ran
    Shelf closed
    |}]
;;

let%expect_test "a local command run from the palette asks over its view" =
  let t = run (create ()) " vx cc" in
  let t = run t "delete<CR>" in
  show t;
  let t = run t "y" in
  show t;
  [%expect {|
    confirm "Delete elm from the shelf?"; focused confirm; items [ash elm]; pending true; notice (none)
    no float; focused shelf; items [ash]; pending false; notice Deleted
    |}]
;;
