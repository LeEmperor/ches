open! Core
open Ches_vcs

module Kind = struct
  type t =
    | Preamble
    | Message
    | Meta
    | Hunk
    | Added
    | Removed
    | Context
    | No_newline
    | Note
  [@@deriving sexp_of, equal]

  let style : t -> Style.t = function
    | Preamble | Meta -> Diff_meta
    | Message | Context -> Status
    | Hunk -> Diff_hunk
    | Added -> Diff_added
    | Removed -> Diff_removed
    | No_newline | Note -> Stale
  ;;
end

module Target = struct
  type t =
    { path : string option
    ; display : string
    ; line : int option
    }
  [@@deriving sexp_of, equal]
end

module Line = struct
  type t =
    { text : string
    ; kind : Kind.t
    ; target : Target.t option
    }
  [@@deriving sexp_of]
end

module Position = struct
  type t =
    { file : int
    ; hunk : int option
    ; line : int option
    }
  [@@deriving sexp_of, equal]
end

type t =
  { lines : Line.t array
  ; positions : Position.t option array (** Each line's place in the [Diff.t]. *)
  ; starts : int array (** Byte offset of each line in [text]. *)
  ; text : string
  }
[@@deriving sexp_of]

let lines t = Array.to_list t.lines
let text t = t.text
let one_line s = String.concat ~sep:"^J" (String.split s ~on:'\n')

(* Lines, each with its position in the diff ([None] outside any file). *)
let create (lines : (Line.t * Position.t option) list) =
  let positions = Array.of_list (List.map lines ~f:snd) in
  let lines =
    Array.of_list
      (List.map lines ~f:(fun (line, _) -> { line with text = one_line line.text }))
  in
  let starts = Array.create ~len:(Array.length lines) 0 in
  let _ =
    Array.foldi lines ~init:0 ~f:(fun i offset (line : Line.t) ->
      starts.(i) <- offset;
      offset + String.length line.text + 1)
  in
  { lines
  ; positions
  ; starts
  ; text = String.concat ~sep:"\n" (Array.to_list (Array.map lines ~f:(fun l -> l.text)))
  }
;;

let note text : Line.t = { text; kind = Note; target = None }
let of_message message = create [ note message, None ]

(* The lines of one hunk, each with the line [e] opens: an added or context line's
   [new_line]; a removed line's next new-side line in the hunk, else [new_start]; a
   "\ No newline" marker the line of the line it is about (the one before it). [at]
   is a line's position ([None]: the [@@] line). *)
let hunk_lines (hunk : Diff.Hunk.t) ~target ~at =
  let start = Int.max 1 hunk.new_start in
  let lines = Array.of_list hunk.lines in
  let n = Array.length lines in
  let next_new = Array.create ~len:(n + 1) None in
  for i = n - 1 downto 0 do
    next_new.(i)
    <- (match lines.(i).new_line with
      | Some _ as line -> line
      | None -> next_new.(i + 1))
  done;
  let resolved = Array.create ~len:n start in
  Array.iteri lines ~f:(fun i (line : Diff.Line.t) ->
    resolved.(i)
    <- (match line.kind with
      | Added | Context -> Option.value line.new_line ~default:start
      | Removed -> Option.value next_new.(i + 1) ~default:start
      | No_newline -> if i = 0 then start else resolved.(i - 1)));
  ( ({ Line.text = hunk.header; kind = Hunk; target = Some (target (Some start)) }
      : Line.t)
  , Some (at None) )
  :: List.mapi hunk.lines ~f:(fun i (line : Diff.Line.t) ->
    ( ({ text = line.prefix ^ line.text
       ; kind =
           (match line.kind with
            | Added -> Added
            | Removed -> Removed
            | Context -> Context
            | No_newline -> No_newline)
       ; target = Some (target (Some resolved.(i)))
       }
       : Line.t)
    , Some (at (Some i)) ))
;;

let subproject (line : Diff.Line.t) =
  let text = String.chop_prefix_if_exists line.text ~prefix:"Subproject commit " in
  if String.length text > 7 && String.for_all (String.prefix text 7) ~f:Char.is_hex_digit
  then String.prefix text 7 ^ String.drop_prefix text 40
  else text
;;

let header_only (file : Diff.File.t) =
  file.binary
  || file.submodule
  || Diff.File.mode_only file
  || Diff.File.rename_only file
  || List.is_empty file.hunks
;;

(* The lines of file [index] of the diff. *)
let file_lines index (file : Diff.File.t) =
  let display = Diff.File.path file in
  let target line = { Target.path = file.new_path; display; line } in
  let meta text : Line.t = { text; kind = Meta; target = Some (target None) } in
  (* Header lines, notes and the placeholder belong to the file, not a hunk. *)
  let of_file line = line, Some { Position.file = index; hunk = None; line = None } in
  let header = List.map file.header ~f:(fun text -> of_file (meta text)) in
  let body =
    if file.submodule
    then (
      let commits kind =
        List.concat_map file.hunks ~f:(fun hunk -> hunk.lines)
        |> List.filter ~f:(fun (line : Diff.Line.t) -> Diff.Line.Kind.equal line.kind kind)
        |> List.map ~f:subproject
      in
      match commits Removed, commits Added with
      | [], [] -> []
      | old, new_ ->
        [ of_file
            { (note
                 (sprintf
                    "(submodule: %s -> %s)"
                    (Option.value (List.hd old) ~default:"none")
                    (Option.value (List.hd new_) ~default:"none")))
              with
              target = Some (target None)
            }
        ])
    else if header_only file
    then []
    else
      List.concat_mapi file.hunks ~f:(fun h hunk ->
        hunk_lines hunk ~target ~at:(fun line ->
          { Position.file = index; hunk = Some h; line }))
  in
  let truncated =
    match file.truncated with
    | None -> []
    | Some { omitted_hunks; omitted_lines; cut } ->
      let omitted =
        if omitted_hunks = 0
        then []
        else
          [ sprintf
              "%d more hunk%s (%s%d line%s) not shown"
              omitted_hunks
              (if omitted_hunks = 1 then "" else "s")
              (if cut then "at least " else "")
              omitted_lines
              (if omitted_lines = 1 then "" else "s")
          ]
      in
      let cut = if cut then [ "the diff output was cut inside this file" ] else [] in
      [ of_file
          { (note (sprintf "... %s" (String.concat ~sep:"; " (omitted @ cut))))
            with
            target = Some (target None)
          }
      ]
  in
  header @ body @ truncated
;;

let of_diff (diff : Diff.t) =
  let preamble =
    List.map diff.preamble ~f:(fun text ->
      ( ({ text
         ; kind =
             (if String.is_empty text || String.is_prefix text ~prefix:"    "
              then Message
              else Preamble)
         ; target = None
         }
         : Line.t)
      , None ))
  in
  let files = List.concat_mapi diff.files ~f:file_lines in
  let cut =
    if diff.cut then [ note "(the diff output was cut at its size limit)", None ] else []
  in
  match preamble, files, cut with
  | [], [], [] -> of_message "No changes"
  | _ -> create (preamble @ files @ cut)
;;

(* The last line starting at or before [offset]. *)
let index_at t offset =
  let rec search low high =
    (* Invariant: starts.(low) <= offset, and every line after [high] starts later. *)
    if low >= high
    then low
    else (
      let mid = (low + high + 1) / 2 in
      if t.starts.(mid) <= offset then search mid high else search low (mid - 1))
  in
  if Array.is_empty t.starts || offset < t.starts.(0)
  then None
  else Some (search 0 (Array.length t.starts - 1))
;;

let line_at t offset = Option.map (index_at t offset) ~f:(fun i -> t.lines.(i))

let kind_at_start t offset =
  match index_at t offset with
  | Some i when t.starts.(i) = offset -> Some t.lines.(i).kind
  | Some _ | None -> None
;;

let position_at t offset = Option.bind (index_at t offset) ~f:(fun i -> t.positions.(i))

let start_of t ~file ~hunk =
  Array.findi t.positions ~f:(fun _ position ->
    match position, hunk with
    | Some p, None -> p.file = file
    | Some p, Some hunk ->
      p.file = file && Option.equal Int.equal p.hunk (Some hunk) && Option.is_none p.line
    | None, _ -> false)
  |> Option.map ~f:(fun (i, _) -> t.starts.(i))
;;

module Span = struct
  type t =
    { file : int
    ; hunks : (int * int list) list
    }
  [@@deriving sexp_of, equal]
end

let span t ~start ~stop : (Span.t option, [ `Several_files ]) Result.t =
  (* A line's bytes run from its start through its line feed, so the last byte of the
     range ([stop - 1]) is on the last touched line. *)
  match index_at t (Int.max 0 start) with
  | None -> Ok None
  | Some first ->
    let last =
      if stop > start then Option.value (index_at t (stop - 1)) ~default:first else first
    in
    let positions =
      List.filter_map (List.range first (Int.max first last) ~stop:`inclusive) ~f:(fun i ->
        t.positions.(i))
    in
    (match List.dedup_and_sort positions ~compare:(fun (a : Position.t) b ->
             Int.compare a.file b.file)
     with
     | [] -> Ok None
     | _ :: _ :: _ -> Error `Several_files
     | [ { file; _ } ] ->
       let lines =
         List.filter_map positions ~f:(fun position ->
           match position.hunk, position.line with
           | Some hunk, Some line -> Some (hunk, line)
           | _ -> None)
       in
       let hunks =
         (* Laid out in order: hunks and their lines are already ascending. *)
         List.group lines ~break:(fun (a, _) (b, _) -> a <> b)
         |> List.map ~f:(fun group -> fst (List.hd_exn group), List.map group ~f:snd)
       in
       Ok (Some { Span.file; hunks }))
;;

let hunk_starts t =
  Array.filter_mapi t.lines ~f:(fun i line ->
    Option.some_if (Kind.equal line.kind Hunk) t.starts.(i))
  |> Array.to_list
;;
