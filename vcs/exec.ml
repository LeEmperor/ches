open! Core

module Kind = struct
  type t =
    | Read
    | Mutate
    | Network
  [@@deriving sexp, equal, compare, enumerate]

  let default_timeout = function
    | Read -> Time_ns.Span.of_int_sec 30
    | Mutate | Network -> Time_ns.Span.of_int_sec 600
  ;;
end

module Stdin = struct
  type t =
    | Null
    | Data of string
  [@@deriving sexp, equal]
end

module Stream = struct
  type t =
    | Stdout
    | Stderr
  [@@deriving sexp, equal, compare]
end

module Spec = struct
  type t =
    { prog : string
    ; args : string list
    ; cwd : string
    ; env : (string * string) list
    ; kind : Kind.t
    ; stdin : Stdin.t
    ; timeout : Time_ns.Span.t option
    ; stdout_limit : int
    ; stderr_limit : int
    ; stream : bool
    }
  [@@deriving sexp, equal]

  let default_stdout_limit = 32 * 1024 * 1024
  let default_stderr_limit = 64 * 1024

  let create
    ?(env = [])
    ?(stdin = Stdin.Null)
    ?timeout
    ?(stdout_limit = default_stdout_limit)
    ?(stderr_limit = default_stderr_limit)
    ?(stream = false)
    ~kind
    ~cwd
    prog
    args
    =
    let timeout = Option.value timeout ~default:(Some (Kind.default_timeout kind)) in
    { prog; args; cwd; env; kind; stdin; timeout; stdout_limit; stderr_limit; stream }
  ;;

  let argv t = t.prog :: t.args

  let plain c =
    Char.is_alphanum c
    || (match c with
        | '_' | '@' | '%' | '+' | '=' | ':' | ',' | '.' | '/' | '-' -> true
        | _ -> false)
  ;;

  let quote arg =
    if (not (String.is_empty arg)) && String.for_all arg ~f:plain
    then arg
    else (
      let buffer = Buffer.create (String.length arg + 2) in
      Buffer.add_char buffer '\'';
      String.iter arg ~f:(fun c ->
        if Char.equal c '\''
        then Buffer.add_string buffer {|'\''|}
        else if Char.to_int c < 0x20 || Char.to_int c = 0x7f
        then Buffer.add_string buffer (sprintf "\\x%02X" (Char.to_int c))
        else Buffer.add_char buffer c);
      Buffer.add_char buffer '\'';
      Buffer.contents buffer)
  ;;

  let to_string_hum t = String.concat ~sep:" " (List.map (argv t) ~f:quote)
end

module Status = struct
  type t =
    | Exited of int
    | Signaled of string
    | Not_started of string
  [@@deriving sexp, equal]
end

module Result = struct
  type t =
    { status : Status.t
    ; stdout : string
    ; stdout_truncated : bool
    ; stderr : string
    ; stderr_truncated : bool
    ; timed_out : bool
    ; cancelled : bool
    ; elapsed : Time_ns.Span.t
    }
  [@@deriving sexp, equal]

  let exited_with t codes =
    (not t.timed_out)
    && (not t.cancelled)
    &&
    match t.status with
    | Exited code -> List.mem codes code ~equal:Int.equal
    | Signaled _ | Not_started _ -> false
  ;;

  let succeeded t = exited_with t [ 0 ]
  let cut_at_limit t = t.stdout_truncated && (not t.timed_out) && not t.cancelled

  let status_hum t =
    if t.cancelled
    then "cancelled"
    else if t.timed_out
    then sprintf "timed out after %s" (Time_ns.Span.to_string_hum ~decimals:0 t.elapsed)
    else (
      match t.status with
      | Exited code -> sprintf "exit %d" code
      | Signaled signal -> sprintf "killed by %s" signal
      | Not_started message -> sprintf "could not start: %s" message)
  ;;
end
