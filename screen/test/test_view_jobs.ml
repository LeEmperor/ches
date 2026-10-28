open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Job = Ches_vcs.Job
module Event = Ches_vcs.Event
module Stamps = Ches_vcs.Stamps
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 80
let height = 16

(* A test-only view with background work, installed through [Ui_state.create ~views]
   alone: it submits a job when shown, after saves and on [r]; logs its jobs' events,
   dropping what its own stamps call stale; [o]/[O]/[m] open a file at a line; [t]
   shows text in an area inside its content; [a] asks a question when its next job
   finishes. Nothing in [Ui_state] names it. *)
module Worker = struct
  type t =
    { name : string
    ; stamps : Stamps.t
    ; log : string list (** Newest first. *)
    ; text : Ches_tile.Text_view.t option
    ; ask_on_finish : bool
    ; open_target : string
    }
  [@@deriving sexp_of]

  type action =
    | Submit of string (** Why. *)
    | Event of Event.t
    | Open of string * int option
    | Show_text
    | Arm

  let create ?(open_target = "/nonexistent-ches-test/b.txt") name =
    { name
    ; stamps = Stamps.create ()
    ; log = []
    ; text = None
    ; ask_on_finish = false
    ; open_target
    }
  ;;

  let log t line = { t with log = line :: t.log }

  let job t =
    let stamps, id = Stamps.issue ~lane:"work" t.stamps in
    let job =
      Job.create ~id ~lane:"work"
        [ Read_file { path = "/nonexistent-ches-test/work"; limit = 16 } ]
      |> Or_error.ok_exn
    in
    { t with stamps }, job
  ;;

  let id_hum = Job.Id.to_string_hum

  let perform t controller ~context:_ ~rows:_ ~width:_ action =
    let outcome ?notice ?open_file ?jobs ?ask () =
      View_registry.Outcome.create ?notice ?open_file ?jobs ?ask controller
    in
    match action with
    | Submit why ->
      let t, job = job t in
      log t (sprintf "%s: submit %s" why (id_hum job.id)), outcome ~jobs:[ job ] ()
    | Event (Started { job; step; _ }) ->
      log t (sprintf "started %s step %d" (id_hum job) step), outcome ()
    | Event (Output _) -> t, outcome ()
    | Event (Finished report) when not (Stamps.accepts t.stamps report) ->
      log t (sprintf "stale %s dropped" (id_hum report.id)), outcome ()
    | Event (Finished report) ->
      let t =
        log t
          (sprintf "finished %s%s" (id_hum report.id)
             (if report.cancelled then " (cancelled)" else ""))
      in
      if t.ask_on_finish
      then
        ( { t with ask_on_finish = false }
        , outcome
            ~ask:
              (View_registry.Ask.Confirm
                 { title = "Again"; message = "Run again?"; yes = Submit "again"; no = None })
            () )
      else t, outcome ~notice:(`Post (t.name ^ " work done")) ()
    | Open (path, line) -> t, outcome ~open_file:{ path; line; contents = None } ()
    | Show_text ->
      ( { t with
          text = Some (Ches_tile.Text_view.create ~cell_width:Cell_map.width "abc\ndef")
        }
      , outcome () )
    | Arm -> { t with ask_on_finish = true }, outcome ()
  ;;

  let interpret t (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ Char c ] ->
      (match Uchar.to_char c with
       | Some 'r' -> Action (Submit "refresh")
       | Some 'o' -> Action (Open (t.open_target, Some 3))
       | Some 'O' -> Action (Open (t.open_target, Some 99))
       | Some 'm' -> Action (Open ("/nonexistent-ches-test/missing.txt", None))
       | Some 't' -> Action Show_text
       | Some 'a' -> Action Arm
       | _ -> Unbound)
    | _ -> Unbound
  ;;

  let signal _ : View_registry.Signal.t -> action option = function
    | Shown -> Some (Submit "shown")
    | Saved paths ->
      Some (Submit ("saved " ^ String.concat ~sep:"," (List.map paths ~f:Filename.basename)))
    | Job event -> Some (Event event)
    | Request _ -> None
  ;;

  (* One adapter (and typed key) per installed worker. *)
  let adapter name : t Type_equal.Id.t * (t, action) View_registry.Adapter.t =
    let key = Type_equal.Id.create ~name sexp_of_t in
    ( key
    , { spec = Ches_tile.Spec.read_only_text (View_id.of_string name) ~title:name
      ; key
      ; fit = (fun t _ ~rows:_ ~width:_ -> t)
      ; leave = Fn.id
      ; text_view = (fun t -> t.text)
      ; interpret
      ; escape = (fun _ -> None)
      ; hint = "Worker: r refreshes"
      ; perform
      ; commands = (fun _ -> [])
      ; signal
      ; text_area =
          (fun t ~rows:_ ~width:_ ->
            Option.map t.text ~f:(fun _ -> { Geometry.Rect.x = 2; y = 1; width = 10; height = 3 }))
      ; label = (fun _ -> None)
      ; render =
          (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
            { title = t.name
            ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
            ; body = [ Tile_text.row Status (String.concat ~sep:"; " (List.rev t.log)) ~width ]
            })
      } )
  ;;
end

let alpha_key, alpha_adapter = Worker.adapter "alpha"
let beta_key, beta_adapter = Worker.adapter "beta"
let alpha = View_id.of_string "alpha"

let create ?(path = "a") ?(text = "first\nsecond") ?(alpha_opens_in = View_registry.Placement.Tab)
      ?open_target ?(beta = false) ?source_attached ()
  =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view alpha)
         ; leader_v 'X', View (Toggle_view alpha)
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path text)) in
  Ui_state.create ~tiles_visible:false ?source_attached
    ~views:
      (View_registry.Entry.install ~opens_in:alpha_opens_in alpha_adapter
         (Worker.create ?open_target "alpha")
       :: (if beta
           then [ View_registry.Entry.install ~placement:Band beta_adapter (Worker.create "beta") ]
           else []))
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let feed t events = Helpers.run ~width ~height t (List.map events ~f:(fun e -> Ui_state.Input.Vcs e))
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)
let state t key = Option.value_exn (View_registry.find (Ui_state.views t) key)

let print_log ?(key = alpha_key) t =
  let worker = state t key in
  printf "%s log: %s\n" worker.name (String.concat ~sep:"; " (List.rev worker.log))
;;

let take t =
  let t, jobs = Ui_state.take_vcs_jobs t in
  printf "jobs: [%s]\n"
    (String.concat ~sep:"; " (List.map jobs ~f:(fun (job : Job.t) -> Worker.id_hum job.id)));
  t, jobs
;;

let placement t =
  Sexp.to_string
    [%sexp (View_registry.placement (Ui_state.views t) alpha : View_registry.Placement.t option)]
;;

let message t = Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)

let succeeded (job : Job.t) : Event.t =
  Finished
    { id = job.id
    ; lane = job.lane
    ; kind = Job.kind job
    ; steps = List.map job.steps ~f:(fun step -> { Job.Step_report.step; outcome = Read Missing })
    ; cancelled = false
    }
;;

let started (job : Job.t) : Event.t =
  Started
    { job = job.id
    ; step = 0
    ; spec = Ches_vcs.Exec.Spec.create ~kind:Read ~cwd:"/" "true" []
    }
;;

let%expect_test "a shown view submits jobs, hears their events, and drops stale ones itself" =
  let t = create () in
  let t, none = Ui_state.take_vcs_jobs t in
  assert (List.is_empty none);
  let t = run t " vx" in
  printf "focused %s, placement %s\n" (focused t) (placement t);
  let t, first = take t in
  let t, _ = take t in
  [%expect
    {|
    focused alpha, placement (Tab)
    jobs: [g0.1]
    jobs: []
    |}];
  (* A refresh supersedes the first in its lane; the runner's reports for both come
     back in one batch, and only the current one counts for the view. *)
  let t = run t "r" in
  let t, second = take t in
  let first = List.hd_exn first
  and second = List.hd_exn second in
  let t =
    feed t
      [ started first
      ; Finished (Job.never_started first)
      ; started second
      ; succeeded second
      ]
  in
  print_log t;
  printf "focused %s, message %s\n" (focused t) (message t);
  [%expect
    {|
    jobs: [g0.2]
    alpha log: shown: submit g0.1; refresh: submit g0.2; started g0.1 step 0; stale g0.1 dropped; started g0.2 step 0; finished g0.2
    focused alpha, message alpha work done
    |}];
  (* Nothing is delivered after a job's [Finished], nor for jobs no view submitted. *)
  let t = feed t [ succeeded second; started second ] in
  print_log t;
  [%expect
    {| alpha log: shown: submit g0.1; refresh: submit g0.2; started g0.1 step 0; stale g0.1 dropped; started g0.2 step 0; finished g0.2 |}]
;;

let%expect_test "Shown is signalled once per opening: moves are not openings" =
  let t = create () in
  let t = run t " vx" in
  let t, _ = take t in
  (* Split, back to a tab, then close: no new opening. *)
  let t = run t " ss" in
  printf "placement %s\n" (placement t);
  let t = run t " st" in
  printf "placement %s\n" (placement t);
  let t = run t " sh" in
  printf "placement %s\n" (placement t);
  let t, _ = take t in
  [%expect
    {|
    jobs: [g0.1]
    placement (Split)
    placement (Tab)
    placement (Hidden)
    jobs: []
    |}];
  (* Reopening is; Toggle_view opens it where it opens (a tab), and closes it. *)
  let t = run t " vx" in
  let t, _ = take t in
  let t = run t " vX" in
  printf "placement %s\n" (placement t);
  let t = run t " vX" in
  printf "placement %s, active tab %s, focused %s\n" (placement t)
    (Option.value_map (Ui_state.active_tab_view t) ~default:"none" ~f:View_id.to_string)
    (focused t);
  let t, _ = take t in
  print_log t;
  [%expect
    {|
    jobs: [g0.2]
    placement (Hidden)
    placement (Tab), active tab alpha, focused alpha
    jobs: [g0.3]
    alpha log: shown: submit g0.1; shown: submit g0.2; shown: submit g0.3
    |}]
;;

let%expect_test "a view installed placed is shown by the first input; ids in flight are not reused" =
  let t = create ~beta:true () in
  let t = run t "l" in
  let t, beta_jobs = take t in
  print_log ~key:beta_key t;
  [%expect
    {|
    jobs: [g0.1]
    beta log: shown: submit g0.1
    |}];
  (* Alpha's stamps issue the same id, still in flight for beta: it is not submitted,
     and alpha hears at once that it never started. *)
  let t = run t " vx" in
  let t, _ = take t in
  print_log t;
  [%expect
    {|
    jobs: []
    alpha log: shown: submit g0.1; finished g0.1 (cancelled)
    |}];
  (* The runner's report goes to beta, which owns the id. *)
  let t = feed t [ succeeded (List.hd_exn beta_jobs) ] in
  print_log t;
  print_log ~key:beta_key t;
  [%expect
    {|
    alpha log: shown: submit g0.1; finished g0.1 (cancelled)
    beta log: shown: submit g0.1; finished g0.1
    |}]
;;

let%expect_test "saves signal every view, once per input, without taking source requests" =
  Fixture.with_repo (fun repo ->
    let t = create ~path:(Fixture.path repo "a.txt") ~source_attached:true () in
    let t, _ = Ui_state.take_source_requests t in
    let t = run t "ix<Esc> w" in
    let t, _ = take t in
    let t = run t "iy<Esc> wiz<Esc> w" in
    let t, _ = take t in
    print_log t;
    let _, requests = Ui_state.take_source_requests t in
    List.iter requests ~f:(fun request ->
      match request with
      | Document_saved { revision; _ } -> printf "source: saved revision %d\n" revision
      | _ -> ());
    [%expect
      {|
      jobs: [g0.1]
      jobs: [g0.2; g0.3]
      alpha log: saved a.txt: submit g0.1; saved a.txt: submit g0.2; saved a.txt: submit g0.3
      source: saved revision 1
      source: saved revision 2
      source: saved revision 3
      |}])
;;

let%expect_test "an outcome opens a file at a line: from a tab, from the split, or not at all" =
  Fixture.with_repo (fun repo ->
    let b = Fixture.path repo "b.txt" in
    Fixture.write repo "b.txt" "1\n2\n3\n4\n5\n";
    let show t =
      let editor = Controller.editor (Ui_state.controller t) in
      printf "focused %s, file %s, line %d, placement %s, active tab %s\n" (focused t)
        (Option.value_map (Ches_core.Editor.path editor) ~default:"none" ~f:Filename.basename)
        (Ches_core.Editor.cursor_line editor + 1)
        (placement t)
        (Option.value_map (Ui_state.active_tab_view t) ~default:"none" ~f:View_id.to_string)
    in
    let t = create ~open_target:b () in
    let t = run t " vxo" in
    show t;
    (* Past the end is the last line; the view tab is still a tab. *)
    let t = run t " vxO" in
    show t;
    (* From the split, the file shows in the other pane, which is focused. *)
    let t = run t " vx ss" in
    show t;
    let t = run t "o" in
    show t;
    (* A file that cannot be opened is the view's notice; focus stays. *)
    let t = run t " vxm" in
    show t;
    print_endline (Option.value (Ui_state.capture_notice t) ~default:"(none)");
    [%expect
      {|
      focused document, file b.txt, line 3, placement (Tab), active tab none
      focused document, file b.txt, line 6, placement (Tab), active tab none
      focused alpha, file b.txt, line 6, placement (Split), active tab none
      focused document, file b.txt, line 3, placement (Split), active tab none
      focused alpha, file b.txt, line 3, placement (Split), active tab none
      alpha: file no longer exists: /nonexistent-ches-test/missing.txt
      |}])
;;

let%expect_test "signalled outcomes never move focus; a question opens only over the focused view" =
  let t = create ~alpha_opens_in:Band () in
  let t = run t " vxa" in
  let t, jobs = take t in
  printf "focused %s\n" (focused t);
  let t = feed t [ succeeded (List.hd_exn jobs) ] in
  printf "focused %s, asking %b\n" (focused t) (Option.is_some (Ui_state.confirm t));
  (* Its answer is the view's action, as for a key's question. *)
  let t = run t "y" in
  let t, jobs = take t in
  printf "focused %s\n" (focused t);
  [%expect
    {|
    jobs: [g0.1]
    focused alpha
    focused confirm, asking true
    jobs: [g0.2]
    focused alpha
    |}];
  (* Unfocused: the question is withdrawn; a posted notice reaches feedback only. *)
  let t = run t "a<Tab>" in
  let t = feed t [ succeeded (List.hd_exn jobs) ] in
  printf "focused %s, asking %b, pending %b, capture notice %s\n" (focused t)
    (Option.is_some (Ui_state.confirm t))
    (Option.is_some (View_registry.asking (Ui_state.views t) alpha))
    (Option.value (Ui_state.capture_notice t) ~default:"(none)");
  let t = run t " vxr<Tab>" in
  let t, jobs = take t in
  let t = feed t [ succeeded (List.hd_exn jobs) ] in
  printf "focused %s, message %s\n" (focused t) (message t);
  print_log t;
  [%expect
    {|
    focused document, asking false, pending false, capture notice (none)
    jobs: [g0.3]
    focused document, message alpha work done
    alpha log: shown: submit g0.1; finished g0.1; again: submit g0.2; finished g0.2; refresh: submit g0.3; finished g0.3
    |}]
;;

let%expect_test "the terminal cursor is the text cursor in the view's text area" =
  let t = create ~alpha_opens_in:Band () in
  let t = run t " vxt" in
  let layout = Option.value_exn (Ui_state.minor_layout t ~width ~height alpha) in
  let x, y, _ = Option.value_exn (Ui_state.minor_cursor t ~width ~height) in
  printf "cursor at content + (%d, %d)\n" (x - layout.content.x) (y - layout.content.y);
  [%expect {| cursor at content + (2, 1) |}]
;;

let%expect_test "the shared driver runs submitted jobs to completion and feeds them back" =
  Fixture.with_repo (fun repo ->
    let t = run (create ()) " vx" in
    let t, ran = Vcs_driver.settle repo t ~width ~height in
    List.iter ran ~f:(fun job -> print_endline (Vcs_driver.describe job));
    print_log t);
  [%expect {|
    work g0.1
    alpha log: shown: submit g0.1; finished g0.1
    |}]
;;
