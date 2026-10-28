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

(* A test-only view that hands out a file to edit, [note.txt] in [root], through the
   generic seams alone; nothing in [Ui_state] names it. Keys: [o] opens the note with
   fresh contents ([Location.contents], "version N"), [p] reads it in the background
   and opens it when the read finishes (a signalled [open_file]), [w] logs who has the
   editor's input ([Context.active]), [s] saves the note and submits a job that needs
   it, [d] disposes of it. Requests (signals): ["where"], ["save"] and ["drop"] do
   the same as [w], [s] and [d]; any other is ignored. Its tab label counts its log. *)
module Desk = struct
  let id = View_id.of_string "desk"

  type t =
    { root : string
    ; stamps : Stamps.t
    ; version : int
    ; save_target : string option (** Instead of the note, for a failing save. *)
    ; reading : bool (** The next [Finished] is the read's: open the note. *)
    ; log : string list (** Newest first. *)
    }
  [@@deriving sexp_of]

  type action =
    | Open
    | Read
    | Where of string
    | Save of string
    | Drop of string
    | Event of Event.t

  let note t = Filename.concat t.root "note.txt"
  let log t line = { t with log = line :: t.log }
  let key = Type_equal.Id.create ~name:"desk" sexp_of_t

  let job t =
    let stamps, id = Stamps.issue t.stamps in
    let job =
      Job.create ~id [ Read_file { path = "/nonexistent-ches-test/desk"; limit = 16 } ]
      |> Or_error.ok_exn
    in
    { t with stamps }, job
  ;;

  let perform t controller ~context ~rows:_ ~width:_ action =
    let outcome ?notice ?open_file ?jobs ?save ?dispose () =
      View_registry.Outcome.create ?notice ?open_file ?jobs ?save ?dispose controller
    in
    match action with
    | Open ->
      let t = { t with version = t.version + 1 } in
      ( log t (sprintf "open version %d" t.version)
      , outcome
          ~open_file:
            { path = note t
            ; line = Some 2
            ; contents = Some (sprintf "version %d\nsecond line\n" t.version)
            }
          () )
    | Read ->
      let t, job = job { t with version = t.version + 1; reading = true } in
      log t "read", outcome ~jobs:[ job ] ()
    | Event (Finished report) ->
      let reading = t.reading in
      let t =
        log { t with reading = false }
          (sprintf "finished%s" (if report.cancelled then " (never started)" else ""))
      in
      if reading
      then
        ( t
        , outcome
            ~open_file:
              { path = note t
              ; line = Some 1
              ; contents = Some (sprintf "read back %d\n" t.version)
              }
            () )
      else t, outcome ()
    | Event (Started _ | Output _) -> t, outcome ()
    | Where why ->
      let active =
        Option.value_map (View_registry.Context.active context) ~default:"none"
          ~f:(fun (file : View_registry.Context.File.t) -> file.label)
      in
      log t (sprintf "%s: active %s" why active), outcome ()
    | Save why ->
      let t, job = job t in
      ( log t (sprintf "%s: save" why)
      , outcome ~save:[ Option.value t.save_target ~default:(note t) ] ~jobs:[ job ]
          ~notice:(`Post "Desk saved") () )
    | Drop why -> log t (sprintf "%s: drop" why), outcome ~dispose:[ note t ] ()
  ;;

  let interpret _ (keys : Key.t list) : action Ches_tile.Content_key.t =
    match keys with
    | [ Char c ] ->
      (match Uchar.to_char c with
       | Some 'o' -> Action Open
       | Some 'p' -> Action Read
       | Some 'w' -> Action (Where "key")
       | Some 's' -> Action (Save "key")
       | Some 'd' -> Action (Drop "key")
       | _ -> Unbound)
    | _ -> Unbound
  ;;

  let signal _ : View_registry.Signal.t -> action option = function
    | Request "where" -> Some (Where "request")
    | Request "save" -> Some (Save "request")
    | Request "drop" -> Some (Drop "request")
    | Job event -> Some (Event event)
    | Request _ | Shown | Saved _ -> None
  ;;

  let adapter : (t, action) View_registry.Adapter.t =
    { spec = Ches_tile.Spec.read_only id ~title:"Desk"
    ; key
    ; fit = (fun t _ ~rows:_ ~width:_ -> t)
    ; leave = Fn.id
    ; text_view = (fun _ -> None)
    ; interpret
    ; escape = (fun _ -> None)
    ; hint = "Desk: o opens the note"
    ; perform
    ; commands = (fun _ -> [])
    ; signal
    ; text_area = (fun _ ~rows:_ ~width:_ -> None)
    ; label = (fun t -> Some (sprintf "Desk (%d)" (List.length t.log)))
    ; render =
        (fun t _ ~hotkey_hints:_ ~focused:_ ~notice ~pending ~width ~rows:_ ->
          { title = "Desk"
          ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default:"")
          ; body = [ Tile_text.row Status (String.concat ~sep:"; " (List.rev t.log)) ~width ]
          })
    }
  ;;
end

let absent = View_id.of_string "absent"

(* The editor on [a.txt] of [root], the desk installed [placement] (opening in a tab)
   beside an unavailable "absent" view. *)
let create ?(placement = View_registry.Placement.Hidden) ?save_target root =
  let path = Filename.concat root "a.txt" in
  Out_channel.write_all path ~data:"alpha\n";
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let request ?(view = Desk.id) c request =
    [ Key.char ' '; Key.char 'k'; Key.char c ], Bindings.Target.View (Request_view { view; request })
  in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view Desk.id)
         ; request 'r' "where"
         ; request 'w' "save"
         ; request 'd' "drop"
         ; request 'i' "polish"
         ; request ~view:absent 'a' "where"
         ; request ~view:(View_id.of_string "nowhere") 'n' "where"
         ])
    |> Or_error.ok_exn
  in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path "alpha\n")) in
  Ui_state.create ~tiles_visible:false
    ~views:
      [ View_registry.Entry.install ~placement ~opens_in:Tab Desk.adapter
          { root; stamps = Stamps.create (); version = 0; save_target; reading = false; log = [] }
      ; View_registry.Entry.unavailable absent ~title:"Absent" ~notice:"Absent unavailable here"
      ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)
let message t = Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)

let print_log t =
  let desk = Option.value_exn (View_registry.find (Ui_state.views t) Desk.key) in
  printf "log: %s\n" (String.concat ~sep:"; " (List.rev desk.log))
;;

(* Focus, the tab strip (the active entry starred), and the editor's buffer. *)
let show t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf "focused %s; tabs [%s]; %s: %S line %d%s\n" (focused t)
    (String.concat ~sep:" "
       (List.map (Ui_state.tab_items t) ~f:(fun (item : Tab_strip.Item.t) ->
          (if item.active then "*" else "") ^ item.label)))
    (Option.value_map (Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Ches_core.Text_buffer.to_string (Editor.text editor))
    (Editor.cursor_line editor + 1)
    (if Editor.is_dirty editor then " dirty" else "")
;;

(* Fixture paths are under a fresh temporary directory. *)
let scrub (repo : Fixture.t) text = String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"

let disk path =
  if Sys_unix.file_exists_exn path then sprintf "%S" (In_channel.read_all path) else "(none)"
;;

let finished (job : Job.t) : Event.t =
  Finished
    { id = job.id
    ; lane = job.lane
    ; kind = Job.kind job
    ; steps = List.map job.steps ~f:(fun step -> { Job.Step_report.step; outcome = Read Missing })
    ; cancelled = false
    }
;;

let%expect_test "a request reaches the view focused or not, hidden or placed" =
  Fixture.with_repo (fun repo ->
    let t = create repo.work in
    (* From the editor, to the hidden view: the editor's buffer has the input. *)
    let t = run t " kr" in
    print_log t;
    show t;
    [%expect {|
      log: request: active a.txt
      focused document; tabs [*a.txt]; a.txt: "alpha\n" line 1
      |}];
    (* From the focused view: no buffer has the editor's input. *)
    let t = run t " vx kr" in
    print_log t;
    show t;
    [%expect {|
      log: request: active a.txt; request: active none
      focused desk; tabs [a.txt *Desk (2)]; a.txt: "alpha\n" line 1
      |}];
    (* Ignored, unavailable, unknown: the feedback line (and a focused view's footer). *)
    let t = run t " ki" in
    printf "%s | footer %s\n" (message t) (Option.value (Ui_state.capture_notice t) ~default:"-");
    let t = run t "<Esc> ka" in
    printf "%s\n" (message t);
    let t = run t " kn" in
    printf "%s\n" (message t);
    print_log t;
    [%expect {|
      Desk: nothing to do for polish | footer Desk: nothing to do for polish
      Absent unavailable here
      View nowhere unavailable
      log: request: active a.txt; request: active none
      |}])
;;

let%expect_test "open_file with contents writes the file first; a dirty buffer refuses it" =
  Fixture.with_repo (fun repo ->
    let note = Fixture.path repo "note.txt" in
    let t = create ~placement:Tab repo.work in
    (* A new file: written, opened at line 2. *)
    let t = run t " vxo" in
    show t;
    printf "disk %s\n" (disk note);
    [%expect {|
      focused document; tabs [a.txt *note.txt Desk (1)]; note.txt: "version 1\nsecond line\n" line 2
      disk "version 1\nsecond line\n"
      |}];
    (* Back in the view: a retained clean buffer is reloaded from the new text. *)
    let t = run t " vxo" in
    show t;
    printf "disk %s; %s\n" (disk note) (message t);
    [%expect {|
      focused document; tabs [a.txt *note.txt Desk (2)]; note.txt: "version 2\nsecond line\n" line 2
      disk "version 2\nsecond line\n"; Reloaded from disk: note.txt
      |}];
    (* A dirty buffer for the path refuses it: nothing written. *)
    let t = run t "ix<Esc> vxo" in
    show t;
    printf "disk %s; footer %s\n" (disk note)
      (Option.value (Ui_state.capture_notice t) ~default:"-");
    [%expect {|
      focused desk; tabs [a.txt note.txt *Desk (3)]; note.txt: "version 2\nxsecond line\n" line 2 dirty
      disk "version 2\nsecond line\n"; footer Desk: note.txt has unsaved changes; save or undo them first; nothing written
      |}]);
  (* Replacing a file that exists but has no buffer. *)
  Fixture.with_repo (fun repo ->
    let note = Fixture.path repo "note.txt" in
    Out_channel.write_all note ~data:"old\n";
    let t = create ~placement:Tab repo.work in
    let t = run t " vxo" in
    show t;
    printf "disk %s\n" (disk note);
    [%expect {|
      focused document; tabs [a.txt *note.txt Desk (1)]; note.txt: "version 1\nsecond line\n" line 2
      disk "version 1\nsecond line\n"
      |}])
;;

let%expect_test "a signalled open_file applies only while the view is focused" =
  Fixture.with_repo (fun repo ->
    let t = create ~placement:Tab repo.work in
    let t = run t " vxp" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    let t = Helpers.run ~width ~height t (List.map jobs ~f:(fun job -> Ui_state.Input.Vcs (finished job))) in
    show t;
    [%expect {| focused document; tabs [a.txt *note.txt Desk (2)]; note.txt: "read back 1\n" line 1 |}];
    (* Started from the view, finished while the editor has focus: nothing opens. *)
    let t = run t " vxp vx" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    let t = Helpers.run ~width ~height t (List.map jobs ~f:(fun job -> Ui_state.Input.Vcs (finished job))) in
    show t;
    print_log t;
    printf "disk %s\n" (disk (Fixture.path repo "note.txt"));
    [%expect {|
      focused document; tabs [a.txt *note.txt Desk (4)]; note.txt: "read back 1\n" line 1
      log: read; finished; read; finished
      disk "read back 1\n"
      |}])
;;

let%expect_test "save writes the buffer before the jobs go out; a failed save drops them" =
  Fixture.with_repo (fun repo ->
    let message t = scrub repo (message t) in
    let note = Fixture.path repo "note.txt" in
    let t = create ~placement:Tab repo.work in
    (* From the note's buffer, dirty: written as it is, then the job is submitted. *)
    let t = run t " vxoAX<Esc> kw" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    show t;
    printf "disk %s; jobs %d; %s\n" (disk note) (List.length jobs) (message t);
    [%expect {|
      focused document; tabs [a.txt *note.txt Desk (2)]; note.txt: "version 1\nsecond lineX\n" line 2
      disk "version 1\nsecond lineX\n"; jobs 1; Wrote $DIR/work/note.txt (23 bytes)
      |}];
    (* Clean: written again all the same (a [Saved] signal names it). *)
    let t, _ = Ui_state.take_source_requests t in
    let t = run t " kw" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    printf "saved %s; jobs %d\n"
      (String.concat ~sep:","
         (List.map (Ches_app.Session.saved (Ui_state.session t))
            ~f:(fun (saved : Controller.Saved.t) -> Filename.basename saved.path)))
      (List.length jobs);
    [%expect {| saved note.txt; jobs 1 |}];
    (* The file deleted under the buffer: the save fails, nothing is submitted, and the
       view hears its job never started. *)
    Core_unix.unlink note;
    let t = run t " kw" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    printf "jobs %d; %s\n" (List.length jobs) (message t);
    print_log t;
    [%expect {|
      jobs 0; Desk: Missing backing file: text retained; recreate it or save as; nothing ran
      log: open version 1; request: save; request: save; request: save; finished (never started)
      |}]);
  (* No buffer for the path at all. *)
  Fixture.with_repo (fun repo ->
    let message t = scrub repo (message t) in
    let t = create ~placement:Tab ~save_target:(Fixture.path repo "elsewhere.txt") repo.work in
    let t = run t " vxs" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    printf "jobs %d; %s | footer %s\n" (List.length jobs) (message t)
      (scrub repo (Option.value (Ui_state.capture_notice t) ~default:"-"));
    print_log t;
    [%expect {|
      jobs 0; Desk: $DIR/work/elsewhere.txt is not open in a buffer; nothing ran | footer Desk: $DIR/work/elsewhere.txt is not open in a buffer; nothing ran
      log: key: save; finished (never started)
      |}])
;;

let%expect_test "dispose closes the buffer, deletes the file, and returns the user to the view" =
  let scenario ?(keys = " kd") placement =
    Fixture.with_repo (fun repo ->
      let note = Fixture.path repo "note.txt" in
      let t = create ~placement:Tab repo.work in
      let t = run t " vxo" in
      let t =
        match (placement : View_registry.Placement.t) with
        | Tab -> t
        | other ->
          run
            t
            (match other with
             | Split -> " vx ss vx"
             | Hidden -> " vx sh"
             | Band | Tab -> " vx sb vx")
      in
      (* Dirty: discarded without a question. *)
      let t = run t ("ix<Esc>" ^ keys) in
      show t;
      printf "disk %s; %s\n" (disk note) (message t))
  in
  scenario Tab;
  [%expect {|
    focused desk; tabs [a.txt *Desk (2)]; a.txt: "alpha\n" line 1
    disk (none); (none)
    |}];
  scenario Split;
  [%expect {|
    focused desk; tabs [*a.txt]; a.txt: "alpha\n" line 1
    disk (none); (none)
    |}];
  scenario Hidden;
  [%expect {|
    focused document; tabs [*a.txt]; a.txt: "alpha\n" line 1
    disk (none); (none)
    |}];
  (* From the view, the note being the active file under its tab: nothing moves. *)
  Fixture.with_repo (fun repo ->
    let note = Fixture.path repo "note.txt" in
    let t = create ~placement:Tab repo.work in
    let t = run t " vxo vxd" in
    show t;
    printf "disk %s\n" (disk note);
    [%expect {|
      focused desk; tabs [a.txt *Desk (2)]; a.txt: "alpha\n" line 1
      disk (none)
      |}])
;;
