open! Core
module Query = Ches_palette.Query
module Event = Ches_palette.Palette.Event
module Index = Model.Result_index

module Cache_limits = struct
  type t = { max_entries : int; max_bytes : int }
  let default = { max_entries = 4; max_bytes = 96 * 1024 * 1024 }
end

type cached_query =
  { key : string; query : Search.query; results : Index.t; generation : int; bytes : int }
type source = Full | Narrow of (int * Model.Candidate.t) Sequence.t
type job_kind = Rank | Reuse of Index.t

module Rank_key = struct
  module T = struct type t = int * int [@@deriving sexp, compare] end
  include T
  include Comparator.Make (T)
end

type snapshot_job =
  { mutable remaining : Model.Candidate.t list
  ; mutable ordinal : int
  ; identities : Index.Identity.Builder.t
  ; blank : Index.Builder.t
  ; mutable retained : Search.prepared String.Map.t
  ; mutable corpus_bytes : int
  ; mutable prepared_bytes : int
  }

type job =
  { mutable source : source
  ; mutable remaining : Model.Candidate.t list
  ; mutable ordinal : int
  ; kind : job_kind
  ; mutable examined : int
  ; query : Search.query
  ; scratch : Search.scratch
  ; mutable ranked : Model.Candidate.t Map.M(Rank_key).t
  ; mutable output : (Rank_key.t * Model.Candidate.t) Sequence.t option
  ; results : Index.Builder.t
  ; mutable chunk_number : int
  ; mutable prepared_chunk : Search.prepared option array
  ; tail_from : int
  }

type stream =
  { mutable update : Model.Discovery.Update.t
  ; pending : Model.Candidate.t Queue.t
  ; mutable arrivals : Model.Candidate.t option array Int.Map.t
  ; identities : Index.Identity.Builder.t
  ; mutable ingested : int
  ; mutable cursor : int
  ; mutable ranked : Index.Tree.t
  ; mutable query : Search.query
  ; mutable scratch : Search.scratch
  ; mutable rebuild : Model.Candidate.t Sequence.t option
  ; mutable retained : Search.prepared String.Map.t option
  }

type snapshot =
  { candidates : Model.Discovery.Candidates.t
  ; arrivals : Model.Candidate.t option array Int.Map.t
  ; prepared_slots : Search.prepared option array Int.Map.t
  ; prepared : Search.prepared String.Map.t
  ; identity : Index.Identity.t; blank : Index.t; queries : cached_query list
  ; corpus_bytes : int; prepared_bytes : int; bytes : int }
type refresh =
  { mutable incoming : Model.Discovery.Update.t; old : snapshot
  ; mutable unchanged : int; mutable changed : bool }

let next_instance = ref 0

type 'token t =
  { mutable model : 'token Model.t
  ; mutable query : string
  ; mutable cache : Search.prepared String.Map.t
  ; mutable prepared_chunks : Search.prepared option array Int.Map.t
  ; mutable identity : Index.Identity.t option
  ; mutable snapshot_job : snapshot_job option
  ; mutable job : job option
  ; mutable closed : bool
  ; mutable prepared_count : int
  ; mutable indexed_count : int
  ; mutable compiled_count : int
  ; mutable scored_count : int
  ; mutable blank_results : Index.t option
  ; cache_limits : Cache_limits.t
  ; mutable query_cache : cached_query list
  ; mutable generation : int
  ; mutable corpus_bytes : int
  ; mutable prepared_bytes : int
  ; mutable cache_hits : int
  ; mutable cache_evictions : int
  ; mutable narrowed_count : int
  ; mutable last_examined_count : int
  ; mutable stream : stream option
  ; instance : int
  ; mutable visible_revision : int
  ; mutable refresh : refresh option
  ; mutable accept_validated : bool
  ; mutable finish_validation : bool
  ; mutable frozen_prepared : Int.Set.t
  ; mutable on_snapshot : (snapshot -> unit) option
  }

let owned_base_bytes t = t.corpus_bytes + t.prepared_bytes + 8192
  + Option.value_map t.blank_results ~default:0 ~f:Index.retained_bytes
let cache_bytes t = if List.is_empty t.query_cache then 0 else
  owned_base_bytes t + List.sum (module Int) t.query_cache ~f:(fun entry -> entry.bytes)
