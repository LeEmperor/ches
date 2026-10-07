open! Core
open Ches_input

type t =
  { leader : Key.t
  ; primary : View_id.t
  ; views : Spec.t list
  ; focus : View_id.t
  ; pending : Key.t list
  ; notice : string option
  ; paste : (View_id.t * string list) option (** Owner, chunks newest first. *)
  }
[@@deriving sexp_of]

let spec t id =
  match List.find t.views ~f:(fun (spec : Spec.t) -> View_id.equal spec.id id) with
  | Some spec -> spec
  | None -> raise_s [%message "Ches_tile.Host: unknown view" (id : View_id.t)]
;;

let create ~leader ~primary views =
  let t =
    { leader; primary; views; focus = primary; pending = []; notice = None; paste = None }
  in
  ignore (spec t primary : Spec.t);
  t
;;

let primary t = t.primary

let focused t ~available =
  if View_id.equal t.focus t.primary || available t.focus then t.focus else t.primary
;;

let capturing t ~available =
  let focused = focused t ~available in
  Option.some_if (not (View_id.equal focused t.primary)) focused
;;

let cursor_owner t ~available =
  let focused = focused t ~available in
  Option.some_if (spec t focused).owns_cursor focused
;;

let focus t id =
  if (spec t id).focusable then { t with focus = id; pending = []; notice = None } else t
;;

let return t = { t with focus = t.primary; pending = []; notice = None }

let reconcile t ~available =
  if View_id.equal (focused t ~available) t.focus
  then t, `Kept
  else return t, `Returned t.focus
;;

let pending t = t.pending
let notice t = t.notice
let with_notice t text = { t with notice = Some text; pending = [] }

module Decision = struct
  type 'action t =
    | Handled
    | Workspace of View_command.t
    | Content of 'action
    | Return
    | Notice of string
  [@@deriving sexp_of]
end

let key t (key : Key.t) ~lookup ~content ~escape ~hint : t * _ Decision.t =
  let prefix keys = { t with pending = keys; notice = None }, Decision.Handled in
  let notice text = { t with pending = [] }, Decision.Notice text in
  let action a = { t with pending = []; notice = None }, Decision.Content a in
  match key, t.pending with
  | Escape, _ :: _ -> { t with pending = []; notice = None }, Handled
  | Escape, [] ->
    (match escape with
     | Some a -> action a
     | None -> t, Return)
  | Ctrl 'c', _ -> notice "Escape returns to the editor"
  | Tab, _ -> t, Return
  | _, first :: _ when Key.equal first t.leader ->
    let keys = t.pending @ [ key ] in
    (match (lookup keys : Bindings.lookup) with
     | Prefix -> prefix keys
     | Bound (View (Scroll _)) | Bound (Scroll _) ->
       notice "Document scrolling is unavailable here"
     | Bound (View view) -> { t with pending = []; notice = None }, Workspace view
     | Bound _ -> notice "Editor command unavailable; Escape returns to editor"
     | Unbound -> notice "Unbound workspace key")
  | _, [] when Key.equal key t.leader && not (spec t t.focus).accepts_text ->
    prefix [ key ]
  | _, pending ->
    let keys = pending @ [ key ] in
    (match (content keys : _ Content_key.t) with
     | Prefix -> prefix keys
     | Action a -> action a
     | Unbound -> notice (if List.is_empty pending then hint else "Cancelled prefix"))
;;

let pasting t = Option.is_some t.paste

let paste_start t ~available =
  if pasting t then t else { t with paste = Some (focused t ~available, []) }
;;

let paste_key t key =
  match t.paste, Key.text key with
  | Some (owner, chunks), Some text -> { t with paste = Some (owner, text :: chunks) }
  | Some _, None | None, _ -> t
;;

let paste_end t =
  match t.paste with
  | None -> t, `Not_pasting
  | Some (owner, chunks) ->
    let t = { t with paste = None } in
    let spec = spec t owner in
    if spec.accepts_paste
    then t, `Deliver (owner, String.concat (List.rev chunks))
    else t, `Reject (owner, sprintf "%s: read-only; paste ignored" spec.title)
;;
