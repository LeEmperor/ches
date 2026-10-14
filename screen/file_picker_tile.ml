open! Core
open Ches_file_picker
module Selection = Ches_tile.Navigation.Selection
module Preview = Ches_file_preview_model.Model

let id = Ches_tile.View_id.of_string "file-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Files"

type 'token t =
  { session : 'token Interaction.t
  ; mutable view : Model.Candidate.Id.t Selection.t
  ; mutable expected : Preview.request option
  ; mutable preview : Preview.snapshot option
  ; mutable preview_revision : int
  }

let create ~token ~discovery =
  { session = Interaction.create ~token ~discovery; view = Selection.empty
  ; expected = None; preview = None; preview_revision = 0 }
;;

let session t = t.session
let view t = t.view
let preview t = t.preview
let visible_stamp t = Interaction.instance t.session, Interaction.visible_revision t.session, t.preview_revision
let expect_preview t expected =
  if not (Option.equal Preview.equal_request t.expected expected) then (
    t.preview_revision <- t.preview_revision + 1; t.preview <- None);
  t.expected <- expected
;;
let clear_preview t =
  if Option.is_some t.expected || Option.is_some t.preview then t.preview_revision <- t.preview_revision + 1;
  t.expected <- None; t.preview <- None
let install_preview t snapshot =
  let model = Interaction.model t.session in
  if Preview.accept ~expected:t.expected snapshot
      && Model.Discovery.equal_request (Model.discovery_request model) snapshot.request.session
     && Option.equal Model.Candidate.Id.equal (Model.selected model) (Some snapshot.request.selected)
  then (
    if not (Option.exists t.preview ~f:(fun previous ->
      Preview.equal_snapshot previous snapshot)) then (
      t.preview_revision <- t.preview_revision + 1; t.preview <- Some snapshot);
    true) else false
;;

(* Minimum useful results/preview widths; the separator has three cells. *)
let columns ~width =
  if width < 96 then width, None
  else let left = (width - 3) / 2 in left, Some (width - left - 3)
;;

let fit t ~rows =
  let model = Interaction.model t.session in
  let count = Model.result_count model in
  let index = Option.value (Model.selected_index model) ~default:0 in
  let rows = Int.max 1 (rows - 2) in
  let top = Int.min t.view.top (Int.max 0 (count - rows)) in
  let top = if index < top then index else if index >= top + rows then index - rows + 1 else top in
  t.view <- { selected = Model.selected model; index; top }
;;

type action = Event of Ches_palette.Palette.Event.t | Accept [@@deriving sexp_of]

let interpret keys =
  match Palette_tile.interpret keys with
  | Action (Event event) -> Ches_tile.Content_key.Action (Event event)
  | Action Accept -> Action Accept
  | Prefix -> Prefix
  | Unbound -> Unbound
;;

let update t ~rows event = Interaction.update t.session event; fit t ~rows
let install t snapshot = Interaction.install t.session snapshot
let install_update t update = Interaction.install_update t.session update
let work t ~budget = Interaction.work t.session ~budget
let accept t ~release ~consume = Interaction.accept t.session ~release ~consume
let cancel t ~release = clear_preview t; Interaction.cancel t.session ~release
let cursor t ~width = Picker_text.cursor (Interaction.query t.session) ~width:(fst (columns ~width))

(* Escape all untrusted metadata using the exact same display boundary as paths. *)
let safe = Model.Candidate.display_text

let status t =
  let status = Model.discovery_status (Interaction.model t.session) in
  if Interaction.refreshing t.session then
    sprintf "Loading / refreshing cached files... %d discovered | Enter disabled" (Interaction.refresh_count t.session)
  else if Interaction.acceptance_blocked t.session then
    (match status with
     | Failed error -> "Refresh failed: " ^ safe error ^ " | Enter disabled; reopen to retry"
     | Complete { truncated = true } -> "TRUNCATED refresh | Enter disabled; reopen to retry"
     | _ -> "Validating refreshed files... | Enter disabled")
  else match status with
  | Loading -> "Loading files..."
  | Partial -> "Discovering files (partial)"
  | Complete { truncated = true } -> "TRUNCATED: discovery limit reached; not all files shown"
  | Complete { truncated = false } -> "Discovery complete"
  | Failed error -> "Discovery failed: " ^ safe error
  | Cancelled -> "Discovery cancelled"
;;

let result_row (result : Model.Query_result.t) ~selected ~width =
  let marker = Span.of_text (if selected then "> " else "  ") ~style:Pending ~special:Status_special in
  let path = Picker_text.matched_text (Model.Candidate.display_path result.candidate) ~positions:result.positions in
  Span.keep_left (marker @ path) ~n:(Int.max 0 width) ~marker_style:Status_special
  |> fun spans -> Span.merge (spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ])
