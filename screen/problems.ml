open! Core
open Ches_core
module Feedback = Ches_error.Error
module Diagnostics = Feedback.Diagnostics
module Selection = Ches_tile.Navigation.Selection

module Document = struct
  type t =
    { path : string option
    ; revision : int
    ; text : Text_buffer.t
    ; anchor_text : string -> Text_buffer.t option
    }

  let of_editor ?(anchor_text = fun _ -> None) editor =
    { path = Editor.path editor
    ; revision = Editor.revision editor
    ; text = Editor.text editor
    ; anchor_text
    }
  ;;

  let of_path path =
    { path; revision = 0; text = Text_buffer.empty; anchor_text = (fun _ -> None) }
  ;;

  let path t = t.path
  let is t resource = Option.value_map t.path ~default:false ~f:(String.equal resource)

  (* [line] is one-based, in the text [source]'s list was applied against. *)
  let line_text t ~source line =
    let text = Option.value (t.anchor_text source) ~default:t.text in
    if line >= 1 && line <= Text_buffer.line_count text
    then Some (Text_buffer.line_text text (line - 1))
    else None
  ;;
end

module Key = struct
  type anchor =
    [ `Text of string
    | `Line of int
    | `Nowhere
    ]
  [@@deriving sexp_of, equal]

  type t =
    | Problem of Feedback.Identity.t
    | Finding of
        { source : string
        ; severity : Feedback.Severity.t
        ; message : string
        ; anchor : anchor
        ; nth : int
        }
  [@@deriving sexp_of, equal]

  let identity = function
    | Problem identity -> Some identity
    | Finding _ -> None
  ;;
end

module Row = struct
  type kind =
    | Problem of Feedback.Problem.t
    | Finding of
        { stale : bool
        ; stopped : bool
        }
  [@@deriving sexp_of]

  type t =
    { key : Key.t
    ; severity : Feedback.Severity.t
    ; source : string
    ; resource : string
    ; location : Feedback.Problem.Location.t option
    ; text : string
    ; kind : kind
    }
  [@@deriving sexp_of]
end

let severity_rank : Feedback.Severity.t -> int = function
  | Error -> 0
  | Warning -> 1
  | Info -> 2
  | Hint -> 3
;;

let problem_row (p : Feedback.Problem.t) : Row.t =
  { key = Problem p.identity
  ; severity = p.severity
  ; source = p.identity.source
  ; resource = p.identity.resource
  ; location = p.location
  ; text = p.text
  ; kind = Problem p
  }
;;

(* Findings sorted by file, severity, then position; the stable sort keeps a source's
   own order (and sources' alphabetical order) for ties. *)
let finding_rows feedback ~document =
  let diagnostics = Feedback.diagnostics feedback in
  let findings =
    List.concat_map (Diagnostics.collections diagnostics) ~f:(fun c ->
      let stale =
        c.session_ended
        || (Document.is document c.resource
            && Diagnostics.Collection.behind c ~revision:document.revision)
      in
      let stopped = Diagnostics.stopped diagnostics ~source:c.source in
      List.map c.findings ~f:(fun f -> c, f, stale, stopped))
    |> List.stable_sort ~compare:(fun (a, (fa : Diagnostics.Finding.t), _, _) (b, fb, _, _) ->
      let position (f : Diagnostics.Finding.t) =
        Option.value_map f.location ~default:(0, 0) ~f:(fun l -> l.line, l.column)
      in
      [%compare: string * int * (int * int)]
        (a.Diagnostics.Collection.resource, severity_rank fa.severity, position fa)
        (b.resource, severity_rank fb.severity, position fb))
  in
  (* Count earlier identical keys so duplicates pair up in order. *)
  let seen = Hashtbl.Poly.create () in
  List.map findings ~f:(fun ((c : Diagnostics.Collection.t), (f : Diagnostics.Finding.t), stale, stopped) ->
    let anchor : Key.anchor =
      match f.location with
      | None -> `Nowhere
      | Some { line; _ } when Document.is document c.resource ->
        Option.value_map (Document.line_text document ~source:c.source line) ~default:(`Line line) ~f:(fun text ->
          `Text text)
      | Some { line; _ } -> `Line line
    in
    let base = c.source, f.severity, f.message, anchor in
    let nth = Option.value (Hashtbl.find seen base) ~default:0 in
    Hashtbl.set seen ~key:base ~data:(nth + 1);
    { Row.key = Finding { source = c.source; severity = f.severity; message = f.message; anchor; nth }
    ; severity = f.severity
    ; source = c.source
    ; resource = c.resource
    ; location = f.location
    ; text = f.message
    ; kind = Finding { stale; stopped }
    })
;;

let entries feedback ~current_document ~document =
  List.map (Feedback.problems feedback) ~f:problem_row @ finding_rows feedback ~document
  |> List.filter ~f:(fun (row : Row.t) ->
    (not current_document) || Document.is document row.resource)
;;

let count feedback =
  List.length (Feedback.problems feedback)
  + List.sum
      (module Int)
      (Diagnostics.collections (Feedback.diagnostics feedback))
      ~f:(fun c -> List.length c.findings)
;;

let description (row : Row.t) =
  let severity =
    match row.severity with
    | Hint -> "hint"
    | Info -> "info"
    | Warning -> "warning"
    | Error -> "error"
  in
  let stopped =
    match row.kind with
    | Finding { stopped = true; _ } -> " stopped"
    | Finding { stopped = false; _ } | Problem _ -> ""
  in
  let location =
    Option.value_map row.location ~default:"" ~f:(fun l -> sprintf ":%d:%d" l.line l.column)
  in
  sprintf "%s [%s%s] %s%s: %s" severity row.source stopped row.resource location row.text
;;

let style (row : Row.t) : Style.t =
  match row.kind, row.severity with
  | Finding { stale = true; _ }, _ -> Stale
  | _, Hint -> Severity_hint
  | _, Info -> Info
  | _, Warning -> Warning
  | _, Error -> Error
;;

let render ?(hotkey_hints = false) ?(focused = false) ?(navigation = Selection.empty)
  ?details ?notice ?pending
  feedback ~current_document ~document ~width ~rows : Tile_shell.Content.t =
  let total = count feedback in
  let entries = entries feedback ~current_document ~document in
  let count = List.length entries in
  let rows = Int.max 0 rows in
  let row style text = Tile_text.row style text ~width in
  let filter = if current_document then "document" else "workspace" in
  let empty = if count = 0 && rows > 0 then [ row Status "No active problems" ] else [] in
  if focused then (
    let navigation = Selection.fit navigation
      (List.map entries ~f:(fun (r : Row.t) -> r.key))
      ~equal:Key.equal ~rows in
    let body = match details with
      | Some view -> Tile_text.text_view view ~width ~rows
      | None ->
        List.take (List.drop entries navigation.top) rows
        |> List.mapi ~f:(fun i r -> Tile_text.item (style r) (description r) ~width
          ~selected:(navigation.top + i = navigation.index)) in
    let title = sprintf "Problems*%s (%s): %d/%d [%d/%d]"
      (if Option.is_some details then " details" else "") filter count total
      (if count = 0 then 0 else navigation.index + 1) count in
    let default = match details with
      | Some view -> Tile_text.text_footer ~hotkey_hints view ~width ~rows
      | None -> sprintf "%d above, %d below%s"
        navigation.top (Int.max 0 (count - navigation.top - rows))
        (if hotkey_hints then " | j/k e Enter a yy Esc" else "") in
    { title
    ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default)
    ; body = (if count = 0 then empty else body)
    })
  else (
    let preview = List.take entries rows |> List.map ~f:(fun r -> row (style r) (description r)) in
    (* Overflow is counted in the footer, so it costs no content row. *)
    let footer : Tile_shell.Label.t =
      if count > rows
      then { text = sprintf "+%d more%s" (count - rows)
        (if hotkey_hints then " | Space v e: all details" else ""); style = Warning }
      else Tile_shell.Label.hint
        (if hotkey_hints then "Space v o: focus | Space v e: details" else "")
    in
    { title = sprintf "Problems (%s): %d/%d" filter count total
    ; footer = Some footer
    ; body = (if count = 0 then empty else preview)
    })
;;
