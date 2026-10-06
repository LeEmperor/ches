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
    ; history : bool
    }
  [@@deriving sexp_of, equal]
end

module Problem = struct
  module Location = struct
    type t = { line : int; column : int } [@@deriving sexp_of, equal]
  end

  type t =
    { identity : Identity.t
    ; severity : Severity.t
    ; text : string
    ; attention : bool
    ; location : Location.t option
    }
  [@@deriving sexp_of, equal]
end

module History = struct
  module Event = struct
    type t =
      | Notified of Notification.t
      | Reported of
          { identity : Identity.t
          ; severity : Severity.t
          ; text : string
          ; location : Problem.Location.t option
          ; again : bool
          }
      | Resolved of
          { identity : Identity.t
          ; severity : Severity.t
          ; text : string
          }
    [@@deriving sexp_of, equal]

    (* Repeats coalesce whether or not the identity was already active. *)
    let same a b =
      let plain = function
        | Reported r -> Reported { r with again = false }
        | (Notified _ | Resolved _) as event -> event
      in
      equal (plain a) (plain b)
    ;;
  end

  module Entry = struct
    type t =
      { seq : int
      ; event : Event.t
      ; count : int
      }
    [@@deriving sexp_of, equal]
  end

  type t =
    { newest_first : Entry.t list
    ; length : int
    ; next : int
    ; dropped : int
    }
  [@@deriving sexp_of]

  let capacity = 200
  let empty = { newest_first = []; length = 0; next = 1; dropped = 0 }

  let record t event =
    match t.newest_first with
    | newest :: rest when Event.same newest.event event ->
      { t with newest_first = { newest with count = newest.count + 1 } :: rest }
    | _ ->
      let newest_first = { Entry.seq = t.next; event; count = 1 } :: t.newest_first in
      let excess = Int.max 0 (t.length + 1 - capacity) in
      { newest_first = List.take newest_first (t.length + 1 - excess)
      ; length = t.length + 1 - excess
      ; next = t.next + 1
      ; dropped = t.dropped + excess
      }
  ;;

  let clear t = { empty with next = t.next }
  let entries t = List.rev t.newest_first
  let dropped t = t.dropped
end

type t =
  { problems : Problem.t list
  ; transient : Notification.t option
  ; details : Identity.t option
  ; history : History.t
  }
[@@deriving sexp_of]

type update =
  | Notify of Notification.t
  | Failed of Identity.t * Severity.t * string
  | Report of Identity.t * Severity.t * string * Problem.Location.t option
  | Resolve of Identity.t
  | Command_completed
  | Acknowledge
  | Inspect_next
  | Inspect_identity of Identity.t
  | Acknowledge_identity of Identity.t
  | Clear_history
[@@deriving sexp_of]

let empty = { problems = []; transient = None; details = None; history = History.empty }
let problems t = t.problems
let history t = t.history
let find t identity = List.find t.problems ~f:(fun p -> Identity.equal p.identity identity)

(* First occurrence order is stable, including updates after acknowledgement. *)
let presented_problem t =
  match
    Option.bind t.details ~f:(fun identity ->
      List.find t.problems ~f:(fun p -> Identity.equal p.identity identity))
  with
  | Some _ as problem -> problem
  | None -> List.find t.problems ~f:(fun p -> p.attention)
;;

let apply t update =
  let update =
    match update with
    | Failed (identity, severity, text) -> Report (identity, severity, text, None)
    | update -> update
  in
  match update with
  | Inspect_identity identity ->
    if List.exists t.problems ~f:(fun p -> Identity.equal p.identity identity)
    then { t with details = Some identity } else t
  | Acknowledge_identity identity ->
    { t with problems = List.map t.problems ~f:(fun p ->
        if Identity.equal p.identity identity then { p with attention = false } else p) }
  | Notify transient ->
    { t with
      transient = Some transient
    ; history =
        (if transient.history
         then History.record t.history (Notified transient)
         else t.history)
    }
  | Clear_history -> { t with history = History.clear t.history }
  | Command_completed -> { t with transient = None; details = None }
  | Failed _ -> assert false
  | Report (identity, severity, text, location) ->
    let problem = { Problem.identity; severity; text; attention = true; location } in
    let exists = Option.is_some (find t identity) in
    let problems =
      if exists
      then
        List.map t.problems ~f:(fun p ->
          if Identity.equal p.identity identity then problem else p)
      else t.problems @ [ problem ]
    in
    let history =
      History.record
        t.history
        (Reported { identity; severity; text; location; again = exists })
    in
    { t with problems; history }
  | Resolve identity ->
    { t with
      history =
        (match find t identity with
         | None -> t.history
         | Some p ->
           History.record t.history (Resolved { identity; severity = p.severity; text = p.text }))
    ; problems =
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
      ; history = false
      }
  | None -> t.transient
;;