let valid_entry t (entry : cached_query) = entry.generation = t.generation
  && Option.exists t.identity ~f:(Index.belongs_to entry.results)
let touch t entry = t.query_cache <- entry :: List.filter t.query_cache
  ~f:(fun other -> not (phys_equal other entry))

let schedule ?(allow_narrowing = false) t =
  let cached = List.find t.query_cache ~f:(fun entry -> valid_entry t entry && String.equal entry.key t.query) in
  let query, kind, source, remaining = match cached with
    | Some entry -> touch t entry; entry.query, Reuse entry.results, Full, []
    | None ->
      t.compiled_count <- t.compiled_count + 1;
      let query = Search.compile t.query in
      let exact = List.find t.query_cache ~f:(fun entry -> valid_entry t entry && Search.same_query entry.query query) in
      (match exact with
       | Some entry -> touch t entry; entry.query, Reuse entry.results, Full, []
       | None ->
         let parent = if not allow_narrowing then None else
           List.fold t.query_cache ~init:(None : cached_query option) ~f:(fun best entry ->
             if not (valid_entry t entry && Search.is_extension ~previous:entry.query ~next:query)
                || Index.length entry.results >= Model.discovered_count t.model then best
             else match best with
               | Some prior when Index.length prior.results <= Index.length entry.results -> best
               | _ -> Some entry) in
         let source, remaining = match parent with
           | None -> Full, (if Option.is_some t.stream then [] else (Model.discovery t.model).candidates)
           | Some entry ->
             touch t entry;
             t.narrowed_count <- t.narrowed_count + 1;
             Narrow (Index.metadata entry.results), [] in
         query, Rank, source, remaining) in
  let job =
    { source; remaining; ordinal = 0; kind; examined = 0
    ; query; scratch = Search.scratch ()
    ; ranked = Map.empty (module Rank_key); output = None; results = Index.Builder.create ()
    ; chunk_number = -1; prepared_chunk = [||]; tail_from = Model.discovered_count t.model } in
  t.job <- Some job;
  Option.iter t.stream ~f:(fun stream ->
    stream.query <- query; stream.scratch <- job.scratch;
    stream.cursor <- 0; stream.ranked <- Index.Tree.empty)
;;
let reset_snapshot t =
  t.stream <- None;
  t.query_cache <- [];
  t.generation <- t.generation + 1;
  t.corpus_bytes <- 0; t.prepared_bytes <- 0;
  t.identity <- None;
  t.blank_results <- None;
  t.prepared_chunks <- Int.Map.empty;
  t.snapshot_job <- Some
    { remaining = (Model.discovery t.model).candidates; ordinal = 0
    ; identities = Index.Identity.Builder.create (); blank = Index.Builder.create ()
    ; retained = String.Map.empty; corpus_bytes = 8192; prepared_bytes = 0 }
;;
let create_with_cache_limits ~(cache_limits : Cache_limits.t) ~token ~discovery =
  if cache_limits.max_entries < 0 || cache_limits.max_entries > 16 || cache_limits.max_bytes < 0 then
    invalid_arg "File-picker query cache limits";
  incr next_instance;
  let t =
    { model = Model.create ~token ~discovery; query = ""; cache = String.Map.empty
    ; prepared_chunks = Int.Map.empty; identity = None; snapshot_job = None
    ; job = None; closed = false; prepared_count = 0; indexed_count = 0
    ; compiled_count = 0; scored_count = 0; blank_results = None; cache_limits
    ; query_cache = []; generation = 0; corpus_bytes = 0; prepared_bytes = 0
    ; cache_hits = 0; cache_evictions = 0; narrowed_count = 0; last_examined_count = 0
    ; stream = None; instance = !next_instance; visible_revision = 0
    ; refresh = None; accept_validated = true; finish_validation = false
    ; frozen_prepared = Int.Set.empty; on_snapshot = None } in
  reset_snapshot t; schedule t; t
