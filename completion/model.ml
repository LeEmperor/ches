open! Core
open Ches_core
module B = Text_buffer

module Token = struct
  type t = { resource : string; generation : int; revision : int; request : int }
  [@@deriving sexp_of, equal]
end

module Candidate = struct
  type source = Buffer | Lsp of string [@@deriving sexp_of, equal]
  type t =
    { id : string; source : source; label : string; detail : string option
    ; filter_text : string; sort_text : string; primary : Text_edit.t
    ; additional : Text_edit.t list; cursor : int }
  [@@deriving sexp_of, equal]
end

module Request = struct
  type trigger = Automatic | Character of string | Incomplete
  [@@deriving sexp_of, equal]
  type t =
    { token : Token.t; cursor : int; fallback_start : int; fallback_stop : int
    ; trigger : trigger }
  [@@deriving sexp_of, equal]
end

module Reply = struct
  type t =
    { token : Token.t; source : string; candidates : Candidate.t list; incomplete : bool }
  [@@deriving sexp_of, equal]
end

let identifier text at =
  at < B.length text
  && match Search_match.small_word_class text at with Some `Identifier -> true | _ -> false
;;

let prefix_start text cursor =
  if not (B.is_boundary text cursor) then None else
    let rec loop at =
      match B.prev_boundary text at with
      | Some before when identifier text before ->
        if cursor - before > 4096 then None else loop before
      | _ -> Some at
    in
    loop cursor
;;

module Buffer_words = struct
  type t = { text : B.t; words : (string * int list) list }

  let create text =
    let rec boundary at = if B.is_boundary text at then at else boundary (at - 1) in
    let bound = boundary (Int.min (B.length text) 65536) in
    let rec scan at word_start words =
      if at >= bound then
        match word_start with
        | Some start when at = B.length text ->
          Map.add_multi words ~key:(B.slice text ~pos:start ~len:(at - start)) ~data:start
        | _ -> words
      else if identifier text at then
        scan (Option.value_exn (B.next_boundary text at))
          (Some (Option.value word_start ~default:at)) words
      else
        let words = match word_start with
          | None -> words
          | Some start ->
            Map.add_multi words ~key:(B.slice text ~pos:start ~len:(at - start)) ~data:start
        in
        scan (Option.value_exn (B.next_boundary text at)) None words
    in
    { text; words = Map.to_alist (scan 0 None String.Map.empty) }
  ;;

  let candidates t ~text ~cursor ~limit =
    if limit <= 0 || not (phys_equal text t.text) then [] else
      match prefix_start text cursor with
      | None -> []
      | Some start ->
        let prefix = B.slice text ~pos:start ~len:(cursor - start) in
        if String.is_empty prefix then [] else
          List.filter_map t.words ~f:(fun (word, offsets) ->
            if String.equal word prefix || not (String.is_prefix word ~prefix) then None
            else
              if List.exists offsets ~f:(fun at -> at <> start) then Some word else None)
          (* The index's string map already supplies lexical order. *)
          |> Fn.flip List.take limit
          |> List.map ~f:(fun word ->
            { Candidate.id = "buffer:" ^ word; source = Buffer; label = word; detail = None
            ; filter_text = word; sort_text = word
            ; primary = { start; stop = cursor; text = word }; additional = []
            ; cursor = String.length word })
  ;;
end

type direction = Next | Previous [@@deriving sexp_of, equal]
type ghost = { at : int; text : string } [@@deriving sexp_of, equal]
type t =
  { token : Token.t; base : B.t; prefix : string; initial_cursor : int; expected_revision : int
  ; expected_cursor : int; limit : int; buffer : Candidate.t list
  ; providers : (string * Candidate.t list) list; items : Candidate.t list
  ; selected_index : int; installed : Candidate.t option; finalized : bool
  ; stamp : unit ref }

type plan_kind = Primary | Finalize
type plan =
  { owner : unit ref; candidate : Candidate.t; index : int; kind : plan_kind
  ; batches : Text_edit.t list list; final_cursor : int }

let candidates t = t.items
let selected t = List.nth t.items t.selected_index
let edits p = p.batches
let cursor p = p.final_cursor
let matches t ~revision ~cursor =
  not t.finalized && revision = t.expected_revision && cursor = t.expected_cursor
;;

let start ~token ~text ~cursor ~words ~limit =
  if limit <= 0 then None else
    Option.map (prefix_start text cursor) ~f:(fun start ->
      let buffer = Buffer_words.candidates words ~text ~cursor ~limit in
      { token; base = text; prefix = B.slice text ~pos:start ~len:(cursor - start)
      ; initial_cursor = cursor; expected_revision = token.revision
      ; expected_cursor = cursor; limit; buffer; providers = []; items = buffer
      ; selected_index = 0; installed = None; finalized = false; stamp = ref () },
      { Request.token; cursor; fallback_start = start; fallback_stop = cursor
      ; trigger = Automatic })
;;

let valid_candidate base (c : Candidate.t) =
  Result.is_ok (Text_edit.inverse base (c.primary :: c.additional))
  && match B.of_string c.primary.text with
  | Error _ -> false
  | Ok text -> B.is_boundary text c.cursor
;;

let equivalent (a : Candidate.t) (b : Candidate.t) =
  Text_edit.equal a.primary b.primary
  && List.equal Text_edit.equal a.additional b.additional
  && a.cursor = b.cursor
;;

let receive t (reply : Reply.t) =
  if not (Token.equal t.token reply.token) || Option.is_some t.installed || t.finalized
  then t
  else
    let contribution =
      (* Bound untrusted provider work as well as the final menu. *)
      List.take reply.candidates 1000
      |> List.filter ~f:(fun c ->
        String.is_prefix c.Candidate.filter_text ~prefix:t.prefix
        && valid_candidate t.base c)
    in
    let providers = List.Assoc.add t.providers ~equal:String.equal reply.source contribution in
    let lsp = List.sort providers ~compare:(fun (a, _) (b, _) -> String.compare a b)
      |> List.concat_map ~f:snd
      |> List.stable_sort ~compare:(fun a b -> String.compare a.Candidate.sort_text b.sort_text)
    in
    let items = List.fold (lsp @ t.buffer) ~init:[] ~f:(fun acc item ->
      if List.exists acc ~f:(equivalent item) then acc else item :: acc)
      |> List.rev |> Fn.flip List.take t.limit
    in
    let selected_index = match selected t with
      | None -> 0
      | Some old ->
        List.findi items ~f:(fun _ c ->
          Candidate.equal_source old.source c.source && String.equal old.id c.id)
        |> Option.value_map ~default:0 ~f:fst
    in
    { t with providers; items; selected_index; stamp = ref () }
;;

let make_plan t index candidate kind =
  let inverse = match t.installed with
    | None -> []
    | Some c -> Or_error.ok_exn (Text_edit.inverse t.base [ c.primary ])
  in
  let additional = match kind with Primary -> [] | Finalize -> candidate.Candidate.additional in
  let shift = List.fold additional ~init:0 ~f:(fun shift (e : Text_edit.t) ->
    if e.stop <= candidate.primary.start
    then shift + String.length e.text - (e.stop - e.start) else shift)
  in
  { owner = t.stamp; candidate; index; kind
  ; batches = [ inverse; candidate.primary :: additional ]
  ; final_cursor = candidate.primary.start + shift + candidate.cursor }
;;

let plan t direction =
  if t.finalized || List.is_empty t.items then None else
    let count = List.length t.items in
    let index = match t.installed with
      | None -> t.selected_index
      | Some _ -> (t.selected_index + (match direction with Next -> 1 | Previous -> count - 1)) % count
    in
    Option.map (List.nth t.items index) ~f:(fun c -> make_plan t index c Primary)
;;

let finalize t =
  if t.finalized then None else
    Option.bind t.installed ~f:(fun c ->
      if List.is_empty c.additional then None
      else Some (make_plan t t.selected_index c Finalize))
;;

let applied t p ~revision =
  if not (phys_equal t.stamp p.owner) then invalid_arg "Completion.applied: stale or foreign plan";
  { t with installed = Some p.candidate; selected_index = p.index
  ; expected_revision = revision; expected_cursor = p.final_cursor
  ; finalized = (match p.kind with Finalize -> true | Primary -> false); stamp = ref () }
;;

let ghost t =
  if t.finalized || Option.is_some t.installed then None else
    Option.bind (selected t) ~f:(fun c ->
      let e = c.primary in
      if not (List.is_empty c.additional) || e.stop <> t.initial_cursor
         || String.contains e.text '\n'
      then None
      else
        let prefix = B.slice t.base ~pos:e.start ~len:(e.stop - e.start) in
        if not (String.is_prefix e.text ~prefix) || String.length e.text <= String.length prefix
        then None
        else Some { at = e.stop; text = String.drop_prefix e.text (String.length prefix) })
;;
