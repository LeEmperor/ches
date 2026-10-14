open! Core

module Candidate = struct
  module Id = struct
    type t = string [@@deriving sexp_of, equal, compare]

    let to_string t = t
  end

  type t =
    { root : string
    ; path : string
    ; relative_path : string
    ; display_path : string
    }
  [@@deriving sexp_of, fields ~getters]

  let id t = t.path
  let ownership_bytes t = 192 + String.length t.root + String.length t.path
    + String.length t.relative_path + String.length t.display_path
  ;;

  let display_path_of_bytes ?(on_scalar = fun _ _ _ -> ()) s =
    let buffer = Buffer.create (String.length s) in
    let escape pos length =
      for i = pos to pos + length - 1 do
        Buffer.add_string buffer (sprintf "\\x%02X" (Char.to_int s.[i]))
      done
    in
    let rec loop pos =
      if pos < String.length s
      then (
        let decoded = Stdlib.String.get_utf_8_uchar s pos in
        let length = Stdlib.Uchar.utf_decode_length decoded in
        let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
        let start = Buffer.length buffer in
        if not (Stdlib.Uchar.utf_decode_is_valid decoded)
           || scalar <= 0x1F
           || (scalar >= 0x7F && scalar <= 0x9F)
           || scalar = 0x2028
           || scalar = 0x2029
        then escape pos length
        else if scalar = 0x5C
        then Buffer.add_string buffer "\\\\"
        else Buffer.add_substring buffer s ~pos ~len:length;
        on_scalar pos start (Buffer.length buffer - start);
        loop (pos + length))
    in
    loop 0;
    Buffer.contents buffer
  ;;

  let display_positions t ~raw_positions =
    if String.equal t.relative_path t.display_path
    then List.dedup_and_sort raw_positions ~compare:Int.compare
    else (
      let wanted = Int.Set.of_list raw_positions in
      let positions = ref [] in
      let (_ : string) =
        display_path_of_bytes t.relative_path ~on_scalar:(fun raw start length ->
          if Set.mem wanted raw
          then (
            let decoded = Stdlib.String.get_utf_8_uchar t.relative_path raw in
            let raw_length = Stdlib.Uchar.utf_decode_length decoded in
            (* Escapes consist of ASCII characters; mark the entire representation.
               Unescaped UTF-8 contributes only its code-point start. *)
            if length <> raw_length || not (Stdlib.Uchar.utf_decode_is_valid decoded)
            then
              for offset = start to start + length - 1 do
                positions := offset :: !positions
              done
            else positions := start :: !positions))
      in
      List.dedup_and_sort !positions ~compare:Int.compare)
  ;;

  let display_text s = display_path_of_bytes s

  let create ~root ~relative_path =
    if String.is_empty root || not (Char.equal root.[0] '/')
    then Or_error.error_string "File picker root must be absolute"
    else if String.mem root '\000' || String.mem relative_path '\000'
    then Or_error.error_string "File picker paths cannot contain NUL"
    else if
      List.exists (String.split relative_path ~on:'/') ~f:(fun component ->
        String.is_empty component
        || String.equal component "."
        || String.equal component "..")
    then Or_error.error_string "File picker candidate must be a normalized relative path"
    else (
      let root = String.rstrip root ~drop:(Char.equal '/') in
      let root = if String.is_empty root then "/" else root in
      let separator = if String.equal root "/" then "" else "/" in
      Ok
        { root
        ; path = root ^ separator ^ relative_path
        ; relative_path
        ; display_path = display_path_of_bytes relative_path
        })
  ;;
end

module Run_id = struct
  type t = int [@@deriving sexp_of, equal]

  let of_int t = t
end