;;

let render_results ~hotkey_hints ?notice t ~width ~rows : Tile_shell.Content.t =
  fit t ~rows;
  let model = Interaction.model t.session in
  let discovery_status = Model.discovery_status model in
  let count = Model.result_count model in
  let busy = Interaction.busy t.session in
  let summary = status t ^ if busy then " | Filtering... (Enter waits)" else "" in
  let list =
    if count = 0 then
      [ Tile_text.row Stale
          (if busy then "Filtering files..."
            else match discovery_status with
             | Loading -> "Waiting for discovery"
             | Complete { truncated = false } when Model.discovered_count model = 0 -> "No project files"
             | Complete { truncated = true } when Model.discovered_count model = 0 ->
               "No files available within discovery limits"
             | Failed _ when Model.discovered_count model = 0 -> "No files available"
             | Cancelled -> "Discovery cancelled"
             | _ -> "No matching files") ~width ]
    else Model.result_slice model ~start:t.view.top ~length:(Int.max 0 (rows - 2))
      |> List.mapi ~f:(fun i result -> result_row result ~selected:(t.view.top + i = t.view.index) ~width)
  in
  let query = Picker_text.query_row (Interaction.query t.session) ~width in
  let query = query @ [ Span.blank Status (Int.max 0 (width - Span.total_width query)) ] in
  { title = "Files | " ^ safe (Model.discovery_request model).root
  (* When requested, keep controls ahead of duplicated discovery metadata so
     narrow layouts still show key guidance. Status is independent of hints. *)
  ; footer = Some (Tile_shell.Label.hint
      (Option.value_map notice ~default:"" ~f:(fun text -> text ^ " | ")
       ^ sprintf "%d/%d matches%s | %d discovered | %s"
         (if count = 0 then 0 else t.view.index + 1) count
         (if hotkey_hints then " | Enter, Esc | Tab/Shift-Tab, Ctrl-n/p" else "")
         (Model.discovered_count model) summary))
  ; body = List.take (query :: Tile_text.row Stale summary ~width :: list) (Int.max 0 rows)
  }
;;

let preview_rows t ~width ~rows =
  let row style text = Tile_text.row style text ~width in
  let model = Interaction.model t.session in
  let filename = Option.map (Model.selected_candidate model) ~f:Model.Candidate.display_path in
  let title = row Pending ("Preview | " ^ Option.value filename ~default:"No selection") in
  let source = function Preview.Disk -> "disk" | Buffer { revision } -> sprintf "buffer r%d" revision in
  let state = Option.map t.preview ~f:(fun snapshot -> snapshot.Preview.state) in
  let status, lines = match state with
    | None -> (if Option.is_some filename then "Loading..." else "No selected file"), []
    | Some Loading -> "Loading...", []
    | Some (Ready payload) -> "Read-only | " ^ source payload.source, payload.lines
    | Some (Truncated (payload, cap)) ->
      "TRUNCATED | " ^ source payload.source
      ^ (if cap.bytes then " | 64 KiB" else "")
      ^ (if cap.lines then " | 100 lines" else "")
      ^ (if cap.utf8_boundary then " | UTF-8 boundary" else ""), payload.lines
    | Some (Empty origin) -> "Empty file | " ^ source origin, []
    | Some Missing -> "File missing", []
    | Some (Unreadable error) -> "Unreadable: " ^ error, []
    | Some (Unsupported Binary) -> "Unsupported binary file", []
    | Some (Unsupported Encoding) -> "Unsupported encoding", []
    | Some (Unsupported Special_file) -> "Unsupported non-regular file", [] in
  (* Only visible prefix rows are mapped to display cells. Cell_map escapes controls,
     expands tabs and clips wide UTF-8 glyphs without emitting raw terminal bytes. *)
  let lines = List.take lines (Int.max 0 (rows - 2))
    |> List.mapi ~f:(fun i text ->
      let number = Span.of_text (sprintf "%3d " (i + 1)) ~style:Stale ~special:Status_special in
      let glyphs = Cell_map.glyphs text in
      number @ Span.of_glyphs glyphs ~left:0 ~cols:(Int.max 0 (width - 4))
        ~text:Status ~special:Status_special) in
  List.take (title :: row Stale status :: lines) (Int.max 0 rows)
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows =
  let left, right = columns ~width in
  let content = render_results ~hotkey_hints ?notice t ~width:left ~rows in
  match right with
  | None -> content
  | Some right ->
    let preview = preview_rows t ~width:right ~rows in
    let at rows index width = Option.value (List.nth rows index) ~default:[ Span.blank Status width ] in
    { content with body = List.init (Int.max 0 rows) ~f:(fun i ->
        at content.body i left @ Span.of_text " | " ~style:Stale ~special:Status_special
        @ at preview i right) }
;;
