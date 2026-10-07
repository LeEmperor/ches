open! Core
open Ches_content_picker
module Selection = Ches_tile.Navigation.Selection
let id = Ches_tile.View_id.of_string "content-picker"
let spec = Ches_tile.Spec.text_input id ~title:"On-disk literal search"
type 'token t = { session : 'token Model.t; mutable view : Model.hit Selection.t }
let create ~token ~snapshot = { session = Model.create ~token snapshot; view = Selection.empty }
let session t = t.session
let view t = t.view
let fit t ~rows =
  t.view <- Selection.fit { t.view with selected = Model.selected t.session }
    (Model.snapshot t.session).hits ~equal:Model.same_hit ~rows:(Int.max 1 (rows - 2))
;;
type action = Event of Ches_palette.Palette.Event.t | Accept [@@deriving sexp_of]
let interpret keys =
  match Palette_tile.interpret keys with
  | Action (Event event) -> Ches_tile.Content_key.Action (Event event)
  | Action Accept -> Action Accept
  | Prefix -> Prefix
  | Unbound -> Unbound
;;
let update t ~rows event = Model.update t.session event; fit t ~rows
let expect t request = Model.expect t.session request
let install t snapshot = Model.install t.session snapshot
let accept t ~release ~consume = Model.accept t.session ~release ~consume
let cancel t ~release = Model.cancel t.session ~release
let cursor t ~width = Picker_text.cursor (Model.query t.session) ~width
let safe = Model.Candidate.display_text
let search_status t =
  if Model.pending t.session then "Query changed; waiting for on-disk search (Enter disabled)"
  else if String.is_empty (Model.query t.session) then "Type a literal; empty query does not search"
  else match (Model.snapshot t.session).status with
    | Loading -> "Searching on disk..."
    | Partial -> "Searching on disk (partial)"
    | Complete { truncated = true } -> "TRUNCATED: search limit reached; not all matches shown"
    | Complete { truncated = false } -> "On-disk literal search complete"
    | Failed message -> "Search failed: " ^ safe message
    | Cancelled -> "Search cancelled"
;;
let status t =
  (if Model.query_truncated t.session then "QUERY TRUNCATED at 4 KiB | " else "")
  ^ search_status t
;;
let result_row (hit : Model.hit) ~selected ~width =
  let text = Option.value (String.chop_suffix hit.text ~suffix:"\n") ~default:hit.text in
  let before = String.sub text ~pos:0 ~len:hit.start_byte |> safe in
  let matched = String.sub text ~pos:hit.start_byte ~len:(hit.end_byte - hit.start_byte) |> safe in
  let after = String.drop_prefix text hit.end_byte |> safe in
  let spans =
    Span.of_text (if selected then "> " else "  ") ~style:Pending ~special:Status_special
    @ Span.of_text (sprintf "%s:%d:%d | " (Model.Candidate.display_path hit.candidate)
                      hit.line (hit.start_byte + 1)) ~style:Status ~special:Status_special
    @ Span.of_text before ~style:Status ~special:Status_special
    @ Span.of_text matched ~style:Pending ~special:Status_special
    @ Span.of_text after ~style:Status ~special:Status_special in
  let spans = Span.keep_left spans ~n:(Int.max 0 width) ~marker_style:Status_special in
  Span.merge (spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ])
;;
let render ?notice t ~width ~rows : Tile_shell.Content.t =
  fit t ~rows;
  let snapshot = Model.snapshot t.session in
  let count = List.length snapshot.hits in
  let summary = status t in
  let results =
    if count = 0 then [ Tile_text.row Stale
      (if String.is_empty (Model.query t.session) then "No search requested"
       else "No on-disk matches available") ~width ]
    else List.take (List.drop snapshot.hits t.view.top) (Int.max 0 (rows - 2))
      |> List.mapi ~f:(fun i hit -> result_row hit ~selected:(t.view.top + i = t.view.index) ~width) in
  let query = Picker_text.query_row (Model.query t.session) ~width in
  let query = query @ [ Span.blank Status (Int.max 0 (width - Span.total_width query)) ] in
  { title = "Literal search | ON DISK (excludes unsaved edits) | " ^ safe snapshot.request.root
   ; footer = Some (Tile_shell.Label.hint
       (Option.value notice ~default:(sprintf "%d matches | columns are 1-based BYTES, not cells | %s | Ctrl-n/p, Enter, Esc" count summary)))
  ; body = List.take (query :: Tile_text.row Stale summary ~width :: results) (Int.max 0 rows) }
;;