module Discovery = struct
  module Candidates = struct
    type stamp = unit ref
    let sexp_of_stamp _ = Sexp.Atom "candidate-set"
    type t = { paths : Candidate.t String.Map.t; stamp : stamp; list : Candidate.t list Lazy.t }
    let create () = { paths = String.Map.empty; stamp = ref (); list = lazy [] }
    let length t = Map.length t.paths
    let stamp t = t.stamp
    let sexp_of_t t = [%sexp (length t : int)]
    let to_list t = Lazy.force t.list
    let nth t i = Option.map (Map.nth t.paths i) ~f:snd
    let rank t path = Map.rank t.paths path
    let find t path = Map.find t.paths path
    let sequence t = Sequence.map (Map.to_sequence t.paths) ~f:snd
    let materialized t = Lazy.is_val t.list
    let append t candidates =
      let paths, added = List.fold candidates ~init:(t.paths, []) ~f:(fun (paths, added) c ->
        let key = Candidate.relative_path c in
        match Map.add paths ~key ~data:c with
        | `Duplicate -> paths, added
        | `Ok paths -> paths, c :: added) in
      if List.is_empty added then t, [] else
        { paths; stamp = ref (); list = lazy (Map.data paths) }, List.rev added
    ;;
  end
  type request =
    { run_id : Run_id.t
    ; root : string
    }
   [@@deriving sexp_of, equal]

  type status =
    | Loading
    | Partial
    | Complete of { truncated : bool }
    | Failed of string
    | Cancelled
  [@@deriving sexp_of, equal]

  type t =
    { request : request
    ; candidates : Candidate.t list
    ; status : status
    }
  [@@deriving sexp_of]

  module Update = struct
    type t =
      { request : request; revision : int; base : Candidates.stamp; base_count : int
      ; candidates : Candidates.t; additions : Candidate.t list; status : status }
    [@@deriving sexp_of]
    let initial request =
      let candidates = Candidates.create () in
      { request; revision = 0; base = Candidates.stamp candidates; base_count = 0
      ; candidates; additions = []; status = Loading }
    let append t ~status candidates =
      let next, additions = Candidates.append t.candidates candidates in
      { request = t.request; revision = t.revision + 1; base = Candidates.stamp t.candidates
      ; base_count = Candidates.length t.candidates; candidates = next; additions; status }
    ;;
  end
end

module Query_result = struct
  type t =
    { candidate : Candidate.t
    ; score : int
    ; positions : int list
    }
  [@@deriving sexp_of]
end

module Request = struct
  type 'token t =
    { token : 'token
    ; path : string
    }
  [@@deriving sexp_of]
end

(* Fixed-size chunks avoid corpus-sized array allocations/copies at publication.
   Published rows/identity are immutable; only bounded exact-alignment memoization
   is mutable, and cannot change the logical content of a query snapshot. *)
