open! Core
open Ches_core
module Controller = Ches_app.Controller
module Fuzzy = Ches_palette.Fuzzy
module Query = Ches_palette.Query

type result = { line : int; text : string; score : int; positions : int list }
module Key = struct
  module T = struct type t = int * int [@@deriving sexp, compare] end
  include T
  include Comparator.Make (T)
end
type snapshot =
  { id : Controller.Document_id.t; revision : int; text : Text_buffer.t }
type prepared = (int * string, unit) Fuzzy.Prepared.t
type job =
  { mutable index : int
  ; mutable ranked : result Map.M(Key).t
  ; mutable output : (Key.t * result) Sequence.t option
  ; mutable reversed : result list
  }
type t =
  { mutable snapshot : snapshot option
  ; count : int
  ; mutable query : string
  ; mutable results : result list
  ; mutable selected : int option
  ; mutable job : job option
  ; mutable cache : prepared Int.Map.t
  ; mutable prepared_count : int
  ; mutable bytes : int
  ; mutable limit : int
  ; mutable truncated : bool
  ; mutable closed : bool
  ; mutable invalidated : bool
  }
let schedule t =
  t.job <- Some { index = 0; ranked = Map.empty (module Key); output = None; reversed = [] }
let create controller =
  let editor = Controller.editor controller in
  let text = Editor.text editor in
  let count = Text_buffer.line_count text in
  let t =
    { snapshot = Some { id = Controller.document_id controller; revision = Editor.revision editor; text }
    ; count; query = ""; results = []; selected = None; job = None
    ; cache = Int.Map.empty; prepared_count = 0; bytes = 0
    ; limit = Int.min count 50_000; truncated = count > 50_000
    ; closed = false; invalidated = false }
  in schedule t; t
let query t = t.query
let results t = t.results
let selected t = t.selected
let busy t = Option.is_some t.job
let closed t = t.closed
let invalidated t = t.invalidated
let truncated t = t.truncated
let line_count t = t.count
let prepared_count t = t.prepared_count
let fresh snapshot controller =
  let editor = Controller.editor controller in
  Controller.Document_id.equal snapshot.id (Controller.document_id controller)
  && snapshot.revision = Editor.revision editor
  && phys_equal snapshot.text (Editor.text editor)
let drop t =
  t.snapshot <- None; t.job <- None; t.cache <- Int.Map.empty;
  t.results <- []; t.selected <- None
let validate t controller =
  match t.snapshot with
  | Some snapshot when fresh snapshot controller -> true
  | _ ->
    if not t.closed then (t.invalidated <- true; drop t);
    false
let update t (event : Ches_palette.Palette.Event.t) =
  if not t.closed && not t.invalidated then (
    let move by =
      if not (busy t) then
        Option.iter t.selected ~f:(fun selected ->
          Option.iter (List.findi t.results ~f:(fun _ r -> r.line = selected))
            ~f:(fun (i, _) ->
              let i = Int.clamp_exn (i + by) ~min:0 ~max:(List.length t.results - 1) in
              t.selected <- Some (List.nth_exn t.results i).line))
    in
    let query = match event with
      | Insert u -> Query.append t.query (Uchar.Utf8.to_string u)
      | Paste s -> Query.append t.query s
      | Backspace -> Query.backspace t.query
      | Delete_word -> Query.delete_word t.query
      | Next -> move 1; t.query
      | Previous -> move (-1); t.query
    in
    if not (String.equal query t.query) then (t.query <- query; schedule t))
let work t ~budget =
  if budget <= 0 then invalid_arg "line picker budget must be positive";
  Option.iter t.job ~f:(fun job ->
    match job.output with
    | None ->
      let rec loop left =
        if job.index >= t.limit then job.output <- Some (Map.to_sequence job.ranked)
        else if left > 0 then (
          let index = job.index in
          let prepared = match Map.find t.cache index with
            | Some p -> Some p
            | None ->
              let buffer = (Option.value_exn t.snapshot).text in
              let size = Text_buffer.line_end buffer index - Text_buffer.line_start buffer index in
              if size > 4096 || t.bytes + size > 8 * 1024 * 1024 then (
                t.limit <- index; t.truncated <- true; None)
              else (
                let text = Text_buffer.line_text buffer index in
                let p = Fuzzy.Prepared.create ((index + 1, text),
                  [ { Fuzzy.Field.tag = (); text; weight = 100 } ]) in
                t.bytes <- t.bytes + size;
                t.prepared_count <- t.prepared_count + 1;
                t.cache <- Map.set t.cache ~key:index ~data:p; Some p)
          in
          Option.iter prepared ~f:(fun p ->
            List.iter (Fuzzy.rank_prepared ~policy:Loose_subsequence ~query:t.query [ p ])
              ~f:(fun matched ->
                let line, text = matched.item in
                let positions = List.concat_map matched.positions ~f:snd in
                let result = { line; text; score = matched.score; positions } in
                job.ranked <- Map.set job.ranked ~key:(-result.score, line) ~data:result);
            job.index <- index + 1);
          loop (left - 1))
      in loop budget
    | Some output ->
      let rec loop left sequence =
        if left = 0 then job.output <- Some sequence
        else match Sequence.next sequence with
          | Some ((_, result), rest) -> job.reversed <- result :: job.reversed; loop (left - 1) rest
          | None ->
            let results = List.rev job.reversed in
            t.selected <- Ches_palette.Selection.preserve t.selected results
              ~id:(fun r -> r.line) ~equal:Int.equal;
            t.results <- results; t.job <- None
      in loop budget output)
let close t ~release = t.closed <- true; drop t; release ()
let cancel t ~release = if not t.closed then close t ~release
let accept t ~current ~release =
  if t.closed then Ok None
  else if not (validate t (current ())) then Or_error.error_string "Line search invalidated; reopen for the current document"
  else if busy t then Ok None
  else match Option.bind t.selected ~f:(fun line -> List.find t.results ~f:(fun r -> r.line = line)) with
    | None -> Ok None
    | Some result ->
      let snapshot = Option.value_exn t.snapshot in
      let pos = Option.value (List.min_elt result.positions ~compare:Int.compare) ~default:0 in
      let offset = Text_buffer.line_start snapshot.text (result.line - 1) + pos in
      close t ~release;
      let controller = current () in
      if not (fresh snapshot controller) then Or_error.error_string "Document changed while releasing line picker"
      else Or_error.bind (Editor.display_position_of_offset (Controller.editor controller) offset)
        ~f:(fun (line, column) -> Result.map (Controller.jump controller ~line ~column) ~f:Option.some)
