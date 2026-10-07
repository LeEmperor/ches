open! Core
module Query = Ches_palette.Query
module Event = Ches_palette.Palette.Event

module Rank_key = struct
  module T = struct
    type t = int * int [@@deriving sexp, compare]
  end
  include T
  include Comparator.Make (T)
end

type job =
  { mutable remaining : Model.Candidate.t list
  ; mutable index : int
  ; mutable ranked : Model.Query_result.t Map.M(Rank_key).t
  ; mutable cache : Search.t String.Map.t
  ; mutable output : (Rank_key.t * Model.Query_result.t) Sequence.t option
  ; mutable reversed : Model.Query_result.t list
  }

type 'token t =
  { mutable model : 'token Model.t
  ; mutable query : string
  ; mutable cache : Search.t String.Map.t
  ; mutable job : job option
  ; mutable closed : bool
  ; mutable prepared_count : int
  }

let schedule t =
  t.job <- Some
    { remaining = (Model.discovery t.model).candidates
    ; index = 0
    ; ranked = Map.empty (module Rank_key)
    ; cache = String.Map.empty
    ; output = None
    ; reversed = []
    }
;;

let create ~token ~discovery =
  let t =
    { model = Model.create ~token ~discovery; query = ""
    ; cache = String.Map.empty; job = None; closed = false; prepared_count = 0 }
  in
  schedule t;
  t
;;

let model t = t.model
let query t = t.query
let busy t = Option.is_some t.job
let closed t = t.closed
let prepared_count t = t.prepared_count

let install t (snapshot : Model.Discovery.t) =
  let current = Model.discovery t.model in
  if not t.closed
     && Model.Run_id.equal current.request.run_id snapshot.request.run_id
     && String.equal current.request.root snapshot.request.root
  then (
    t.model <- Model.with_discovery t.model snapshot;
    if not (phys_equal current.candidates snapshot.candidates) then schedule t;
    true)
  else false
;;

let move t ~by =
  let results = Model.results t.model in
  Option.iter (Model.selected t.model) ~f:(fun id ->
    Option.iter
      (List.findi results ~f:(fun _ r -> Model.Candidate.Id.equal id (Model.Candidate.id r.candidate)))
      ~f:(fun (index, _) ->
        let index = Int.clamp_exn (index + by) ~min:0 ~max:(List.length results - 1) in
        t.model <- Model.select t.model (Model.Candidate.id (List.nth_exn results index).candidate)))
;;

let update t (event : Event.t) =
  if not t.closed then (
    let query =
      match event with
      | Insert u -> Query.append t.query (Uchar.Utf8.to_string u)
      | Paste text -> Query.append t.query text
      | Backspace -> Query.backspace t.query
      | Delete_word -> Query.delete_word t.query
      | Next -> if not (busy t) then move t ~by:1; t.query
      | Previous -> if not (busy t) then move t ~by:(-1); t.query
    in
    if not (String.equal t.query query) then (t.query <- query; schedule t))
;;

(* Only explicit host work does decoding/matching. New input replaces the job, so
   obsolete output can never publish. Cache entries created by abandoned jobs are
   reused; publishing drops entries absent from the current snapshot. *)
let work t ~budget =
  if budget <= 0 then invalid_arg "file picker work budget must be positive";
  Option.iter t.job ~f:(fun job ->
    match job.output with
    | None ->
      let rec loop left =
        match left, job.remaining with
        | 0, _ -> ()
        | _, [] -> job.output <- Some (Map.to_sequence job.ranked)
        | _, candidate :: rest ->
          let key = Model.Candidate.path candidate in
          let prepared =
            match Map.find t.cache key with
            | Some prepared -> prepared
            | None ->
              let prepared = Search.prepare [ candidate ] in
              t.prepared_count <- t.prepared_count + 1;
              t.cache <- Map.set t.cache ~key ~data:prepared;
              prepared
          in
          job.cache <- Map.set job.cache ~key ~data:prepared;
          List.iter (Search.rank ~query:t.query prepared) ~f:(fun result ->
            job.ranked <- Map.set job.ranked ~key:(-result.score, job.index) ~data:result);
          job.index <- job.index + 1;
          job.remaining <- rest;
          loop (left - 1)
      in
      loop budget
    | Some output ->
      let rec loop left sequence =
        if left = 0 then job.output <- Some sequence
        else
          match Sequence.next sequence with
          | Some ((_, result), rest) ->
            job.reversed <- result :: job.reversed;
            loop (left - 1) rest
          | None ->
            t.model <- Model.with_results t.model ~query:t.query (List.rev job.reversed);
            t.cache <- job.cache;
            t.job <- None
      in
      loop budget output)
;;

let close t ~release =
  t.closed <- true;
  t.job <- None;
  t.cache <- String.Map.empty;
  let discovery = Model.discovery t.model in
  t.model <- Model.create ~token:(Model.token t.model)
    ~discovery:{ discovery with candidates = []; status = Cancelled };
  release ()
;;

let cancel t ~release = if not t.closed then close t ~release

let accept t ~release ~consume =
  if not t.closed && not (busy t)
  then Option.iter (Model.accept t.model) ~f:(fun request ->
    close t ~release;
    consume request)
;;
