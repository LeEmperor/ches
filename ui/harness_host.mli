open! Core

(** One asynchronous qh operation per editor instance. Uses argv, never a shell.
    QH_BIN overrides the executable; otherwise ~/devel/Quick-Harness/bin/qh, then
    qh on PATH. QH_SCRATCH_ROOT overrides ~/scratch/ches. Each new scratch lives in
    an atomically reserved unique container with a nonexistent [project] child.
    Runs use six jobs and qh's default timeout; latest reads persisted JSON.
    Waveform I/O/parsing happens off the UI thread. *)
type t
val create : unit -> t
val execute
  : t -> Ches_harness.Protocol.work
  -> (Ches_harness.Protocol.reply * (Ches_harness.Vcd.t, string) Result.t option, string) Result.t Async.Deferred.t
(** Interrupts qh, which terminates its active tool process group and saves a result. *)
val stop : t -> unit
