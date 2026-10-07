open! Core
open Ches_core

type fingerprint = int * int * Core_unix.file_kind * int64 * float * float
let fingerprint path =
  let s = Core_unix.lstat path in
  s.st_dev, s.st_ino, s.st_kind, s.st_size, s.st_mtime, s.st_ctime
;;

type t =
  { id : Buffer_id.t
  ; path : string
  ; entries : Directory_identity.Entry.t list
  ; baseline : Directory_identity.t
  ; controller : Controller.t
  ; next_entry : int
  ; fingerprints : fingerprint String.Map.t
  ; parent_identity : int * int
  ; marks : Int.Set.t
  }

let is_directory path =
  try Poly.equal (Core_unix.stat path).st_kind Core_unix.S_DIR with _ -> false
;;

let load ?previous ~id ~path ~cell_width ~keymap_config () =
  Or_error.try_with (fun () ->
    if Option.exists previous ~f:(fun t -> Editor.is_dirty (Controller.editor t.controller))
    then failwith "Directory has unsaved edits; undo them before refreshing";
    if not (is_directory path) then failwith ("Not a directory: " ^ path);
    let names = Stdlib.Sys.readdir path |> Array.to_list |> List.sort ~compare:String.compare in
    let next = ref (Option.value_map previous ~default:1 ~f:(fun t -> t.next_entry)) in
    let fingerprints = ref String.Map.empty in
    let entries = List.map names ~f:(fun name ->
      let stat = Core_unix.lstat (Filename.concat path name) in
      let fingerprint = fingerprint (Filename.concat path name) in
      fingerprints := Map.set !fingerprints ~key:name ~data:fingerprint;
      let kind = match stat.st_kind with
        | S_REG -> Directory_identity.Kind.File
        | S_DIR -> Directory
        | S_LNK -> Symlink
        | _ -> Unsupported in
      let old = Option.bind previous ~f:(fun t -> List.find t.entries ~f:(fun e ->
        String.equal e.name name && Directory_identity.Kind.equal e.kind kind
        && Option.value_map (Map.find t.fingerprints name) ~default:false ~f:(Poly.equal fingerprint))) in
      let entry_id = Option.value_map old ~default:0 ~f:(fun e -> e.id) in
      let entry_id = if entry_id > 0 then entry_id else (let n = !next in incr next; n) in
      { Directory_identity.Entry.id = entry_id; name; kind }) in
    let baseline = Directory_identity.create entries |> Or_error.ok_exn in
    let controller = Controller.create ~keymap_config ~kind:Directory
      (Editor.create ~path ~cell_width (Directory_identity.text baseline)) in
    let controller = match previous with
      | None -> controller
      | Some old ->
        let index = Editor.cursor_line (Controller.editor old.controller) in
        let selected = Directory_identity.parse old.baseline (Editor.text (Controller.editor old.controller))
          |> Result.ok |> Option.bind ~f:(fun rows -> List.find rows ~f:(fun r -> r.line = index))
          |> Option.bind ~f:(fun r -> match r.identity with Existing id -> Some id | Fresh -> None) in
        let index = Option.value (List.findi entries ~f:(fun _ e -> Option.equal Int.equal selected (Some e.id)) |> Option.map ~f:fst)
          ~default:(Int.min index (Int.max 0 (List.length entries - 1))) in
        Controller.jump controller ~line:(index + 1) ~column:1 |> Or_error.ok_exn in
    let marks = Option.value_map previous ~default:Int.Set.empty ~f:(fun t ->
      Set.filter t.marks ~f:(fun id -> List.exists entries ~f:(fun e -> e.id = id))) in
    let parent = Core_unix.stat path in
    { id; path; entries; baseline; controller; next_entry = !next; fingerprints = !fingerprints; marks
      ; parent_identity = parent.st_dev, parent.st_ino })
;;

let rows t = Directory_identity.parse t.baseline (Editor.text (Controller.editor t.controller))
let plan t = Directory_plan.plan t.entries (Editor.text (Controller.editor t.controller))
let is_dirty t = Editor.is_dirty (Controller.editor t.controller)
let backing_entry t row = match row.Directory_identity.Row.identity with
  | Fresh -> None
  | Existing id -> List.find t.entries ~f:(fun e -> e.id = id)
let current_rows t = Result.ok (rows t) |> Option.value ~default:[]

let select t name =
  match List.find (current_rows t) ~f:(fun row -> Option.exists (backing_entry t row) ~f:(fun e -> String.equal e.name name)) with
  | None -> t
  | Some row -> { t with controller = Controller.jump t.controller ~line:(row.line + 1) ~column:1 |> Or_error.ok_exn }
;;

let row_at t line = List.find (current_rows t) ~f:(fun row -> row.line = line)
let selected_row t = row_at t (Editor.cursor_line (Controller.editor t.controller))
let selected t = Option.bind (selected_row t) ~f:(backing_entry t)

let selection_rows t =
  let editor = Controller.editor t.controller in
  match Editor.selection editor with
  | None -> Option.to_list (selected_row t)
  | Some selection ->
    let text = Editor.text editor in
    let first = Text_buffer.line_of_offset text (Int.min selection.anchor selection.active) in
    let last = Text_buffer.line_of_offset text (Int.max selection.anchor selection.active) in
    List.filter (current_rows t) ~f:(fun row -> row.line >= first && row.line <= last)
;;

let selection_entries t = List.filter_map (selection_rows t) ~f:(backing_entry t)
let marked_entries t = List.filter_map (current_rows t) ~f:(fun row ->
  Option.filter (backing_entry t row) ~f:(fun e -> Set.mem t.marks e.id))

let mark_selection t ~marked =
  { t with marks = List.fold (selection_entries t) ~init:t.marks ~f:(fun marks e ->
      if marked then Set.add marks e.id else Set.remove marks e.id) }
;;

let toggle_mark t = match selected t with
  | None -> t
  | Some e -> { t with marks = if Set.mem t.marks e.id then Set.remove t.marks e.id else Set.add t.marks e.id }
;;

(** Save/reload are session-owned: never dispatch listing text as file IO. *)
let allows = function
  | Ches_core.Command.Save | Reload | Quit | Force_quit -> false
  | _ -> true
