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
    let label = sprintf " %s " (Mode.to_string mode) in
    field Mode ~priority:0 [ Span.create (Mode mode) label ~width:(String.length label) ]
  in
  let filename =
    Option.bind (Editor.path editor) ~f:(fun path ->
      field
        Filename
        ~priority:5
        ~fit:Cut_left
        (Span.of_text path ~style:Status ~special:Status_special))
  in
  let dirty =
    if Editor.is_dirty editor
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
           | Info | Warning -> 6)
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
    field Position ~priority:4 ~side:Right [ Span.create Status s ~width:(String.length s) ]
  in
  List.filter_opt [ mode; filename; dirty; message; pending; position ]
;;

(* Fields that are shown cut must keep at least this many cells. *)
let min_cut_width = 4

(* Gives [available] cells to [fields] in priority order, each taking a separator
   cell before it, and returns the spans of those shown. Once a field does not fit
   (after cutting, where allowed), every field of lower priority is dropped too. *)
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
           | Cut_left -> Stop ((id, Span.keep_right spans ~n:available ~marker_style) :: shown)
           | Cut_right -> Stop ((id, Span.keep_left spans ~n:available ~marker_style) :: shown)))
       ~finish:fst
;;

(* The shown fields of [fields] on [side] (any side if [None]), in [fields]' order,
   each after a separator cell in [style]. *)
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
  let rule n = Span.create Border (String.concat (List.init n ~f:(fun _ -> "─"))) ~width:n in
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
      List.find fields ~f:(fun (field : Status_field.t) -> Status_field.Id.equal field.id id))
  in
  let width = Int.max 0 rect.width in
  match layout with
  | Status_row -> status_row fields ~width
  | Border_title -> border_title fields ~width
;;
