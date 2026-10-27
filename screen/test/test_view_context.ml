open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor
module View_id = Ches_tile.View_id
module Job = Ches_vcs.Job
module Event = Ches_vcs.Event
module Stamps = Ches_vcs.Stamps
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 80
let height = 16

(* A test-only view over a directory [root], installed through [Ui_state.create ~views]
   alone: [d] logs the dirty file buffers within [root] from its perform context, [c]
   asks a question whose [y] does the same (the answer's context), [r] asks the
   application to reconcile buffers within [root] at once, and [j] submits a job whose
   [Finished] signal asks for it. Nothing in [Ui_state] names it. *)
module Keeper = struct
  type t =
    { root : string
    ; stamps : Stamps.t
    ; log : string list (** Newest first. *)
    }
  [@@deriving sexp_of]

  type action =
    | Dirty of string (** Why. *)
    | Ask
    | Reconcile
    | Submit
    | Event of Event.t

  let log t line = { t with log = line :: t.log }

  let perform t controller ~context ~rows:_ ~width:_ action =
    let outcome ?notice ?jobs ?reconcile ?ask () =
      View_registry.Outcome.create ?notice ?jobs ?reconcile ?ask controller
    in
    match action with
    | Dirty why ->
      let dirty =
        List.map (View_registry.Context.dirty_within context ~root:t.root)
          ~f:(fun (file : View_registry.Context.File.t) -> file.label)
      in
      let files = List.length (View_registry.Context.files context) in
      ( log t (sprintf "%s: %d files, dirty [%s]" why files (String.concat ~sep:", " dirty))
      , outcome () )
    | Ask ->
      ( t
      , outcome
          ~ask:
            (View_registry.Ask.Confirm
               { title = "Check"; message = "Check?"; yes = Dirty "answer"; no = None })
          () )
    | Reconcile -> log t "reconcile", outcome ~reconcile:[ t.root ] ()
    | Submit ->
      let stamps, id = Stamps.issue t.stamps in
      let job =
        Job.create ~id [ Read_file { path = "/nonexistent-ches-test/keeper"; limit = 16 } ]
        |> Or_error.ok_exn
      in
      log { t with stamps } "submit", outcome ~jobs:[ job ] ()
    | Event (Finished _) ->
      log t "finished: reconcile", outcome ~reconcile:[ t.root ] ~notice:(`Post "keeper done") ()
    | Event (Started _ | Output _) -> t, outcome ()
  ;;

  let interpret _ (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ Char c ] ->
      (match Uchar.to_char c with
       | Some 'd' -> Action (Dirty "key")
       | Some 'c' -> Action Ask
       | Some 'r' -> Action Reconcile
       | Some 'j' -> Action Submit
       | _ -> Unbound)
    | _ -> Unbound
  ;;

  let key = Type_equal.Id.create ~name:"keeper" sexp_of_t

  let adapter : (t, action) View_registry.Adapter.t =
    { spec = Ches_tile.Spec.read_only_text (View_id.of_string "keeper") ~title:"Keeper"
    ; key
    ; fit = (fun t _ ~rows:_ ~width:_ -> t)
    ; leave = Fn.id
    ; text_view = (fun _ -> None)
    ; interpret
    ; escape = (fun _ -> None)
    ; hint = "Keeper: d dirty, r reconcile"
    ; perform
    ; commands = (fun _ -> [])
    ; signal =
        (fun _ -> function
          | Job event -> Some (Event event)
          | Shown | Saved _ -> None)
    ; text_area = (fun _ ~rows:_ ~width:_ -> None)
    ; render =
        (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
          { title = "Keeper"
          ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
          ; body = [ Tile_text.row Status (String.concat ~sep:"; " (List.rev t.log)) ~width ]
          })
    }
  ;;
end

let keeper = View_id.of_string "keeper"

(* The editor on [a.txt] of [root] as it is on disk, the keeper placed in the band. *)
let create root =
  let path = Filename.concat root "a.txt" in
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default @ [ leader_v 'x', Bindings.Target.View (Focus_view keeper) ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path (In_channel.read_all path))) in
  Ui_state.create ~tiles_visible:false
    ~views:[ View_registry.Entry.install Keeper.adapter { root; stamps = Stamps.create (); log = [] } ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)

let print_log t =
  let keeper = Option.value_exn (View_registry.find (Ui_state.views t) Keeper.key) in
  printf "log: %s\n" (String.concat ~sep:"; " (List.rev keeper.log))
;;

let editor t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf "focused %s; %s: %S, line %d, column %d, dirty %b\n" (focused t)
    (Option.value_map (Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Ches_core.Text_buffer.to_string (Editor.text editor))
    (Editor.cursor_line editor + 1) (Editor.cursor_column editor + 1) (Editor.is_dirty editor)
;;

let message t = Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)

let%expect_test "a view sees the session's dirty file buffers when it performs, keys and answers alike" =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\ntwo\n";
    Fixture.write repo "b.txt" "bee\n";
    let t = create repo.work in
    let t = run t " vxd" in
    (* Unsaved text in the editor: the active controller's latest state counts. *)
    let t = run t "<Esc>iX<Esc> vxd" in
    let t, _ =
      Ui_state.open_file t ~width ~height (Fixture.path repo "b.txt") |> Or_error.ok_exn
    in
    let t = run t "iY<Esc> vxc" in
    printf "focused %s\n" (focused t);
    let t = run t "y" in
    print_log t;
    [%expect
      {|
      focused confirm
      log: key: 1 files, dirty []; key: 1 files, dirty [a.txt]; answer: 2 files, dirty [a.txt, b.txt]
      |}])
;;

let%expect_test "an outcome reconciles buffers within a root, from a key or a job's signal" =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\ntwo\nthree\n";
    let t = create repo.work in
    let t = run t "jl" in
    Fixture.write repo "a.txt" "ONE\nTWO\nTHREE\n";
    let t = run t " vxr" in
    editor t;
    print_endline (message t);
    [%expect
      {|
      focused keeper; a.txt: "ONE\nTWO\nTHREE\n", line 2, column 2, dirty false
      Reloaded from disk: a.txt
      |}];
    (* From a signal: the job finishes while the editor has focus, which it keeps. *)
    let t = run t "j<Esc>" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    Fixture.write repo "a.txt" "1\n";
    printf "focused %s\n" (focused t);
    let t =
      Helpers.run ~width ~height t
        (List.map (List.concat_map jobs ~f:(Vcs_driver.events repo)) ~f:(fun event ->
           Ui_state.Input.Vcs event))
    in
    editor t;
    print_endline (message t);
    print_log t;
    [%expect
      {|
      focused document
      focused document; a.txt: "1\n", line 2, column 1, dirty false
      keeper done
      log: reconcile; submit; finished: reconcile
      |}];
    (* A deleted file marks the buffer missing; its text stays. (Deleted while the view
       has focus: an editor command would notice it first.) *)
    let t = run t " vx" in
    Core_unix.unlink (Fixture.path repo "a.txt");
    let t = run t "r" in
    editor t;
    printf "missing %b; %s\n" (Controller.is_missing (Ui_state.controller t)) (message t);
    [%expect
      {|
      focused keeper; a.txt: "1\n", line 2, column 1, dirty false
      missing true; Deleted on disk (kept, marked missing): a.txt
      |}])
;;