module Result_index = struct
  let chunk_size = 128
  module Identity = struct
    type t = { ordinals : int String.Map.t; count : int }
    module Builder = struct
      type identity = t
      type t = { mutable ordinals : int String.Map.t; mutable count : int; mutable finished : bool }
      let create () = { ordinals = String.Map.empty; count = 0; finished = false }
      let append t candidate =
        if t.finished then invalid_arg "Published file identity index";
        let key = Candidate.Id.to_string (Candidate.id candidate) in
        (match Map.add t.ordinals ~key ~data:t.count with
         | `Ok ordinals -> t.ordinals <- ordinals | `Duplicate -> ());
        t.count <- t.count + 1
      ;;
      let finish t : identity =
        t.finished <- true;
        { ordinals = t.ordinals; count = t.count }
      ;;
      let snapshot t : identity = { ordinals = t.ordinals; count = t.count }
      let of_snapshot (identity : identity) =
        { ordinals = identity.ordinals; count = identity.count; finished = false }
    end
  end
  type row = Eager of Query_result.t | Scored of Candidate.t * int * int
  module Tree = struct
    module Key = struct
      module T = struct type t = int * string [@@deriving sexp, compare] end
      include T
      include Comparator.Make (T)
    end
    type t = { ranked : row Map.M(Key).t; scores : int array Int.Map.t }
    let empty = { ranked = Map.empty (module Key); scores = Int.Map.empty }
    let add t ~ordinal ~candidate ~score =
      let block = ordinal / chunk_size in
      let scores, chunk = match Map.find t.scores block with
        | Some chunk -> t.scores, chunk
        | None -> let chunk = Array.create ~len:chunk_size Int.min_value in
          Map.set t.scores ~key:block ~data:chunk, chunk in
      if chunk.(ordinal % chunk_size) <> Int.min_value || score = Int.min_value then
        invalid_arg "Streaming score slots are append-only";
      chunk.(ordinal % chunk_size) <- score;
      { ranked = Map.set t.ranked ~key:(-score, Candidate.relative_path candidate)
          ~data:(Scored (candidate, score, ordinal)); scores }
    ;;
  end
  let alignment_byte_limit = 256 * 1024
  type t =
    { chunks : row option array Int.Map.t
    ; by_id : int String.Map.t
    ; identity : Identity.t option
    ; ordinal_positions : int array Int.Map.t
    ; count : int
    ; align : Candidate.t -> int list
    ; cache : (Query_result.t * int) Int.Table.t
    ; cached_order : int Queue.t
    ; mutable alignment_count : int
    ; mutable alignment_bytes : int
    ; alignment_byte_limit : int
    ; eager_position_bytes : int
    ; tree : Tree.t option
    ; plain : (string * Discovery.Candidates.t) option
    ; tree_root : string option
    }

  let make ~chunks ~by_id ~identity ~ordinal_positions ~count ~align
      ~alignment_byte_limit ~eager_position_bytes ~tree ~plain ~tree_root =
    { chunks; by_id; identity; ordinal_positions; count; align
    ; cache = Int.Table.create (); cached_order = Queue.create (); alignment_count = 0
    ; alignment_bytes = 0; alignment_byte_limit; eager_position_bytes; tree; plain; tree_root }
  let empty = make ~chunks:Int.Map.empty ~by_id:String.Map.empty ~identity:None
    ~ordinal_positions:Int.Map.empty ~count:0 ~align:(fun _ -> [])
    ~alignment_byte_limit ~eager_position_bytes:0 ~tree:None ~plain:None ~tree_root:None
  let length t = t.count
  let raw t index =
    if index < 0 || index >= t.count then None
    else match t.tree, t.plain with
      | Some tree, _ -> Option.map (Map.nth tree.ranked index) ~f:snd
      | _, Some (_, candidates) -> Option.map (Discovery.Candidates.nth candidates index)
          ~f:(fun candidate -> Eager { candidate; score = 0; positions = [] })
      | None, None -> Option.bind (Map.find t.chunks (index / chunk_size))
          ~f:(fun chunk -> chunk.(index % chunk_size))
  ;;
  let candidate = function Eager r -> r.Query_result.candidate | Scored (candidate, _, _) -> candidate
  let get t index =
    Option.map (raw t index) ~f:(function
      | Eager result -> result
      | Scored (candidate, score, _) ->
        (match Hashtbl.find t.cache index with
         | Some (result, _) -> result
         | None ->
           let positions = t.align candidate in
           t.alignment_count <- t.alignment_count + 1;
           let result = { Query_result.candidate; score; positions } in
           let bytes = 128 + 32 * List.length positions in
           if bytes <= t.alignment_byte_limit then (
             while Queue.length t.cached_order >= 128
                   || t.alignment_bytes + bytes > t.alignment_byte_limit do
               let key = Queue.dequeue_exn t.cached_order in
               let _, charged = Hashtbl.find_exn t.cache key in
               Hashtbl.remove t.cache key;
               t.alignment_bytes <- t.alignment_bytes - charged
             done;
             Queue.enqueue t.cached_order index;
             Hashtbl.set t.cache ~key:index ~data:(result, bytes);
             t.alignment_bytes <- t.alignment_bytes + bytes);
           result))
  ;;
  let find t id =
    let key = Candidate.Id.to_string id in
    let relative root = String.chop_prefix key ~prefix:(if String.equal root "/" then "/" else root ^ "/") in
    match t.plain, t.tree, t.identity with
    | Some (root, candidates), _, _ -> Option.bind (relative root) ~f:(Discovery.Candidates.rank candidates)
    | _, Some tree, Some identity ->
      Option.bind (Map.find identity.ordinals key) ~f:(fun ordinal ->
        Option.bind (Map.find tree.scores (ordinal / chunk_size)) ~f:(fun chunk ->
          let score = chunk.(ordinal % chunk_size) in
          if score = Int.min_value then None else
            Option.bind (relative (Option.value_exn t.tree_root)) ~f:(fun path ->
              Map.rank tree.ranked (-score, path))))
    | _, _, None -> Map.find t.by_id key
    | _, _, Some identity ->
      Option.bind (Map.find identity.ordinals key) ~f:(fun ordinal ->
        Option.bind (Map.find t.ordinal_positions (ordinal / chunk_size)) ~f:(fun chunk ->
          Option.some_if (chunk.(ordinal % chunk_size) >= 0) chunk.(ordinal % chunk_size)))
  ;;
  let to_list t =
    List.init t.count ~f:(fun i -> Option.value_exn (get t i))
  ;;
  let belongs_to t identity = Option.exists t.identity ~f:(phys_equal identity)
  let metadata t =
    Sequence.unfold ~init:0 ~f:(fun position ->
      Option.map (raw t position) ~f:(fun row ->
        let candidate = candidate row in
        let ordinal = match row with
          | Scored (_, _, ordinal) -> ordinal
          | Eager _ -> (match t.identity with
            | None -> position
            | Some identity -> Map.find_exn identity.ordinals (Candidate.Id.to_string (Candidate.id candidate))) in
        (ordinal, candidate), position + 1))
  ;;
  (* Excludes shared corpus/identity/preparation/query, charged by the owner once.
     Reserve the full future alignment payload so reads cannot overrun an LRU budget.
     Counts include array slack, map nodes and generous 64-bit object headers. *)
  let retained_bytes t =
    8192 + t.alignment_byte_limit + t.eager_position_bytes
    + (if Option.is_some t.plain then 0 else 96 * t.count)
    + (128 * 8 + 128) * (Map.length t.chunks + Map.length t.ordinal_positions)
    + 128 * Map.length t.by_id
    + Option.value_map t.tree ~default:0 ~f:(fun tree ->
        160 * Map.length tree.ranked + (128 * 8 + 128) * Map.length tree.scores)
    + Option.value_map t.plain ~default:0 ~f:(fun (_, set) -> 128 * Discovery.Candidates.length set)
  ;;

  module Builder = struct
    type index = t
    type t =
      { mutable chunks : row option array Int.Map.t
      ; mutable by_id : int String.Map.t
      ; mutable ordinal_positions : int array Int.Map.t
      ; mutable ordinal_chunk : int
      ; mutable current_positions : int array
      ; mutable count : int
      ; mutable current : row option array
      ; mutable scored : bool
      ; mutable maximum_ordinal : int
      ; mutable finished : bool
      ; mutable eager_position_bytes : int
      }
    let create () =
      { chunks = Int.Map.empty; by_id = String.Map.empty; count = 0
      ; ordinal_positions = Int.Map.empty; ordinal_chunk = -1; current_positions = [||]
      ; scored = false; maximum_ordinal = -1
      ; current = [||]; finished = false; eager_position_bytes = 0 }
    ;;
    let append_row t row =
      if t.finished then invalid_arg "Cannot append to a published file-picker index";
      let offset = t.count % chunk_size in
      if offset = 0 then (
        t.current <- Array.create ~len:chunk_size None;
        t.chunks <- Map.set t.chunks ~key:(t.count / chunk_size) ~data:t.current);
      t.current.(offset) <- Some row
    ;;
    let append t (result : Query_result.t) =
      append_row t (Eager result);
      t.eager_position_bytes <- t.eager_position_bytes + 32 * List.length result.positions;
      let key = Candidate.Id.to_string (Candidate.id result.candidate) in
      (match Map.add t.by_id ~key ~data:t.count with
       | `Ok by_id -> t.by_id <- by_id
       | `Duplicate -> ());
      t.count <- t.count + 1
    ;;
    let append_ordinal t ordinal row =
      if ordinal < 0 then invalid_arg "Negative file-picker ordinal";
      append_row t row;
      let chunk = ordinal / chunk_size in
      if chunk <> t.ordinal_chunk then (
        t.current_positions <- (match Map.find t.ordinal_positions chunk with
          | Some positions -> positions
          | None ->
            let positions = Array.create ~len:chunk_size (-1) in
            t.ordinal_positions <- Map.set t.ordinal_positions ~key:chunk ~data:positions;
            positions);
        t.ordinal_chunk <- chunk);
      t.current_positions.(ordinal % chunk_size) <- t.count;
      t.maximum_ordinal <- Int.max ordinal t.maximum_ordinal;
      t.count <- t.count + 1
    ;;
    let append_indexed t ~ordinal (result : Query_result.t) =
      append_ordinal t ordinal (Eager result);
      t.eager_position_bytes <- t.eager_position_bytes + 32 * List.length result.positions
    let append_scored t ~ordinal ~candidate ~score =
      append_ordinal t ordinal (Scored (candidate, score, ordinal));
      t.scored <- true
    ;;
    let finish ?identity ?align ?(alignment_byte_limit = alignment_byte_limit) t : index =
      if alignment_byte_limit < 0 || alignment_byte_limit > 256 * 1024 then
        invalid_arg "File-picker alignment byte limit";
      if t.maximum_ordinal >= 0 &&
         not (Option.exists identity ~f:(fun identity -> t.maximum_ordinal < identity.Identity.count))
      then invalid_arg "File-picker ordinal index requires its snapshot identity";
      if t.scored && Option.is_none align then invalid_arg "Scored file rows require an exact aligner";
      t.finished <- true;
      make ~chunks:t.chunks ~by_id:t.by_id ~count:t.count ~identity
        ~ordinal_positions:t.ordinal_positions ~align:(Option.value align ~default:(fun _ -> []))
        ~alignment_byte_limit ~eager_position_bytes:t.eager_position_bytes ~tree:None ~plain:None ~tree_root:None
    ;;
  end
  let of_tree ~identity ~root ~align tree =
    make ~chunks:Int.Map.empty ~by_id:String.Map.empty ~identity:(Some identity)
      ~ordinal_positions:Int.Map.empty ~count:(Map.length tree.Tree.ranked) ~align
      ~alignment_byte_limit ~eager_position_bytes:0 ~tree:(Some tree) ~plain:None ~tree_root:(Some root)
  let of_candidates ~root ~identity candidates =
    make ~chunks:Int.Map.empty ~by_id:String.Map.empty ~identity:(Some identity)
      ~ordinal_positions:Int.Map.empty ~count:(Discovery.Candidates.length candidates) ~align:(fun _ -> [])
      ~alignment_byte_limit:0 ~eager_position_bytes:0 ~tree:None ~plain:(Some (root, candidates)) ~tree_root:None
  let tree t = t.tree
