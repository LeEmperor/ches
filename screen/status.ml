open! Core
open Ches_core
open Ches_input
open Ches_app

let fields ui : Status_field.t list =
  let editor = Controller.editor (Ui_state.controller ui) in
  let keymap = Controller.keymap (Ui_state.controller ui) in
  let field ?(fit = Status_field.Whole) ?(side = Status_field.Left) id ~priority spans =
    Some { Status_field.id; spans; priority; fit; side }
  in
  let mode =
    let mode = Editor.mode editor in
    let label = if Option.is_some (Session.input_directory (Ui_state.session ui))
      then (if Mode.equal mode Normal then " DIRECTORY " else sprintf " DIRECTORY %s " (Mode.to_string mode))
      else sprintf " %s " (Mode.to_string mode) in
    field Mode ~priority:0 [ Span.create (Mode mode) label ~width:(String.length label) ]
  in
  let filename =
     Option.bind (Controller.display_path (Ui_state.controller ui)) ~f:(fun path ->
      let path = if Option.is_some (Session.input_directory (Ui_state.session ui))
        then Directory_identity.encode_name path else path in
      field
        Filename
        ~priority:5
        ~fit:Cut_left
        (Span.of_text path ~style:Status ~special:Status_special))
  in
  let dirty =
    if Controller.is_missing (Ui_state.controller ui) then field Dirty ~priority:1 [ Span.create Dirty "[missing]" ~width:9 ]
    else if Editor.is_dirty editor
    then field Dirty ~priority:3 [ Span.create Dirty "[+]" ~width:3 ]
    else None
  in
  let message =
    Option.bind (Ui_state.message ui) ~f:(fun { kind; text } ->
      field
        Message
        ~priority:
          (match kind with
           | Error -> 1
           | Info | Warning ->
             if Problems.count (Controller.feedback (Ui_state.controller ui)) = 0
             then 6
             else 1)
        ~fit:Cut_right
        (Span.of_text
           text
           ~style:
             (match kind with
              | Info -> Info
              | Warning -> Warning
              | Error -> Error)
           ~special:Status_special))
  in
  let pending =
    Option.bind (Keymap.pending keymap) ~f:(fun keys ->
      field
        Pending
        ~priority:2
        ~side:Right
        (Span.of_text keys ~style:Pending ~special:Status_special))
  in
  let position =
    let s =
      sprintf "%d:%d" (Editor.cursor_line editor + 1) (Editor.cursor_column editor + 1)
    in
    field
      Position
      ~priority:4
      ~side:Right
      [ Span.create Status s ~width:(String.length s) ]
  in
  List.filter_opt [ mode; filename; dirty; message; pending; position ]
;;

(* Fields that are shown cut must keep at least this many cells. *)
let min_cut_width = 4

(* Gives [available] cells to [fields] in priority order, each taking a separator cell
   before it, and returns the spans of those shown. Once a field does not fit (after
   cutting, where allowed), every field of lower priority is dropped too. *)
let allocate (fields : Status_field.t list) ~available ~marker_style =
  List.stable_sort fields ~compare:(fun (a : Status_field.t) b ->
    Int.compare a.priority b.priority)
  |> List.fold_until
       ~init:([], available)
       ~f:(fun (shown, remaining) ({ id; spans; fit; _ } : Status_field.t) ->
         let available = remaining - 1 in
         let width = Span.total_width spans in
         if width <= available
         then Continue ((id, spans) :: shown, available - width)
         else (
           match fit with
           | Whole -> Stop shown
           | (Cut_left | Cut_right) when available < min_cut_width -> Stop shown
           | Cut_left ->
             Stop ((id, Span.keep_right spans ~n:available ~marker_style) :: shown)
           | Cut_right ->
             Stop ((id, Span.keep_left spans ~n:available ~marker_style) :: shown)))
       ~finish:fst
;;

(* The shown fields of [fields] on [side] (any side if [None]), in [fields]' order, each
   after a separator cell in [style]. *)
let place (fields : Status_field.t list) shown ?side style =
  List.concat_map fields ~f:(fun field ->
    match List.Assoc.find shown field.id ~equal:Status_field.Id.equal with
    | None -> []
    | Some spans ->
      (match side, field.side with
       | None, _ | Some Status_field.Left, Left | Some Right, Right ->
         Span.blank style 1 :: spans
       | Some Left, Right | Some Right, Left -> []))
;;