;;
let create ~token ~discovery = create_with_cache_limits ~cache_limits:Cache_limits.default ~token ~discovery
let model t = t.model
let query t = t.query
let busy t = Option.is_some t.job
let has_work t = Option.is_some t.job
let refreshing t = Option.is_some t.refresh
let acceptance_blocked t = not t.accept_validated
let refresh_count t = Option.value_map t.refresh ~default:0 ~f:(fun r -> Model.Discovery.Candidates.length r.incoming.candidates)
let closed t = t.closed
let prepared_count t = t.prepared_count
let indexed_count t = t.indexed_count
let compiled_count t = t.compiled_count
let scored_count t = t.scored_count
let visible_revision t = t.visible_revision
let instance t = t.instance
let cache_hits t = t.cache_hits
let cache_evictions t = t.cache_evictions
let cache_entries t = List.length t.query_cache
let cache_queries t = List.map t.query_cache ~f:(fun entry -> entry.key)
let narrowed_count t = t.narrowed_count
let last_examined_count t = Option.value_map t.job ~default:t.last_examined_count ~f:(fun job -> job.examined)
let prepared_payload_bytes t = Map.fold t.cache ~init:0 ~f:(fun ~key:_ ~data bytes ->
  bytes + Search.retained_bytes data)
let work_phase t = match t.job, t.snapshot_job with
  | None, _ -> `Idle
  | Some _, Some _ -> `Snapshot
  | Some { kind = Reuse _; _ }, None -> `Reuse
  | Some { output = Some _; _ }, None -> `Output
  | Some _, None -> `Score

let install t (snapshot : Model.Discovery.t) =
  let request = Model.discovery_request t.model in
  if not t.closed && Model.Run_id.equal request.run_id snapshot.request.run_id
     && String.equal request.root snapshot.request.root
  then (
    let changed = Option.is_some t.stream || not (phys_equal (Model.discovery t.model).candidates snapshot.candidates) in
    if changed || not (Model.Discovery.equal_status (Model.discovery_status t.model) snapshot.status) then
      t.visible_revision <- t.visible_revision + 1;
    t.model <- Model.with_discovery t.model snapshot;
    if changed then (reset_snapshot t; schedule t);
    true)
  else false
;;
let move t ~by =
  Option.iter (Model.selected_index t.model) ~f:(fun index ->
    let index = Int.clamp_exn (index + by) ~min:0 ~max:(Model.result_count t.model - 1) in
    if not (Option.equal Int.equal (Model.selected_index t.model) (Some index)) then
      t.visible_revision <- t.visible_revision + 1;
    t.model <- Model.select_index t.model index)
;;
let update t (event : Event.t) =
  if not t.closed then (
    let query = match event with
      | Insert u -> Query.append t.query (Uchar.Utf8.to_string u)
      | Paste text -> Query.append t.query text
      | Backspace -> Query.backspace t.query
      | Delete_word -> Query.delete_word t.query
      | Next -> if not (busy t) then move t ~by:1; t.query
      | Previous -> if not (busy t) then move t ~by:(-1); t.query in
    if not (String.equal t.query query) then (
      (* An interrupted query never supplies a narrowing set. Exact completed-cache
         hits remain safe; otherwise interrupted/coalesced edits rescan the corpus. *)
      let allow_narrowing = Option.is_none t.job in
      t.visible_revision <- t.visible_revision + 1;
      t.query <- query; schedule ~allow_narrowing t))
;;

let remember t query results =
  if not (Search.is_blank query) && t.cache_limits.max_entries > 0
     && Option.exists t.identity ~f:(Index.belongs_to results) then (
    let bytes = Index.retained_bytes results + Search.query_bytes query
      + 2 * (String.length t.query + 16) + 512 in
    if owned_base_bytes t + bytes <= t.cache_limits.max_bytes then (
      let entry = { key = t.query; query; results; generation = t.generation; bytes } in
      t.query_cache <- entry :: List.filter t.query_cache ~f:(fun old -> not (String.equal old.key entry.key));
      while List.length t.query_cache > t.cache_limits.max_entries || cache_bytes t > t.cache_limits.max_bytes do
        t.query_cache <- List.drop_last_exn t.query_cache;
        t.cache_evictions <- t.cache_evictions + 1
      done))
;;

let publish t results =
  let job = t.job in
  t.last_examined_count <- Option.value_map job ~default:0 ~f:(fun job -> job.examined);
  t.model <- Model.with_result_index t.model ~query:t.query results;
  t.visible_revision <- t.visible_revision + 1;
  t.job <- None;
  Option.iter job ~f:(fun job -> match job.kind with Rank -> remember t job.query results | Reuse _ -> ())
;;

(* Snapshot identity/ordinal storage is built only once, in budgeted turns. Query
   edits retain partial identity work; actual snapshot changes discard it. *)
let work_snapshot t (snapshot : snapshot_job) ~budget =
  let rec loop left =
    match snapshot.remaining with
    | [] ->
      let identity = Index.Identity.Builder.finish snapshot.identities in
      let blank = Index.Builder.finish ~identity snapshot.blank in
      t.identity <- Some identity; t.blank_results <- Some blank;
      t.cache <- snapshot.retained; t.snapshot_job <- None;
      t.corpus_bytes <- snapshot.corpus_bytes; t.prepared_bytes <- snapshot.prepared_bytes;
      Option.iter t.job ~f:(fun job -> if Search.is_blank job.query then publish t blank)
    | _ when left = 0 -> ()
    | candidate :: rest ->
      let chunk_number = snapshot.ordinal / 128 in
      let offset = snapshot.ordinal % 128 in
      let chunk = if offset = 0 then (
        let chunk = Array.create ~len:128 None in
        t.prepared_chunks <- Map.set t.prepared_chunks ~key:chunk_number ~data:chunk;
        chunk) else Map.find_exn t.prepared_chunks chunk_number in
      let key = Model.Candidate.path candidate in
      (* Count all reachable candidate strings (even shared roots), list cells,
         identity nodes, preparation slots/map headers; no admission-time scan. *)
      snapshot.corpus_bytes <- snapshot.corpus_bytes + Model.Candidate.ownership_bytes candidate + 24 + 128 + 24;
      Option.iter (Map.find t.cache key) ~f:(fun prepared ->
        let prepared = Search.rebind prepared candidate in
        chunk.(offset) <- Some prepared;
        snapshot.retained <- Map.set snapshot.retained ~key ~data:prepared;
        snapshot.prepared_bytes <- snapshot.prepared_bytes + Search.ownership_bytes prepared + 128);
      Index.Identity.Builder.append snapshot.identities candidate;
      Index.Builder.append_indexed snapshot.blank ~ordinal:snapshot.ordinal
        { candidate; score = 0; positions = [] };
      t.indexed_count <- t.indexed_count + 1;
      snapshot.ordinal <- snapshot.ordinal + 1; snapshot.remaining <- rest;
      loop (left - 1)
  in loop budget
;;

let work_static t ~budget =
  if budget <= 0 then invalid_arg "file picker work budget must be positive";
  match t.job, t.snapshot_job with
  | None, _ -> ()
  | Some _, Some snapshot -> work_snapshot t snapshot ~budget
  | Some { kind = Reuse results; _ }, None ->
    t.cache_hits <- t.cache_hits + 1;
    publish t results
  | Some job, None when Search.is_blank job.query -> publish t (Option.value_exn t.blank_results)
  | Some job, None ->
    match job.output with
    | None ->
      let examine ordinal candidate =
          let chunk_number = ordinal / 128 in
          if chunk_number <> job.chunk_number then (
            job.prepared_chunk <- Map.find_exn t.prepared_chunks chunk_number;
            job.chunk_number <- chunk_number);
          let offset = ordinal % 128 in
          let prepared = match job.prepared_chunk.(offset) with
            | Some prepared -> prepared
            | None ->
              let prepared = Search.prepare_candidate candidate in
              t.prepared_count <- t.prepared_count + 1;
              job.prepared_chunk.(offset) <- Some prepared;
              t.cache <- Map.set t.cache ~key:(Model.Candidate.path candidate) ~data:prepared;
              t.prepared_bytes <- t.prepared_bytes + Search.ownership_bytes prepared + 128;
              prepared in
          let score = Search.score job.scratch job.query prepared in
          t.scored_count <- t.scored_count + 1;
          job.examined <- job.examined + 1;
          if score <> Search.no_match then
            job.ranked <- Map.set job.ranked ~key:(-score, ordinal) ~data:candidate
      in
      let rec loop left =
        if left > 0 then match job.source with
          | Full -> (match job.remaining with
            | [] -> job.output <- Some (Map.to_sequence job.ranked)
            | candidate :: rest ->
              let ordinal = job.ordinal in
              job.ordinal <- ordinal + 1; job.remaining <- rest;
              examine ordinal candidate; loop (left - 1))
          | Narrow sequence -> (match Sequence.next sequence with
            | None -> job.output <- Some (Map.to_sequence job.ranked)
            | Some ((ordinal, candidate), rest) ->
              job.source <- Narrow rest;
              examine ordinal candidate; loop (left - 1))
      in loop budget
    | Some output ->
      let rec loop left sequence =
        if left = 0 then job.output <- Some sequence
        else match Sequence.next sequence with
          | Some (((negative_score, ordinal), candidate), rest) ->
            Index.Builder.append_scored job.results ~ordinal ~candidate ~score:(-negative_score);
            t.indexed_count <- t.indexed_count + 1;
            loop (left - 1) rest
          | None ->
            (* Freeze values, never capture t, job, mutable ordinal slots or scoring
               scratch in a published lazy alignment. Old models remain correct. *)
            let prepared = t.cache and query = job.query in
            let align candidate = Search.positions query
              (Map.find_exn prepared (Model.Candidate.path candidate)) in
            publish t (Index.Builder.finish ~identity:(Option.value_exn t.identity) ~align job.results)
      in loop budget output
;;

let resume_stream t (stream : stream) ~cursor =
  t.job <- Some
    { source = Full; remaining = []; ordinal = cursor; kind = Rank; examined = 0
    ; query = stream.query; scratch = stream.scratch; ranked = Map.empty (module Rank_key)
    ; output = None; results = Index.Builder.create (); chunk_number = -1
    ; prepared_chunk = [||]; tail_from = cursor }
;;

let install_stream_update t (update : Model.Discovery.Update.t) =
  let request = Model.discovery_request t.model in
  if t.closed || not (Model.Discovery.equal_request request update.request) then false
  else (
    let initial = Option.is_none t.stream in
    let valid = match t.stream with
      | None -> Model.discovered_count t.model = 0 && update.base_count = 0
          && Model.Discovery.Candidates.length update.candidates = List.length update.additions
          && update.revision >= 0 && update.revision <= 1
      | Some stream -> update.revision = stream.update.revision + 1
          && phys_equal update.base (Model.Discovery.Candidates.stamp stream.update.candidates)
          && update.base_count = Model.Discovery.Candidates.length stream.update.candidates
          && Model.Discovery.Candidates.length update.candidates = update.base_count + List.length update.additions
    in
    if not valid || not (List.for_all update.additions ~f:(fun c ->
      String.equal (Model.Candidate.root c) request.root)) then false
    else (
      let stream = match t.stream with
        | Some stream -> stream
        | None ->
          let query, scratch = match t.job with
            | Some job -> job.query, job.scratch
            | None -> t.compiled_count <- t.compiled_count + 1; Search.compile t.query, Search.scratch () in
          let stream =
            { update; pending = Queue.create (); arrivals = Int.Map.empty
            ; identities = Index.Identity.Builder.create (); ingested = 0; cursor = 0
            ; ranked = Index.Tree.empty; query; scratch; rebuild = None; retained = None } in
          t.stream <- Some stream; t.snapshot_job <- None;
          t.identity <- None; t.blank_results <- None; t.prepared_chunks <- Int.Map.empty;
          t.corpus_bytes <- 8192; t.prepared_bytes <- 0;
          resume_stream t stream ~cursor:0;
          stream in
      let added = not (List.is_empty update.additions) in
      if initial || added then (
        t.query_cache <- []; t.generation <- t.generation + 1;
        t.identity <- None;
        match t.job with
        | None -> resume_stream t stream ~cursor:stream.cursor
        | Some { kind = Reuse results; _ } ->
          (match Index.tree results with
           | Some tree -> stream.ranked <- tree; stream.cursor <- stream.ingested;
             resume_stream t stream ~cursor:stream.cursor
           | None -> stream.ranked <- Index.Tree.empty; resume_stream t stream ~cursor:0)
        | Some _ -> ());
      if added || initial || not (Model.Discovery.equal_status (Model.discovery_status t.model) update.status) then
        t.visible_revision <- t.visible_revision + 1;
      stream.update <- update;
      List.iter update.additions ~f:(Queue.enqueue stream.pending);
      t.model <- Model.with_update t.model update;
      true))
;;

let ingest t (stream : stream) candidate =
  let ordinal = stream.ingested in
  let block = ordinal / 128 and offset = ordinal % 128 in
  if offset = 0 then (
    stream.arrivals <- Map.set stream.arrivals ~key:block ~data:(Array.create ~len:128 None);
    t.prepared_chunks <- Map.set t.prepared_chunks ~key:block ~data:(Array.create ~len:128 None));
  (Map.find_exn stream.arrivals block).(offset) <- Some candidate;
  Option.iter stream.retained ~f:(fun retained ->
    Option.iter (Map.find t.cache (Model.Candidate.path candidate)) ~f:(fun prepared ->
      let prepared = Search.rebind prepared candidate in
      (Map.find_exn t.prepared_chunks block).(offset) <- Some prepared;
      stream.retained <- Some (Map.set retained ~key:(Model.Candidate.path candidate) ~data:prepared);
      t.prepared_bytes <- t.prepared_bytes + Search.ownership_bytes prepared + 128));
  Index.Identity.Builder.append stream.identities candidate;
  stream.ingested <- ordinal + 1;
  t.corpus_bytes <- t.corpus_bytes + Model.Candidate.ownership_bytes candidate + 24 + 128 + 48;
  t.indexed_count <- t.indexed_count + 1;
  ordinal
;;

let publish_stream t (stream : stream) (job : job) =
  Option.iter stream.retained ~f:(fun retained -> t.cache <- retained);
  stream.retained <- None;
  if t.finish_validation then (
    t.accept_validated <- true; t.finish_validation <- false);
  let identity = match t.identity with Some identity -> identity
    | None -> Index.Identity.Builder.snapshot stream.identities in
  t.identity <- Some identity;
  let root = (Model.discovery_request t.model).root in
  let blank = Index.of_candidates ~root ~identity stream.update.candidates in
  t.blank_results <- Some blank;
  stream.cursor <- job.ordinal;
  let results = if Search.is_blank job.query then blank else (
    let prepared = t.cache and query = job.query in
    let align candidate = Search.positions query (Map.find_exn prepared (Model.Candidate.path candidate)) in
    Index.of_tree ~identity ~root ~align stream.ranked) in
  publish t results
;;

let work_stream t (stream : stream) (job : job) ~budget =
  let examine ordinal candidate =
    if not (Search.is_blank job.query) then (
      let block = ordinal / 128 in
      let chunk = Map.find_exn t.prepared_chunks block in
      let offset = ordinal % 128 in
      let prepared = match chunk.(offset) with
        | Some prepared -> prepared
        | None ->
          let chunk = if Set.mem t.frozen_prepared block then (
            let copied = Array.copy chunk in
            t.prepared_chunks <- Map.set t.prepared_chunks ~key:block ~data:copied;
            t.frozen_prepared <- Set.remove t.frozen_prepared block;
            copied) else chunk in
          let prepared = Search.prepare_candidate candidate in
          chunk.(offset) <- Some prepared;
          t.cache <- Map.set t.cache ~key:(Model.Candidate.path candidate) ~data:prepared;
          t.prepared_count <- t.prepared_count + 1;
          t.prepared_bytes <- t.prepared_bytes + Search.ownership_bytes prepared + 128;
          Option.iter stream.retained ~f:(fun retained ->
            stream.retained <- Some (Map.set retained ~key:(Model.Candidate.path candidate) ~data:prepared));
          prepared in
      let score = Search.score job.scratch job.query prepared in
      t.scored_count <- t.scored_count + 1; job.examined <- job.examined + 1;
      if score <> Search.no_match then stream.ranked <- Index.Tree.add stream.ranked ~ordinal ~candidate ~score)
  in
  let rec loop left =
    match job.source with
    | Narrow sequence when left > 0 ->
      (match Sequence.next sequence with
       | Some ((ordinal, candidate), rest) -> job.source <- Narrow rest;
         examine ordinal candidate; loop (left - 1)
       | None -> job.source <- Full; job.ordinal <- job.tail_from; loop left)
    | Narrow _ -> ()
    | Full ->
      if Queue.is_empty stream.pending then Option.iter stream.rebuild ~f:(fun sequence ->
        match Sequence.next sequence with
        | None -> stream.rebuild <- None
        | Some (candidate, rest) -> stream.rebuild <- Some rest; Queue.enqueue stream.pending candidate);
      if job.ordinal >= stream.ingested && Queue.is_empty stream.pending && Option.is_none stream.rebuild then publish_stream t stream job
      else if left > 0 then (
        let ordinal, candidate = if job.ordinal < stream.ingested then
          job.ordinal, Option.value_exn (Map.find_exn stream.arrivals (job.ordinal / 128)).(job.ordinal % 128)
        else (
          let candidate = Queue.dequeue_exn stream.pending in
          ingest t stream candidate, candidate) in
        job.ordinal <- ordinal + 1;
        examine ordinal candidate; loop (left - 1))
  in
  match job.kind with
  | Reuse results ->
    stream.ranked <- Option.value (Index.tree results) ~default:Index.Tree.empty;
    stream.cursor <- stream.ingested;
    t.cache_hits <- t.cache_hits + 1; publish t results
  | Rank -> loop budget
;;

let work t ~budget =
  if budget <= 0 then invalid_arg "file picker work budget must be positive";
  match t.stream, t.job with
  | Some stream, Some job -> work_stream t stream job ~budget
  | Some _, None -> ()
  | None, _ -> work_static t ~budget
;;

module Snapshot = struct
  type t = snapshot
  let candidates t = t.candidates
  let bytes t = t.bytes
end

let snapshot t =
  match t.stream, t.identity, t.blank_results, Model.discovery_status t.model with
  | Some stream, Some identity, Some blank, Complete { truncated = false }
    when not t.closed && not (busy t) && t.accept_validated && Option.is_none t.refresh ->
    let bytes = owned_base_bytes t + List.sum (module Int) t.query_cache ~f:(fun q -> q.bytes)
      + 8192 in
    Some { candidates = stream.update.candidates; arrivals = stream.arrivals
         ; prepared_slots = Map.map t.prepared_chunks ~f:Array.copy; prepared = t.cache
         ; identity; blank; queries = t.query_cache
         ; corpus_bytes = t.corpus_bytes; prepared_bytes = t.prepared_bytes; bytes }
  | _ -> None
;;
let set_snapshot_sink t sink = t.on_snapshot <- Some sink

let restore_snapshot t (saved : snapshot) (initial : Model.Discovery.Update.t) =
  if t.closed || not (Model.Discovery.equal_request (Model.discovery_request t.model) initial.request)
     || initial.revision <> 0 || Model.Discovery.Candidates.length initial.candidates <> 0
  then false else (
    let cached_update = { initial with candidates = saved.candidates; status = Loading } in
    let stream =
      { update = cached_update; pending = Queue.create (); arrivals = saved.arrivals
      ; identities = Index.Identity.Builder.of_snapshot saved.identity
      ; ingested = Model.Discovery.Candidates.length saved.candidates
      ; cursor = Model.Discovery.Candidates.length saved.candidates; ranked = Index.Tree.empty
      ; query = Search.compile ""; scratch = Search.scratch (); rebuild = None; retained = None } in
    t.stream <- Some stream; t.snapshot_job <- None; t.job <- None;
    t.cache <- saved.prepared; t.prepared_chunks <- saved.prepared_slots;
    t.frozen_prepared <- Int.Set.of_list (Map.keys saved.prepared_slots);
    t.identity <- Some saved.identity; t.blank_results <- Some saved.blank;
    t.corpus_bytes <- saved.corpus_bytes; t.prepared_bytes <- saved.prepared_bytes;
    t.generation <- t.generation + 1;
    t.query_cache <- List.map saved.queries ~f:(fun q -> { q with generation = t.generation });
    t.query <- "";
    t.model <- Model.with_result_index (Model.with_update t.model cached_update) ~query:"" saved.blank;
    t.refresh <- Some { incoming = initial; old = saved; unchanged = 0; changed = false };
    t.accept_validated <- false;
    t.visible_revision <- t.visible_revision + 1;
    true)
;;

let install_refresh_update t (refresh : refresh) (update : Model.Discovery.Update.t) =
  let previous = refresh.incoming in
  if t.closed || not (Model.Discovery.equal_request (Model.discovery_request t.model) update.request)
     || update.revision <> previous.revision + 1
     || not (phys_equal update.base (Model.Discovery.Candidates.stamp previous.candidates))
     || update.base_count <> Model.Discovery.Candidates.length previous.candidates
     || Model.Discovery.Candidates.length update.candidates <> update.base_count + List.length update.additions
  then false else (
    List.iter update.additions ~f:(fun candidate ->
      match Model.Discovery.Candidates.find refresh.old.candidates (Model.Candidate.relative_path candidate) with
      | Some cached when Model.Candidate.Id.equal (Model.Candidate.id cached) (Model.Candidate.id candidate) ->
        refresh.unchanged <- refresh.unchanged + 1
      | _ -> refresh.changed <- true);
    refresh.incoming <- update;
    t.visible_revision <- t.visible_revision + 1;
    match update.status with
    | Loading | Partial ->
      let stream = Option.value_exn t.stream in
      t.model <- Model.with_update t.model { stream.update with status = update.status };
      true
    | Complete _ | Failed _ | Cancelled ->
      let success = Model.Discovery.equal_status update.status (Complete { truncated = false }) in
      let same = success && not refresh.changed
        && refresh.unchanged = Model.Discovery.Candidates.length refresh.old.candidates in
      t.refresh <- None;
      if same then (
        let stream = Option.value_exn t.stream in
        stream.update <- { update with candidates = refresh.old.candidates };
        t.model <- Model.with_update t.model stream.update;
        t.accept_validated <- true)
      else (
        let query = Search.compile t.query in
        t.compiled_count <- t.compiled_count + 1;
        let stream =
          { update; pending = Queue.create (); arrivals = Int.Map.empty
          ; identities = Index.Identity.Builder.create (); ingested = 0; cursor = 0
          ; ranked = Index.Tree.empty; query; scratch = Search.scratch ()
          ; rebuild = Some (Model.Discovery.Candidates.sequence update.candidates); retained = Some String.Map.empty } in
        t.stream <- Some stream; t.snapshot_job <- None; t.identity <- None; t.blank_results <- None;
        t.prepared_chunks <- Int.Map.empty; t.frozen_prepared <- Int.Set.empty;
        t.prepared_bytes <- 0; t.corpus_bytes <- 8192; t.query_cache <- []; t.generation <- t.generation + 1;
        t.finish_validation <- success;
        t.model <- Model.with_update t.model update;
        resume_stream t stream ~cursor:0);
      true)
;;
let install_update t update = match t.refresh with
  | Some refresh -> install_refresh_update t refresh update
  | None -> install_stream_update t update
;;

let close t ~release =
  let saved = Option.bind t.on_snapshot ~f:(fun _ -> snapshot t) in
  let sink = t.on_snapshot in
  t.on_snapshot <- None;
  t.closed <- true; t.job <- None; t.snapshot_job <- None; t.identity <- None;
  t.cache <- String.Map.empty; t.prepared_chunks <- Int.Map.empty; t.blank_results <- None;
  t.query_cache <- []; t.corpus_bytes <- 0; t.prepared_bytes <- 0;
  t.stream <- None;
  t.refresh <- None; t.frozen_prepared <- Int.Set.empty;
  t.visible_revision <- t.visible_revision + 1;
  let request = Model.discovery_request t.model in
  t.model <- Model.create ~token:(Model.token t.model)
    ~discovery:{ request; candidates = []; status = Cancelled };
  Option.iter saved ~f:(fun saved -> Option.iter sink ~f:(fun sink -> sink saved));
  release ()
;;
let cancel t ~release = if not t.closed then close t ~release
let accept t ~release ~consume =
  if not t.closed && not (busy t) && t.accept_validated then Option.iter (Model.accept t.model) ~f:(fun request ->
    close t ~release; consume request)
;;
