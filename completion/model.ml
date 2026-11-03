open! Core
open Ches_core
module B = Text_buffer

module Token = struct
  type t = { resource : string; generation : int; revision : int; request : int }
  [@@deriving sexp_of, equal]
end

module Candidate = struct
  type source = Buffer | Lsp of string | Snippet [@@deriving sexp_of, equal]
  type t =
    { id : string; source : source; label : string; detail : string option
    ; filter_text : string; sort_text : string; primary : Text_edit.t
    ; additional : Text_edit.t list; cursor : int; snippet : Snippet.t option }
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
  type t = { text : B.t; words : int String.Map.t }

  module For_testing = struct
    let active = ref None
    let measure f =
      let bytes = ref 0 in
      let previous = !active in
      active := Some bytes;
      Exn.protect ~f:(fun () -> let result = f () in result, !bytes)
        ~finally:(fun () -> active := previous)
    ;;
  end

  let scan text ~start ~stop ~delta words =
    Option.iter !(For_testing.active) ~f:(fun bytes -> bytes := !bytes + stop - start);
    let add words start stop =
      if stop - start > 4096 then words else
      let key = B.slice text ~pos:start ~len:(stop - start) in
      Map.change words key ~f:(fun count ->
        let count = Option.value count ~default:0 + delta in
        if count = 0 then None else Some count)
    in
    let rec scan at word_start words =
      if at >= stop then
        match word_start with
        | Some start -> add words start at
        | _ -> words
      else if identifier text at then
        scan (Option.value_exn (B.next_boundary text at))
          (Some (Option.value word_start ~default:at)) words
      else
        let words = match word_start with
          | None -> words
          | Some start ->
            add words start at
        in
        scan (Option.value_exn (B.next_boundary text at)) None words
    in
    scan start None words
  ;;

  let create text =
    { text; words = scan text ~start:0 ~stop:(B.length text) ~delta:1 String.Map.empty }
  ;;

  let word_stop text at =
    let rec loop at =
      if identifier text at then loop (Option.value_exn (B.next_boundary text at)) else at
    in
    loop at
  ;;

  let update t text =
    if phys_equal t.text text then t else
      match B.changed_range ~before:t.text ~after:text with
      | None -> { t with text }
      | Some (start, old_stop, new_stop) ->
        let rec left at =
          match B.prev_boundary t.text at with
          | Some before when identifier t.text before -> left before
          | _ -> at
        in
        let start = left start in
        let old_stop = word_stop t.text old_stop in
        let new_stop = word_stop text new_stop in
        let words = scan t.text ~start ~stop:old_stop ~delta:(-1) t.words in
        let words = scan text ~start ~stop:new_stop ~delta:1 words in
        { text; words }
  ;;

  module Builder = struct
    type phase = Prefix of int | Suffix of int * int | Left of int * int * int
      | Old_right of int * int * int | New_right of int * int * int
      | Scan of B.t * int * int * int * int option * (int * int) option
      | Done
    type index = t
    type t = { text : B.t; before : index option; mutable words : int String.Map.t
             ; mutable phase : phase }
    let create ?before text =
      { text; before; words = Option.value_map before ~default:String.Map.empty ~f:(fun t -> t.words)
      ; phase = match before with
        | None -> Scan (text, 0, B.length text, 1, None, None)
        | Some old when phys_equal old.text text -> Done
        | Some old ->
          match B.recent_changed_range ~before:old.text ~after:text with
          | `Unchanged -> Done
          | `Changed (start, a, b) -> Left (start, a, b)
          | `Unknown -> Prefix 0 }
    ;;
    let step t ~budget =
      let remaining = ref (Int.max 0 budget) in
      let visited = ref 0 in
      let consume n = remaining := !remaining - n; visited := !visited + n in
      let old () = (Option.value_exn t.before).text in
      let advance text at =
        let next = Option.value_exn (B.next_boundary text at) in
        consume (next - at); next in
      let byte text at = (B.to_string text).[at] in
      while !remaining > 0 && (match t.phase with Done -> false | _ -> true) do
        match t.phase with
        | Done -> ()
        | Prefix at ->
          let before = old () in
          if at < Int.min (B.length before) (B.length t.text)
             && Char.equal (byte before at) (byte t.text at) then (
            consume 1; t.phase <- Prefix (at + 1))
          else if at = B.length before && at = B.length t.text then t.phase <- Done
          else if not (B.is_boundary before at && B.is_boundary t.text at) then (
            consume 1;
            (* The mismatch is inside one UTF-8 scalar. Start at its lead byte. *)
            let start = ref (at - 1) in
            while not (B.is_boundary before !start && B.is_boundary t.text !start) do decr start done;
            t.phase <- Suffix (!start, 0))
          else t.phase <- Suffix (at, 0)
        | Suffix (start, n) ->
          let before = old () in
          if n < Int.min (B.length before) (B.length t.text) - start
             && Char.equal (byte before (B.length before - n - 1))
                  (byte t.text (B.length t.text - n - 1)) then (
            consume 1; t.phase <- Suffix (start, n + 1))
          else (
            let n = ref n in
            while not (B.is_boundary before (B.length before - !n)
                       && B.is_boundary t.text (B.length t.text - !n)) do decr n done;
            t.phase <- Left (start, B.length before - !n, B.length t.text - !n))
        | Left (start, a, b) ->
          (match B.prev_boundary (old ()) start with
           | Some previous when identifier (old ()) previous ->
              consume (start - previous); t.phase <- Left (previous, a, b)
           | _ -> t.phase <- Old_right (start, a, b))
        | Old_right (start, a, b) ->
          if identifier (old ()) a then t.phase <- Old_right (start, advance (old ()) a, b)
          else t.phase <- New_right (start, a, b)
        | New_right (start, a, b) ->
          if identifier t.text b then t.phase <- New_right (start, a, advance t.text b)
          else t.phase <- Scan (old (), start, a, -1, None, Some (start, b))
        | Scan (text, at, stop, delta, word, next) ->
          let add finish =
            Option.iter word ~f:(fun start ->
              (* Pathological identifiers must not turn a bounded step into a
                 multi-megabyte substring allocation / tree comparison. *)
              if finish - start <= 4096 then (
                (* A balanced tree operation can compare a long common prefix
                   at every level. Charge that work, not just tokenization.
                   One atomic operation may exceed the remaining budget. *)
                let levels = 2 * Int.ceil_log2 (Map.length t.words + 2) + 1 in
                remaining := !remaining - ((finish - start + 1) * levels);
                let key = B.slice text ~pos:start ~len:(finish - start) in
                t.words <- Map.change t.words key ~f:(fun count ->
                  let n = Option.value count ~default:0 + delta in
                  if n <= 0 then None else Some n))) in
          if at >= stop then (
            add at;
            t.phase <- match next with None -> Done
              | Some (start, stop) -> Scan (t.text, start, stop, 1, None, None))
          else if identifier text at then
            t.phase <- Scan (text, advance text at, stop, delta,
              Some (Option.value word ~default:at), next)
          else (
            add at;
            t.phase <- Scan (text, advance text at, stop, delta, None, next))
      done;
      Option.iter !(For_testing.active) ~f:(fun bytes -> bytes := !bytes + !visited);
      match t.phase with Done -> Some { text = t.text; words = t.words } | _ -> None
    ;;
  end

  let update_bounded t text ~budget =
    Builder.step (Builder.create ~before:t text) ~budget
  ;;

  let candidates t ~text ~cursor ~limit =
    if limit <= 0 || not (phys_equal text t.text) then [] else
      match prefix_start text cursor with
      | None -> []
      | Some start ->
        let prefix = B.slice text ~pos:start ~len:(cursor - start) in
        let rec bounded_stop at =
          if at - start > 4096 || not (identifier text at) then at else
            bounded_stop (Option.value_exn (B.next_boundary text at)) in
        let stop = bounded_stop cursor in
        let current = if stop - start > 4096 then "" else
            B.slice text ~pos:start ~len:(stop - start) in
        Map.to_sequence t.words ~keys_greater_or_equal_to:prefix
        |> Sequence.take_while ~f:(fun (word, _) -> String.is_prefix word ~prefix)
        |> Sequence.filter ~f:(fun (word, count) ->
          not (String.equal word prefix)
          && (count > 1 || not (String.equal word current)))
        |> Fn.flip Sequence.take limit
        |> Sequence.to_list
        |> List.map ~f:(fun (word, _) ->
          { Candidate.id = "buffer:" ^ word; source = Buffer; label = word; detail = None
          ; filter_text = word; sort_text = word
          ; primary = { start; stop = cursor; text = word }; additional = []
          ; cursor = String.length word; snippet = None })
  ;;
end

type direction = Next | Previous [@@deriving sexp_of, equal]
type ghost = { at : int; text : string } [@@deriving sexp_of, equal]
type t =
  { token : Token.t; base : B.t; prefix : string; initial_cursor : int; expected_revision : int
  ; expected_cursor : int; limit : int; buffer : Candidate.t list
  ; providers : (string * Candidate.t list) list; items : Candidate.t list
  ; selected_index : int; installed : Candidate.t option; finalized : bool
  ; prefer_local_snippets : bool; stamp : unit ref }

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

let start ?(prefer_local_snippets = true) ~token ~text ~cursor ?words ~limit () =
  if limit <= 0 then None else
    Option.map (prefix_start text cursor) ~f:(fun start ->
      let buffer = Option.value_map words ~default:[] ~f:(fun words ->
        Buffer_words.candidates words ~text ~cursor ~limit) in
      { token; base = text; prefix = B.slice text ~pos:start ~len:(cursor - start)
      ; initial_cursor = cursor; expected_revision = token.revision
      ; expected_cursor = cursor; limit; buffer; providers = []; items = buffer
      ; selected_index = 0; installed = None; finalized = false; prefer_local_snippets; stamp = ref () },
      { Request.token; cursor; fallback_start = start; fallback_stop = cursor
      ; trigger = Automatic })
;;

let valid_candidate base (c : Candidate.t) =
  Option.for_all c.snippet ~f:(fun snippet -> String.equal c.primary.text (Snippet.text snippet))
  && Result.is_ok (Text_edit.inverse base (c.primary :: c.additional))
  && match B.of_string c.primary.text with
  | Error _ -> false
  | Ok text -> B.is_boundary text c.cursor
;;

let equivalent (a : Candidate.t) (b : Candidate.t) =
  Text_edit.equal a.primary b.primary
  && List.equal Text_edit.equal a.additional b.additional
  && a.cursor = b.cursor
  && Option.equal Snippet.equal a.snippet b.snippet
;;

let rebuild t ~providers ~buffer =
    let lsp = List.sort providers ~compare:(fun (a, _) (b, _) -> String.compare a b)
      |> List.concat_map ~f:snd
      |> List.stable_sort ~compare:(fun a b ->
        let local c = Candidate.equal_source c.Candidate.source Snippet in
        let source = if t.prefer_local_snippets then Bool.compare (local b) (local a)
          else Bool.compare (local a) (local b) in
        let template = Bool.compare (Option.is_none a.Candidate.snippet)
            (Option.is_none b.Candidate.snippet) in
        if source <> 0 then source else
        if template <> 0 then template else String.compare a.sort_text b.sort_text)
    in
    let items = List.fold (lsp @ buffer) ~init:[] ~f:(fun acc item ->
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
    { t with buffer; providers; items; selected_index; stamp = ref () }
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
    rebuild t ~providers ~buffer:t.buffer
;;

let receive_words t (request : Request.t) words =
  if not (Token.equal t.token request.token) || request.cursor <> t.initial_cursor
     || not (phys_equal words.Buffer_words.text t.base)
     || Option.is_some t.installed || t.finalized then t
  else
    let buffer = Buffer_words.candidates words ~text:t.base ~cursor:t.initial_cursor ~limit:t.limit in
    rebuild t ~providers:t.providers ~buffer
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
