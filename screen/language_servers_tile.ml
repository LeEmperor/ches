open! Core
module Server = Ches_error.Source_event.Server
module Text_view = Ches_tile.Text_view

let id = Ches_tile.View_id.of_string "language-servers"
let spec = Ches_tile.Spec.read_only_text id ~title:"Language servers"

type t =
  { servers : Server.t list
  ; file : string option
  ; source_attached : bool
  ; view : Text_view.t
  }
[@@deriving sexp_of]

(* Quote untrusted process output and paths as literal text, including controls and
   newlines. The report never interprets terminal escapes or markup. *)
let literal s = sprintf "%S" s

let status = function
  | Server.Starting -> "Starting"
  | Running -> "Running"
  | Stopped reason -> "Stopped: " ^ literal reason
  | Unavailable reason -> "Unavailable: " ^ literal reason
;;

let report t =
  let attached (server : Server.t) =
    Option.exists t.file ~f:(fun file -> List.mem server.resources file ~equal:String.equal)
  in
  let current =
    match t.file with
    | None -> [ "Current buffer: no file buffer" ]
    | Some file ->
      [ "Current file: " ^ literal file
      ; (match List.filter t.servers ~f:attached with
         | [] -> "Current file: no managed language server attached (unsupported or not managed)"
         | servers -> "Current file attached to: " ^
             String.concat ~sep:", " (List.map servers ~f:(fun s -> literal s.source)))
      ]
  in
  let inventory =
    if not t.source_attached then
      [ "No diagnostic source attached (language servers disabled with --no-lsp)." ]
    else if List.is_empty t.servers then [ "No managed language servers." ]
    else List.concat_map t.servers ~f:(fun (server : Server.t) ->
      [ "Server: " ^ literal server.source ^ (if attached server then " [current file attached]" else "")
      ; "Status: " ^ status server.status
      ; "Launch command: " ^ String.concat ~sep:" " (List.map (server.program :: server.args) ~f:literal)
      ; "Root: " ^ literal server.root
      ; sprintf "Attached documents: %d" (List.length server.resources)
      ] @ List.map server.resources ~f:(fun resource -> "  " ^ literal resource) @ [ "" ])
  in
  String.concat ~sep:"\n" ([ "Language servers (live)"; "" ] @ current @ [ "" ] @ inventory)
;;

let refresh t = { t with view = fst (Text_view.update t.view (report t)) }
let create ~source_attached =
  refresh { servers = []; file = None; source_attached
          ; view = Text_view.create ~cell_width:Cell_map.width "" }
;;
let inventory t servers = refresh { t with servers }
let context t file = if Option.equal String.equal t.file file then t else refresh { t with file }
let key = Type_equal.Id.create ~name:"language-servers" sexp_of_t

let adapter : (t, Text_view.Action.t) View_registry.Adapter.t =
  { spec
  ; key
  ; fit = (fun t _ ~rows ~width -> { t with view = Text_view.fit t.view ~rows ~width })
  ; leave = (fun t -> { t with view = Text_view.jump t.view (Text_view.cursor t.view) })
  ; text_view = (fun t -> Some t.view)
  ; interpret = (fun t keys -> Text_view.interpret t.view keys)
  ; escape = (fun t -> Text_view.escape t.view)
  ; hint = "Language servers: read-only; v/V select, y copy, Space b c close"
  ; perform = (fun t controller ~context:_ ~rows ~width action ->
      let view, effect = Text_view.perform t.view ~rows ~width action in
      { t with view }, View_registry.Outcome.create ?effect controller)
  ; commands = (fun t -> Text_view.commands t.view)
  ; signal = (fun _ _ -> None)
  ; text_area = (fun _ ~rows ~width -> Some { Geometry.Rect.x = 0; y = 0; width; height = rows })
  ; label = (fun _ -> None)
  ; render = (fun t _ ~hotkey_hints ~focused:_ ~notice ~pending ~width ~rows ->
      { title = "Language servers (live)"
      ; footer = Some (Tile_shell.Label.footer ~notice ~pending
          ~default:(Tile_text.text_footer ~hotkey_hints t.view ~width ~rows))
      ; body = Tile_text.text_view t.view ~width ~rows
      })
  }
;;
