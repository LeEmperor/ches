open! Core
module Candidate = Ches_file_picker.Model.Candidate
module Run_id = Ches_file_picker.Model.Run_id
module Status = Ches_file_picker.Model.Discovery
type request = { run_id : Run_id.t; root : string; query : string }
type hit = { candidate : Candidate.t; line : int; start_byte : int; end_byte : int; text : string }
type snapshot = { request : request; hits : hit list; status : Status.status }
(** Snapshots are provider-owned valid hits: offsets in raw text, matching the
    request literal; paths rooted in request.root. Consumers must not fabricate
    malformed hits. The bounded provider enforces these invariants. *)
(** On-disk intent, NOT editor navigation coordinates. Line is one-based;
    byte_column/end_byte are zero-based raw byte offsets, end exclusive.
    Consumer must open existing, validate expected_text/literal against current
    contents, then convert bytes using the opened document's navigation API.
    Neither display offsets nor rg bytes are display-cell columns. *)
type 'token intent =
  { token : 'token; path : string; line : int; byte_column : int; end_byte : int
  ; expected_text : string; literal : string }
val same_request : request -> request -> bool
val same_hit : hit -> hit -> bool
val payload : hit -> int
val parse : request:request -> string -> hit list Or_error.t
type 'token t
val create : token:'token -> snapshot -> 'token t
val query : _ t -> string
val snapshot : _ t -> snapshot
val selected : _ t -> hit option
val pending : _ t -> bool
val closed : _ t -> bool
val query_truncated : _ t -> bool
(** Host calls expect with the fresh provider request after debounce/start.
    Install requires exact run/root/query identity. Editing immediately disables
    acceptance of old results, even before a replacement request is started. *)
val expect : _ t -> request -> unit
val install : _ t -> snapshot -> bool
val update : _ t -> Ches_palette.Palette.Event.t -> unit
val cancel : _ t -> release:(unit -> unit) -> unit
val accept : 'token t -> release:(unit -> unit) -> consume:('token intent -> unit) -> unit
