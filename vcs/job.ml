open! Core

module Id = struct
  module T = struct
    type t =
      { generation : int
      ; sequence : int
      }
    [@@deriving sexp, equal, compare]
  end

  include T
  include Comparable.Make_plain (T)

  let to_string_hum t = sprintf "g%d.%d" t.generation t.sequence
end

module File_read = struct
  type t =
    { path : string
    ; limit : int
    }
  [@@deriving sexp, equal]

  module Result = struct
    type t =
      | Missing
      | Contents of
          { text : string
          ; truncated : bool
          }
      | Failed of string
    [@@deriving sexp, equal]
  end
end

module Step = struct
  type t =
    | Run of Exec.Spec.t
    | Read_file of File_read.t
  [@@deriving sexp, equal]

  let kind = function
    | Run spec -> spec.kind
    | Read_file _ -> Exec.Kind.Read
  ;;

  module Outcome = struct
    type t =
      | Ran of Exec.Result.t
      | Read of File_read.Result.t
      | Skipped
    [@@deriving sexp, equal]
  end
end

module Step_report = struct
  type t =
    { step : Step.t
    ; outcome : Step.Outcome.t
    }
  [@@deriving sexp, equal]

  let succeeded t =
    match t.outcome with
    | Ran result -> Exec.Result.succeeded result
    | Read (Missing | Contents _) -> true
    | Read (Failed _) | Skipped -> false
  ;;
end

type t =
  { id : Id.t
  ; lane : string option
  ; steps : Step.t list
  }
[@@deriving sexp_of]

let kind_of_steps steps =
  List.fold steps ~init:Exec.Kind.Read ~f:(fun kind step ->
    let step = Step.kind step in
    if Exec.Kind.compare step kind > 0 then step else kind)
;;

let kind t = kind_of_steps t.steps

let validate_step = function
  | Step.Run (spec : Exec.Spec.t) ->
    if String.is_empty spec.prog
    then Or_error.error_string "Command has no program"
    else if not (Filename.is_absolute spec.cwd)
    then Or_error.error_s [%message "Command cwd is not absolute" (spec.cwd : string)]
    else if spec.stdout_limit <= 0 || spec.stderr_limit <= 0
    then Or_error.error_string "Command output limits must be positive"
    else Ok ()
  | Read_file { path; limit } ->
    if not (Filename.is_absolute path)
    then Or_error.error_s [%message "File read path is not absolute" (path : string)]
    else if limit <= 0
    then Or_error.error_string "File read limit must be positive"
    else Ok ()
;;

let create ~id ?lane steps =
  let open Or_error.Let_syntax in
  let%bind () =
    if List.is_empty steps then Or_error.error_string "Job has no steps" else Ok ()
  in
  let%bind () = Or_error.all_unit (List.map steps ~f:validate_step) in
  let%map () =
    match lane with
    | None -> Ok ()
    | Some lane when String.is_empty lane -> Or_error.error_string "Job lane is empty"
    | Some lane ->
      (match kind_of_steps steps with
       | Read -> Ok ()
       | Mutate | Network ->
         Or_error.error_s [%message "Only read jobs may have a lane" (lane : string)])
  in
  { id; lane; steps }
;;

module Report = struct
  type t =
    { id : Id.t
    ; lane : string option
    ; kind : Exec.Kind.t
    ; steps : Step_report.t list
    ; cancelled : bool
    }
  [@@deriving sexp, equal]

  let first_failure t = List.find t.steps ~f:(fun step -> not (Step_report.succeeded step))
  let succeeded t = (not t.cancelled) && Option.is_none (first_failure t)
end

let never_started (t : t) : Report.t =
  { id = t.id
  ; lane = t.lane
  ; kind = kind t
  ; steps = List.map t.steps ~f:(fun step -> { Step_report.step; outcome = Skipped })
  ; cancelled = true
  }
;;