let status_row (fields : Status_field.t list) ~width : Span.t list =
  let lead =
    List.min_elt fields ~compare:(fun (a : Status_field.t) b ->
      Int.compare a.priority b.priority)
  in
  let lead_spans =
    match lead with
    | None -> []
    | Some lead -> Span.take lead.spans ~n:width
  in
  let lead_width = Span.total_width lead_spans in
  let rest =
    List.filter fields ~f:(fun field ->
      match lead with
      | Some lead -> not (Status_field.Id.equal field.id lead.id)
      | None -> true)
  in
  let shown =
    allocate rest ~available:(width - lead_width - 1) ~marker_style:Status_special
  in
  let left = lead_spans @ place rest shown ~side:Left Status in
  let right =
    place rest shown ~side:Right Status
    @ if width > lead_width then [ Span.blank Status 1 ] else []
  in
  let fill = width - Span.total_width left - Span.total_width right in
  Span.merge (left @ [ Span.blank Status fill ] @ right)
;;

let border_title (fields : Status_field.t list) ~width : Span.t list =
  let rule n =
    Span.create Border (String.concat (List.init n ~f:(fun _ -> "─"))) ~width:n
  in
  let to_title (span : Span.t) : Span.t =
    match span.style with
    | Status -> { span with style = Title }
    | Status_special -> { span with style = Title_special }
    | _ -> span
  in
  let shown = allocate fields ~available:(width - 3) ~marker_style:Title_special in
  match place fields shown Title with
  | [] -> [ rule width ]
  | title ->
    let title = List.map title ~f:to_title @ [ Span.blank Title 1 ] in
    Span.merge ((rule 1 :: title) @ [ rule (width - 1 - Span.total_width title) ])
;;

let render ({ rect; layout; fields = ids } : Geometry.Area.t) fields =
  let fields =
    List.filter_map ids ~f:(fun id ->
      List.find fields ~f:(fun (field : Status_field.t) ->
        Status_field.Id.equal field.id id))
  in
  let width = Int.max 0 rect.width in
  match layout with
  | Status_row -> status_row fields ~width
  | Border_title -> border_title fields ~width
;;

module Tile = struct
  type t =
    { rect : Geometry.Rect.t
    ; rows : Span.t list list
    }
  [@@deriving sexp_of]
end

let vertical ~(rect : Geometry.Rect.t) (fields : Status_field.t list) : Tile.t =
  let rect = { rect with width = Int.max 0 rect.width; height = Int.max 0 rect.height } in
  let find id = List.find fields ~f:(fun field -> Status_field.Id.equal field.id id) in
  let mode = find Mode
  and filename = find Filename
  and dirty = find Dirty
  and position = find Position
  and pending = find Pending
  and message = find Message in
  let fit ?(marker_style = Style.Status_special) spans =
    Span.keep_left spans ~n:rect.width ~marker_style
  in
  let mode =
    Option.map mode ~f:(fun field ->
      (* The horizontal badge's outside spaces are not useful in a narrow cell. *)
      let spans =
        List.concat_map field.spans ~f:(fun span ->
          Span.of_text (String.strip span.text) ~style:span.style ~special:Status_special)
      in
      0, Span.take spans ~n:rect.width)
  in
  let file =
    match filename, dirty with
    | None, None -> None
    | filename, dirty ->
      let dirty_spans =
        Option.value_map dirty ~default:[] ~f:(fun field ->
          Span.keep_left field.spans ~n:rect.width ~marker_style:Dirty)
      in
      let dirty_width = Span.total_width dirty_spans in
      let filename_width =
        Int.max 0 (rect.width - dirty_width - if dirty_width > 0 then 1 else 0)
      in
      let filename_spans =
        Option.value_map filename ~default:[] ~f:(fun field ->
          Span.keep_right field.spans ~n:filename_width ~marker_style:Status_special)
      in
      let separator =
        if Span.total_width filename_spans > 0 && dirty_width > 0
        then [ Span.blank Status 1 ]
        else []
      in
      Some
        ((if Option.is_some dirty then 3 else 4), filename_spans @ separator @ dirty_spans)
  in
  let row ?marker_style priority field =
    Option.map field ~f:(fun field ->
      priority, fit ?marker_style field.Status_field.spans)
  in
  let message =
    Option.map message ~f:(fun field ->
      let marker_style = if field.priority <= 1 then Style.Error else Status_special in
      field.priority, fit ~marker_style field.spans)
  in
  let candidates =
    List.filter_opt
      [ mode; file; row 5 position; row ~marker_style:Pending 2 pending; message ]
  in
  let chosen =
    List.mapi candidates ~f:(fun order (priority, spans) -> order, priority, spans)
    |> List.stable_sort ~compare:(fun (_, a, _) (_, b, _) -> Int.compare a b)
    |> Fn.flip List.take rect.height
    |> List.sort ~compare:(fun (a, _, _) (b, _, _) -> Int.compare a b)
    |> List.map ~f:(fun (_, _, spans) ->
      Span.merge (spans @ [ Span.blank Status (rect.width - Span.total_width spans) ]))
  in
  let blank = Span.merge [ Span.blank Status rect.width ] in
  { rect
  ; rows = chosen @ List.init (rect.height - List.length chosen) ~f:(fun _ -> blank)
  }
;;
