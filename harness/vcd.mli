open! Core

(** Digital demo VCD: scalar/binary four-state changes, scopes, aliases and explicit
    1/10/100 s/ms/us/ns/ps/fs timescales. Values before the first assignment are x.
    Repeated assignments at one timestamp retain the final value (no delta cycles).
    No time conversion to floats is performed.

    Limits: 16 MiB source, 4096 declarations, width 4096, one million changes,
    64 MiB expanded values, timestamps 0..10^12. Unsupported real/string/EVCD,
    dump gating, missing scales and malformed data return errors. *)
val max_bytes : int
val max_tick : int

type signal = { name : string; width : int; changes : (int * string) array }
[@@deriving sexp_of]
type t = { timescale : string; signals : signal array; last : int } [@@deriving sexp_of]
val parse : string -> t Or_error.t
val index_at : signal -> int -> int
val value_at : signal -> int -> string
