open! Core
open Ches_file_picker
module Selection = Ches_tile.Navigation.Selection

let id = Ches_tile.View_id.of_string "file-picker"
let spec = Ches_tile.Spec.text_input id ~title:"Files"

type 'token t =
  { session : 'token Interaction.t
  ; mutable view : Model.Candidate.Id.t Selection.t
  }

let create ~token ~discovery =
  { session = Interaction.create ~token ~discovery; view = Selection.empty }
;;

let session t = t.session
let view t = t.view

let fit t ~rows =
  let model = Interaction.model t.session in
  let ids = List.map (Model.results model) ~f:(fun r -> Model.Candidate.id r.candidate) in
  t.view <- Selection.fit { t.view with selected = Model.selected model }
    ids ~equal:Model.Candidate.Id.equal ~rows:(Int.max 1 (rows - 2))
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
let work t ~budget = Interaction.work t.session ~budget
let accept t ~release ~consume = Interaction.accept t.session ~release ~consume
let cancel t ~release = Interaction.cancel t.session ~release
let cursor t ~width = Picker_text.cursor (Interaction.query t.session) ~width

(* Escape all untrusted metadata using the exact same display boundary as paths. *)
let safe = Model.Candidate.display_text

let status t =
  match (Model.discovery (Interaction.model t.session)).status with
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

let render t ~width ~rows : Tile_shell.Content.t =
  fit t ~rows;
  let model = Interaction.model t.session in
  let discovery = Model.discovery model in
  let results = Model.results model in
  let count = List.length results in
  let busy = Interaction.busy t.session in
  let summary = status t ^ if busy then " | Filtering... (Enter waits)" else "" in
  let list =
    if count = 0 then
      [ Tile_text.row Stale
          (if busy then "Filtering files..."
           else match discovery.status with
             | Loading -> "Waiting for discovery"
             | Complete { truncated = false } when List.is_empty discovery.candidates -> "No project files"
             | Complete { truncated = true } when List.is_empty discovery.candidates ->
               "No files available within discovery limits"
             | Failed _ when List.is_empty discovery.candidates -> "No files available"
             | Cancelled -> "Discovery cancelled"
             | _ -> "No matching files") ~width ]
    else List.take (List.drop results t.view.top) (Int.max 0 (rows - 2))
      |> List.mapi ~f:(fun i result -> result_row result ~selected:(t.view.top + i = t.view.index) ~width)
  in
  let query = Picker_text.query_row (Interaction.query t.session) ~width in
  let query = query @ [ Span.blank Status (Int.max 0 (width - Span.total_width query)) ] in
  { title = "Files | " ^ safe discovery.request.root
  ; footer = Some (Tile_shell.Label.hint (sprintf "%d/%d matches | %d discovered | %s | Ctrl-n/p, Enter, Esc"
      (if count = 0 then 0 else t.view.index + 1) count (List.length discovery.candidates) summary))
  ; body = List.take (query :: Tile_text.row Stale summary ~width :: list) (Int.max 0 rows)
  }
;;