end

type 'token t =
  { token : 'token
  ; discovery_snapshot : Discovery.t Lazy.t
  ; discovery_request : Discovery.request
  ; discovery_status : Discovery.status
  ; discovered_count : int
  ; query : string
  ; index : Result_index.t
  ; result_list : Query_result.t list Lazy.t
  ; selection : int option
  ; indexed_reads : int ref
  }
[@@deriving fields ~getters]

let create ~token ~discovery =
  { token; discovery_snapshot = lazy discovery; discovery_request = discovery.Discovery.request
  ; discovery_status = discovery.status; discovered_count = List.length discovery.candidates
  ; query = ""; index = Result_index.empty; result_list = lazy []; selection = None
  ; indexed_reads = ref 0 }
;;

let results t = Lazy.force t.result_list
let result_index t = t.index
let discovery t = Lazy.force t.discovery_snapshot
let result_count t = Result_index.length t.index
let selected_index t = t.selection
let result_at t index =
  incr t.indexed_reads;
  Result_index.get t.index index
;;
let selected_result t = Option.bind t.selection ~f:(result_at t)
let selected_candidate t = Option.bind t.selection ~f:(fun index ->
  incr t.indexed_reads;
  Option.map (Result_index.raw t.index index) ~f:Result_index.candidate)
