open! Core

module Line = struct
  type t =
    { text : string
    ; transient : bool
    }
  [@@deriving sexp, equal]
end

type t =
  | Started of
      { job : Job.Id.t
      ; step : int
      ; spec : Exec.Spec.t
      }
  | Output of
      { job : Job.Id.t
      ; step : int
      ; stream : Exec.Stream.t
      ; line : Line.t
      }
  | Finished of Job.Report.t
[@@deriving sexp, equal]

let job = function
  | Started { job; _ } | Output { job; _ } -> job
  | Finished report -> report.id
;;
