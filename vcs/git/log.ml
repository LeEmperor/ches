open! Core

module Commit = struct
  type t =
    { hash : string
    ; parents : string list
    ; author_name : string
    ; author_email : string
    ; author_time : int
    ; subject : string
    }
  [@@deriving sexp, equal]

  let short_hash t = String.prefix t.hash 7
end

let command ~cwd ~limit =
  if limit <= 0
  then raise_s [%message "Log.command: limit must be positive" (limit : int)];
  Cli.read
    ~cwd
    [ "log"
    ; "-z"
    ; "--no-color"
    ; "--no-show-signature"
    ; sprintf "--max-count=%d" limit
    ; "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s"
    ; "HEAD"
    ; "--"
    ]
;;

let commit = function
  | [ hash; parents; author_name; author_email; time; subject ] as fields ->
    (match Int.of_string_opt time with
     | Some author_time when not (String.is_empty hash) ->
       Ok
         { Commit.hash
         ; parents =
             String.split parents ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
         ; author_name
         ; author_email
         ; author_time
         ; subject
         }
     | _ -> Or_error.error_s [%message "malformed log record" (fields : string list)])
  | fields -> Or_error.error_s [%message "malformed log record" (fields : string list)]
;;

let parse ~cut stdout =
  if String.is_empty stdout
  then Ok []
  else (
    (* Six NUL-terminated fields per commit: the piece after the last NUL is empty, or
       (when cut) the incomplete start of a field. *)
    let fields, tail =
      match List.rev (String.split stdout ~on:'\000') with
      | tail :: rev -> List.rev rev, tail
      | [] -> [], ""
    in
    let groups = List.chunks_of fields ~length:6 in
    let groups =
      if cut then List.filter groups ~f:(fun group -> List.length group = 6) else groups
    in
    if (not cut) && not (String.is_empty tail)
    then Or_error.error_s [%message "unterminated log record" (tail : string)]
    else List.map groups ~f:commit |> Or_error.all)
;;
