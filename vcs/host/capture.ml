open! Core
open Ches_vcs

module Head = struct
  type t =
    { limit : int
    ; buffer : Buffer.t
    ; mutable total : int
    }

  let create ~limit =
    if limit <= 0 then invalid_arg "Capture.Head.create: limit must be positive";
    { limit; buffer = Buffer.create (Int.min limit 4096); total = 0 }
  ;;

  let add t bytes ~pos ~len =
    let before = t.total in
    t.total <- t.total + len;
    let room = t.limit - Buffer.length t.buffer in
    if room > 0 then Buffer.add_subbytes t.buffer bytes ~pos ~len:(Int.min room len);
    if t.total <= t.limit
    then `Within
    else if before <= t.limit
    then `Passed_limit
    else `Beyond
  ;;

  let contents t = Buffer.contents t.buffer
  let truncated t = t.total > t.limit
end

module Tail = struct
  type t =
    { limit : int
    ; mutable buffer : Buffer.t
    ; mutable total : int
    }

  let create ~limit =
    if limit <= 0 then invalid_arg "Capture.Tail.create: limit must be positive";
    { limit; buffer = Buffer.create (Int.min limit 4096); total = 0 }
  ;;

  let add t bytes ~pos ~len =
    t.total <- t.total + len;
    (* Only the last [limit] bytes of this chunk can survive. *)
    let skip = Int.max 0 (len - t.limit) in
    Buffer.add_subbytes t.buffer bytes ~pos:(pos + skip) ~len:(len - skip);
    if Buffer.length t.buffer >= 2 * t.limit
    then (
      let kept = String.suffix (Buffer.contents t.buffer) t.limit in
      let buffer = Buffer.create (2 * t.limit) in
      Buffer.add_string buffer kept;
      t.buffer <- buffer)
  ;;

  let contents t = String.suffix (Buffer.contents t.buffer) t.limit
  let truncated t = t.total > t.limit
end

module Lines = struct
  type t =
    { line : Buffer.t
    ; mutable after_cr : string option
    (** The text of the transient line just reported, while nothing but its ['\r']
        followed it. *)
    }

  let max_line = 4096
  let create () = { line = Buffer.create 128; after_cr = None }

  let take t =
    let text = Buffer.contents t.line in
    Buffer.clear t.line;
    text
  ;;

  let feed t bytes ~pos ~len ~f =
    for i = pos to pos + len - 1 do
      match Bytes.get bytes i with
      | '\n' ->
        let text =
          match t.after_cr with
          | Some text when Buffer.length t.line = 0 -> text
          | Some _ | None -> take t
        in
        t.after_cr <- None;
        f { Event.Line.text; transient = false }
      | '\r' ->
        let text = take t in
        t.after_cr <- Some text;
        f { Event.Line.text; transient = true }
      | c ->
        t.after_cr <- None;
        if Buffer.length t.line >= max_line
        then f { Event.Line.text = take t; transient = false };
        Buffer.add_char t.line c
    done
  ;;

  let finish t ~f =
    t.after_cr <- None;
    if Buffer.length t.line > 0 then f { Event.Line.text = take t; transient = false }
  ;;
end
