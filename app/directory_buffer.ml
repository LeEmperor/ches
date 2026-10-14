open! Core
open Ches_core

module Config = struct
  type t = Hidden | Exposed [@@deriving sexp_of, equal]
  let default = Hidden
end

let next_scope = ref 0
let new_scope path =
  incr next_scope;
  path ^ ":" ^ Int.to_string !next_scope
;;

type fingerprint = int * int * Core_unix.file_kind * int64 * float * float
let fingerprint path =
  let s = Core_unix.lstat path in
  s.st_dev, s.st_ino, s.st_kind, s.st_size, s.st_mtime, s.st_ctime
;;
let same_identity (dev, ino, kind, _, _, _) (dev', ino', kind', _, _, _) =
  dev = dev' && ino = ino' && Poly.equal kind kind'
;;

module Parsed_cache = struct
  type snapshot =
    { text : Text_buffer.t
    ; baseline : Directory_identity.t
    ; entries : Directory_identity.Entry.t list
    ; rows : Directory_identity.Row.t list Or_error.t
    ; by_line : Directory_identity.Row.t option array
    ; by_id : Directory_identity.Entry.t Int.Map.t
    }
  type t = snapshot option ref
end

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
  ; config : Config.t
  ; identity_scope : string
  ; parsed_cache : Parsed_cache.t
  }

(* The shared one-slot memo is only an optimization: every access checks all
   immutable inputs. Older session snapshots may evict it, never read stale data.
   Text object identity includes protected anchors/scope, unlike visible bytes or
   controller revision alone (which can be reused by replacement/undo). *)
let parsed t =
  let text = Editor.text (Controller.editor t.controller) in
  match !(t.parsed_cache) with
  | Some cache when phys_equal cache.text text && phys_equal cache.baseline t.baseline
                    && phys_equal cache.entries t.entries -> cache
  | _ ->
    let rows = Directory_identity.parse t.baseline text in
    let by_line = Array.create ~len:(Text_buffer.line_count text) None in
    Result.iter rows ~f:(List.iter ~f:(fun row -> by_line.(row.Directory_identity.Row.line) <- Some row));
    let by_id = Int.Map.of_alist_exn (List.map t.entries ~f:(fun e -> e.Directory_identity.Entry.id, e)) in
    let cache = { Parsed_cache.text; baseline = t.baseline; entries = t.entries; rows; by_line; by_id } in
    t.parsed_cache := Some cache;
    cache
;;

let rows t = (parsed t).rows

let is_directory path =
  try Poly.equal (Core_unix.stat path).st_kind Core_unix.S_DIR with _ -> false
;;

let load ?previous ?(config = Config.default) ~id ~path ~cell_width ~keymap_config () =
  Or_error.try_with (fun () ->
    if Option.exists previous ~f:(fun t -> Editor.is_dirty (Controller.editor t.controller))
    then failwith "Directory has unsaved edits; save/retry or undo them before refreshing; explicit force-close discards remaining intent";
    if not (is_directory path) then failwith ("Not a directory: " ^ path);
    let names = Stdlib.Sys.readdir path |> Array.to_list |> List.sort ~compare:String.compare in
    let next = ref (Option.value_map previous ~default:1 ~f:(fun t -> t.next_entry)) in
    let previous_by_name = Option.value_map previous ~default:String.Map.empty ~f:(fun t ->
      String.Map.of_alist_exn (List.map t.entries ~f:(fun e -> e.Directory_identity.Entry.name, e))) in
    let fingerprints = ref String.Map.empty in
    let entries = List.map names ~f:(fun name ->
      let stat = Core_unix.lstat (Filename.concat path name) in
      let fingerprint = stat.st_dev, stat.st_ino, stat.st_kind, stat.st_size, stat.st_mtime, stat.st_ctime in
      fingerprints := Map.set !fingerprints ~key:name ~data:fingerprint;
      let kind = match stat.st_kind with
        | S_REG -> Directory_identity.Kind.File
        | S_DIR -> Directory
        | S_LNK -> Symlink
        | _ -> Unsupported in
      let old = Option.bind previous ~f:(fun t -> Option.filter (Map.find previous_by_name name) ~f:(fun e ->
        Directory_identity.Kind.equal e.kind kind
        && Option.value_map (Map.find t.fingerprints name) ~default:false ~f:(same_identity fingerprint))) in
      let entry_id = Option.value_map old ~default:0 ~f:(fun e -> e.id) in
      let entry_id = if entry_id > 0 then entry_id else (let n = !next in incr next; n) in
      { Directory_identity.Entry.id = entry_id; name; kind }) in
    let baseline = Directory_identity.create entries |> Or_error.ok_exn in
    let config = Option.value_map previous ~default:config ~f:(fun t -> t.config) in
    let identity_scope = match previous with Some t -> t.identity_scope | None -> new_scope path in
    let controller = Controller.create ~keymap_config ~kind:Directory
      (Editor.create ~path ~cell_width (Directory_identity.text ?scope:(if Config.equal config Hidden then Some identity_scope else None) baseline)) in
    let controller = match previous with
      | None -> controller
      | Some old ->
        let index = Editor.cursor_line (Controller.editor old.controller) in
        let selected = rows old
          |> Result.ok |> Option.bind ~f:(fun rows -> List.find rows ~f:(fun r -> r.line = index))
           |> Option.bind ~f:(fun r -> match r.identity with Existing id -> Some id | Fresh | Copy _ -> None) in
        let index = Option.value (List.findi entries ~f:(fun _ e -> Option.equal Int.equal selected (Some e.id)) |> Option.map ~f:fst)
          ~default:(Int.min index (Int.max 0 (List.length entries - 1))) in
        Controller.jump controller ~line:(index + 1) ~column:1 |> Or_error.ok_exn in
    let loaded_ids = Int.Set.of_list (List.map entries ~f:(fun e -> e.Directory_identity.Entry.id)) in
    let marks = Option.value_map previous ~default:Int.Set.empty ~f:(fun t ->
      Set.inter t.marks loaded_ids) in
    let parent = Core_unix.stat path in
    { id; path; entries; baseline; controller; next_entry = !next; fingerprints = !fingerprints; marks
       ; parent_identity = parent.st_dev, parent.st_ino; config; identity_scope
       ; parsed_cache = ref None })
;;

let plan t = Directory_plan.plan t.entries (Editor.text (Controller.editor t.controller))
let is_dirty t = Editor.is_dirty (Controller.editor t.controller)
let backing_entry t row = match row.Directory_identity.Row.identity with
  | Fresh | Copy _ -> None
  | Existing id -> Map.find (parsed t).by_id id
let current_rows t = Result.ok (rows t) |> Option.value ~default:[]

let select t name =
  match List.find (current_rows t) ~f:(fun row -> Option.exists (backing_entry t row) ~f:(fun e -> String.equal e.name name)) with
  | None -> t
  | Some row -> { t with controller = Controller.jump t.controller ~line:(row.line + 1) ~column:1 |> Or_error.ok_exn }
;;

let row_at t line =
  let by_line = (parsed t).by_line in
  if line < 0 || line >= Array.length by_line then None else by_line.(line)
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
