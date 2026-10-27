open! Core

module Detection = struct
  type 'repository t =
    | Found of 'repository
    | Not_a_repository of { cwd : string }
    | No_work_tree of
        { cwd : string
        ; message : string
        }
    | Failed of string
  [@@deriving sexp_of]
end

module Refresh = struct
  type t =
    { ignored : bool
    ; log_limit : int
    }
  [@@deriving sexp, equal]

  let default = { ignored = false; log_limit = 200 }
end

module Summary = struct
  module Upstream = struct
    type t =
      { name : string
      ; ahead : int
      ; behind : int
      ; gone : bool
      }
    [@@deriving sexp, equal]
  end

  type t =
    { branch : string option
    ; revision : string option
    ; upstream : Upstream.t option
    ; operations : string list
    }
  [@@deriving sexp, equal]
end

module Plan = struct
  type t =
    { title : string
    ; steps : Job.Step.t list
    ; rewrites_worktree : bool
    }
  [@@deriving sexp_of]

  module Decision = struct
    type plan = t [@@deriving sexp_of]

    type t =
      | Run of plan
      | Confirm of
          { title : string
          ; message : string
          ; plan : plan
          }
      | Refused of string
    [@@deriving sexp_of]
  end
end

(* Documented in backend.mli. *)
module type S = sig
  val name : string

  module Repository : sig
    type t [@@deriving sexp_of, equal]

    val root : t -> string
  end

  module Snapshot : sig
    type t [@@deriving sexp_of]
  end

  module Item : sig
    type t [@@deriving sexp_of]
  end

  module Diff_target : sig
    type t [@@deriving sexp_of, equal]
  end

  module Action : sig
    type t [@@deriving sexp_of]
  end

  val detect : cwd:string -> Job.Step.t list
  val detected : cwd:string -> Job.Step_report.t list -> Repository.t Detection.t
  val refresh : Repository.t -> Refresh.t -> Job.Step.t list

  val snapshot
    :  Repository.t
    -> Refresh.t
    -> Job.Step_report.t list
    -> Snapshot.t Or_error.t

  val summary : Snapshot.t -> Summary.t
  val panels : Snapshot.t -> Item.t Panel.t list
  val diff_target : Snapshot.t -> Panel.Id.t -> Panel.Position.t -> Diff_target.t option
  val diff : Repository.t -> Diff_target.t -> Job.Step.t list

  val parse_diff
    :  Diff_target.t
    -> Diff.Limits.t
    -> Job.Step_report.t list
    -> Diff.t Or_error.t

  val plan : Repository.t -> Snapshot.t -> Action.t -> Plan.Decision.t
end
