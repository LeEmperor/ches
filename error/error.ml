open! Core

module Severity = struct
  type t =
    | Info
    | Warning
    | Error
  [@@deriving sexp_of, equal]
end

module Identity = struct
  type kind =
    | Save
    | Reload
  [@@deriving sexp_of, equal]

  type t =
    { source : string
    ; kind : kind
    ; resource : string
    }
  [@@deriving sexp_of, equal]
end

module Notification = struct
  type t =
    { source : string
    ; scope : string option
    ; severity : Severity.t
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

module Problem = struct
  type t =
    { identity : Identity.t
    ; severity : Severity.t
    ; text : string
    ; attention : bool
    }
  [@@deriving sexp_of, equal]
end

type t =
  { problems : Problem.t list
  ; transient : Notification.t option
  ; details : Identity.t option
  }
[@@deriving sexp_of]

type update =
  | Notify of Notification.t
  | Failed of Identity.t * Severity.t * string
  | Resolve of Identity.t
  | Command_completed
  | Acknowledge
  | Inspect_next
[@@deriving sexp_of]

let empty = { problems = []; transient = None; details = None }
let problems t = t.problems

(* First occurrence order is stable, including updates after acknowledgement. *)
let presented_problem t =
  match
    Option.bind t.details ~f:(fun identity ->
      List.find t.problems ~f:(fun p -> Identity.equal p.identity identity))
  with
  | Some _ as problem -> problem
  | None -> List.find t.problems ~f:(fun p -> p.attention)
;;

let apply t = function
  | Notify transient -> { t with transient = Some transient }
  | Command_completed -> { t with transient = None; details = None }
  | Failed (identity, severity, text) ->
    let problem = { Problem.identity; severity; text; attention = true } in
    let exists =
      List.exists t.problems ~f:(fun p -> Identity.equal p.identity identity)
    in
    let problems =
      if exists
      then
        List.map t.problems ~f:(fun p ->
          if Identity.equal p.identity identity then problem else p)
      else t.problems @ [ problem ]
    in
    { t with problems }
  | Resolve identity ->
    { t with
      problems =
        List.filter t.problems ~f:(fun p -> not (Identity.equal p.identity identity))
    ; details = Option.filter t.details ~f:(fun key -> not (Identity.equal key identity))
    }
  | Acknowledge ->
    let problems =
      match presented_problem t with
      | None -> t.problems
      | Some current ->
        List.map t.problems ~f:(fun p ->
          if Identity.equal p.identity current.identity
          then { p with attention = false }
          else p)
    in
    { t with problems; details = None }
  | Inspect_next ->
    let next =
      match t.details with
      | None -> List.hd t.problems
      | Some identity ->
        let rest =
          List.drop_while t.problems ~f:(fun p ->
            not (Identity.equal p.identity identity))
        in
        (match rest with
         | _ :: next :: _ -> Some next
         | _ -> List.hd t.problems)
    in
    { t with details = Option.map next ~f:(fun p -> p.identity) }
;;

let notification t =
  match presented_problem t with
  | Some p ->
    Some
      { Notification.source = p.identity.source
      ; scope = Some p.identity.resource
      ; severity = p.severity
      ; text = p.text
      }
  | None -> t.transient
;;
