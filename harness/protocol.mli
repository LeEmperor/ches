open! Core

(** 
  Requests snapshot dirty paths so the host can refuse stale on-disk runs for
  the selected project while preserving unrelated unsaved buffers. 
*)
type work = 
  { action : string
  ; location : string
  ; dirty : string list 
  } [@@deriving sexp_of]
  
type run =
  { run_id : string
  ; status : string
  ; exit_code : int
  ; project_root : string
  ; log_path : string
  ; waveform : string option 
  } [@@deriving sexp_of]
  
type reply = 
  | Created of 
    { root : string
    ; entry : string
    }
  | Finished of run
[@@deriving sexp_of]

(** 
  Decode [qh new/run/latest --format json]. A failed run is still a [Finished]
  result; CLI errors without a run record are errors. 
*)
val parse : string -> reply Or_error.t