let selected t = Option.map (selected_candidate t) ~f:Candidate.id
let result_slice t ~start ~length =
  let start = Int.clamp_exn start ~min:0 ~max:(result_count t) in
  List.init (Int.min (Int.max 0 length) (result_count t - start))
    ~f:(fun offset -> Option.value_exn (result_at t (start + offset)))
;;

let with_discovery t discovery =
  let discovered_count =
    if Lazy.is_val t.discovery_snapshot && phys_equal (Lazy.force t.discovery_snapshot).candidates discovery.Discovery.candidates
    then t.discovered_count else List.length discovery.candidates in
  { t with discovery_snapshot = lazy discovery; discovery_request = discovery.request
  ; discovery_status = discovery.status; discovered_count }
;;
let with_update t (update : Discovery.Update.t) =
  { t with discovery_request = update.request; discovery_status = update.status
  ; discovered_count = Discovery.Candidates.length update.candidates
  ; discovery_snapshot = lazy { Discovery.request = update.request; status = update.status
      ; candidates = Discovery.Candidates.to_list update.candidates } }
;;

let with_result_index t ~query index =
  let selection =
    Option.bind (selected t) ~f:(Result_index.find index)
    |> fun retained -> Option.first_some retained
      (Option.some_if (Result_index.length index > 0) 0) in
  { t with query; index; result_list = lazy (Result_index.to_list index)
  ; selection; indexed_reads = ref 0 }
;;

let with_results t ~query results =
  let builder = Result_index.Builder.create () in
  List.iter results ~f:(Result_index.Builder.append builder);
  let index = Result_index.Builder.finish builder in
  { (with_result_index t ~query index) with result_list = lazy results }
;;

let select_index t index =
  if index >= 0 && index < result_count t then { t with selection = Some index } else t
;;
let select t id =
  Option.value_map (Result_index.find t.index id) ~default:t ~f:(select_index t)
;;

let accept t =
  Option.map (selected_candidate t) ~f:(fun candidate ->
    { Request.token = t.token; path = Candidate.path candidate })
;;

module For_testing = struct
  let results_forced t = Lazy.is_val t.result_list
  let indexed_reads t = !(t.indexed_reads)
  let alignment_count t = t.index.Result_index.alignment_count
  let alignment_cache_size t = Hashtbl.length t.index.Result_index.cache
  let alignment_cache_bytes t = t.index.Result_index.alignment_bytes
  let string_id_insertions t = Map.length t.index.Result_index.by_id
  let same_identity a b = Option.equal phys_equal a.index.Result_index.identity b.index.Result_index.identity
end
