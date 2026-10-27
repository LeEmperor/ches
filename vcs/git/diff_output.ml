open! Core
open Ches_vcs

module Source = struct
  type t =
    | Worktree of { paths : string list }
    | Index of { paths : string list }
    | Untracked of string
    | Commit of string
  [@@deriving sexp, equal]
end

let flags =
  [ "--no-color"
  ; "--no-ext-diff"
  ; "--no-relative"
  ; "--src-prefix=a/"
  ; "--dst-prefix=b/"
  ; "--find-renames"
  ; "--submodule=short"
  ]
;;

let command ~cwd (source : Source.t) =
  let args =
    match source with
    | Worktree { paths } -> ("diff" :: flags) @ ("--" :: paths)
    | Index { paths } -> ("diff" :: "--cached" :: flags) @ ("--" :: paths)
    | Untracked path -> ("diff" :: "--no-index" :: flags) @ [ "--"; "/dev/null"; path ]
    | Commit hash ->
      ("show" :: flags)
      @ [ "--no-show-signature"
        ; "--format=fuller"
        ; "--date=iso-strict"
        ; "--end-of-options"
        ; hash
        ; "--"
        ]
  in
  (* A global option: paths are never globs or pathspec magic (a file named [a*.txt] must
     not show [ab.txt] too). *)
  Cli.read ~cwd ("--literal-pathspecs" :: args)
;;

let ok_exits : Source.t -> int list = function
  | Untracked _ -> [ 0; 1 ]
  | Worktree _ | Index _ | Commit _ -> [ 0 ]
;;

(* Errors carry the 1-based output line and the line itself. *)
exception Malformed of string * int * string

let fail ~line_number what line = raise (Malformed (what, line_number, line))

module Quoted = struct
  (* Git's C-style quoting (quote.c): a double-quoted name with backslash escapes.
     [parse s pos] reads one quoted name starting at [s.[pos] = '"'] and returns it with
     the position after the closing quote. *)
  let parse s pos =
    let length = String.length s in
    let buffer = Buffer.create 16 in
    let rec go i =
      if i >= length
      then None
      else (
        match s.[i] with
        | '"' -> Some (Buffer.contents buffer, i + 1)
        | '\\' when i + 1 < length ->
          let simple c =
            Buffer.add_char buffer c;
            go (i + 2)
          in
          (match s.[i + 1] with
           | 'a' -> simple '\007'
           | 'b' -> simple '\b'
           | 't' -> simple '\t'
           | 'n' -> simple '\n'
           | 'v' -> simple '\011'
           | 'f' -> simple '\012'
           | 'r' -> simple '\r'
           | '"' -> simple '"'
           | '\\' -> simple '\\'
           | '0' .. '3' when i + 3 < length ->
             let octal c = Char.between c ~low:'0' ~high:'7' in
             if octal s.[i + 2] && octal s.[i + 3]
             then (
               let digit k = Char.to_int s.[i + k] - Char.to_int '0' in
               Buffer.add_char
                 buffer
                 (Char.of_int_exn ((digit 1 * 64) + (digit 2 * 8) + digit 3));
               go (i + 4))
             else None
           | _ -> None)
        | c ->
          Buffer.add_char buffer c;
          go (i + 1))
    in
    if pos < length && Char.equal s.[pos] '"' then go (pos + 1) else None
  ;;

  (* A whole field: quoted (and nothing after the closing quote), or raw. *)
  let field s =
    if String.is_prefix s ~prefix:"\""
    then (
      match parse s 0 with
      | Some (name, next) when next = String.length s -> Some name
      | _ -> None)
    else Some s
  ;;
end

(* A name from a ---/+++ line: [None] for /dev/null, the prefix removed. Git appends a tab
   to an unquoted name containing a space (for GNU patch); a name that itself ends in a
   tab would have been quoted. *)
let side_path ~prefix ~line_number line raw =
  if String.equal raw "/dev/null"
  then None
  else (
    let name =
      if String.is_prefix raw ~prefix:"\""
      then Quoted.field raw
      else Some (String.chop_suffix_if_exists raw ~suffix:"\t")
    in
    match name with
    | None -> fail ~line_number "bad quoted path" line
    | Some name -> Some (String.chop_prefix_if_exists name ~prefix))
;;

(* The two names of ["diff --git a/X b/Y"]. Unquoted, the split is only certain when X = Y
   (the line is then "a/X b/X"); otherwise the first " b/" is a guess, used only when no
   other header line names the paths. *)
let git_line_paths rest =
  let strip_a = String.chop_prefix_if_exists ~prefix:"a/" in
  let strip_b = String.chop_prefix_if_exists ~prefix:"b/" in
  if String.is_prefix rest ~prefix:"\""
  then (
    match Quoted.parse rest 0 with
    | Some (a, next) when next < String.length rest && Char.equal rest.[next] ' ' ->
      let b_raw = String.drop_prefix rest (next + 1) in
      Option.map (Quoted.field b_raw) ~f:(fun b -> strip_a a, strip_b b)
    | _ -> None)
  else (
    let length = String.length rest in
    let half = (length - 1) / 2 in
    let symmetric =
      length mod 2 = 1
      && Char.equal rest.[half] ' '
      && String.is_prefix rest ~prefix:"a/"
      && String.is_prefix (String.drop_prefix rest (half + 1)) ~prefix:"b/"
      && String.equal
           (String.sub rest ~pos:2 ~len:(half - 2))
           (String.drop_prefix rest (half + 3))
    in
    if symmetric
    then (
      let name = String.sub rest ~pos:2 ~len:(half - 2) in
      Some (name, name))
    else (
      match String.substr_index rest ~pattern:" \"b/" with
      | Some i ->
        Option.map
          (Quoted.field (String.drop_prefix rest (i + 1)))
          ~f:(fun b -> strip_a (String.prefix rest i), strip_b b)
      | None ->
        (match String.substr_index rest ~pattern:" b/" with
         | Some i ->
           Some (strip_a (String.prefix rest i), strip_b (String.drop_prefix rest (i + 1)))
         | None -> None)))
;;

module Hunk_builder = struct
  type t =
    { header : string
    ; old_start : int
    ; old_count : int
    ; new_start : int
    ; new_count : int
    ; section : string
    ; parents : int (* 1 for a unified diff. *)
    ; mutable lines_rev : Diff.Line.t list
    ; mutable keep : bool (* False once the file's limits are exceeded. *)
    ; mutable line_count : int
    ; mutable byte_count : int
    ; mutable old_remaining : int (* First parent's lines still expected. *)
    ; mutable new_remaining : int
    ; mutable next_old : int
    ; mutable next_new : int
    }

  let complete t = t.old_remaining = 0 && t.new_remaining = 0

  let to_hunk t : Diff.Hunk.t =
    { header = t.header
    ; old_start = t.old_start
    ; old_count = t.old_count
    ; new_start = t.new_start
    ; new_count = t.new_count
    ; section = t.section
    ; lines = List.rev t.lines_rev
    }
  ;;

  (* "a,b" or "a" (count 1). *)
  let range text =
    let number s =
      if (not (String.is_empty s)) && String.for_all s ~f:Char.is_digit
      then Int.of_string_opt s
      else None
    in
    match String.lsplit2 text ~on:',' with
    | Some (start, count) -> Option.both (number start) (number count)
    | None -> Option.map (number text) ~f:(fun start -> start, 1)
  ;;

  (* "@@ -a,b +c,d @@ section", or with one more '@' and one more "-" range per extra
     parent. *)
  let create ~line_number line =
    let bad () = fail ~line_number "malformed hunk header" line in
    let ats = String.take_while line ~f:(Char.equal '@') |> String.length in
    if ats < 2 then bad ();
    let parents = ats - 1 in
    let marker = String.make ats '@' in
    let after = String.drop_prefix line ats in
    if not (String.is_prefix after ~prefix:" ") then bad ();
    match String.substr_index after ~pattern:(" " ^ marker) with
    | None -> bad ()
    | Some close ->
      let ranges = String.sub after ~pos:1 ~len:(close - 1) |> String.split ~on:' ' in
      let section =
        String.drop_prefix after (close + 1 + ats)
        |> String.chop_prefix_if_exists ~prefix:" "
      in
      let olds, news =
        List.partition_tf ranges ~f:(fun range -> String.is_prefix range ~prefix:"-")
      in
      (match olds, news with
       | first_old :: _, [ new_range ] when List.length olds = parents ->
         let parse prefix text =
           match Option.bind (String.chop_prefix text ~prefix) ~f:range with
           | Some parsed -> parsed
           | None -> bad ()
         in
         List.iter olds ~f:(fun old -> ignore (parse "-" old : int * int));
         let old_start, old_count = parse "-" first_old in
         let new_start, new_count = parse "+" new_range in
         { header = line
         ; old_start
         ; old_count
         ; new_start
         ; new_count
         ; section
         ; parents
         ; lines_rev = []
         ; keep = true
         ; line_count = 0
         ; byte_count = 0
         ; old_remaining = old_count
         ; new_remaining = new_count
         ; next_old = old_start
         ; next_new = new_start
         }
       | _ -> bad ())
  ;;

  (* Classify one line of this hunk, or [None] if it is not a hunk line here. *)
  let line t text : Diff.Line.t option =
    let take ~kind ~prefix ~in_old ~in_new =
      if (in_old && t.old_remaining <= 0) || (in_new && t.new_remaining <= 0)
      then None
      else (
        let old_line = if in_old && t.parents = 1 then Some t.next_old else None in
        let new_line = if in_new then Some t.next_new else None in
        if in_old
        then (
          t.old_remaining <- t.old_remaining - 1;
          t.next_old <- t.next_old + 1);
        if in_new
        then (
          t.new_remaining <- t.new_remaining - 1;
          t.next_new <- t.next_new + 1);
        Some
          { Diff.Line.kind
          ; prefix
          ; text = String.drop_prefix text (String.length prefix)
          ; old_line
          ; new_line
          })
    in
    if String.is_prefix text ~prefix:"\\"
    then
      (* About the line before it; valid even after the counts are complete. *)
      Some
        { kind = No_newline
        ; prefix = "\\"
        ; text = String.drop_prefix text 1
        ; old_line = None
        ; new_line = None
        }
    else if String.is_empty text
    then
      (* diff.suppressBlankEmpty: an empty context line. *)
      take ~kind:Context ~prefix:"" ~in_old:true ~in_new:true
    else if t.parents = 1
    then (
      match text.[0] with
      | ' ' -> take ~kind:Context ~prefix:" " ~in_old:true ~in_new:true
      | '+' -> take ~kind:Added ~prefix:"+" ~in_old:false ~in_new:true
      | '-' -> take ~kind:Removed ~prefix:"-" ~in_old:true ~in_new:false
      | _ -> None)
    else if String.length text < t.parents
    then None
    else (
      let prefix = String.prefix text t.parents in
      if not
           (String.for_all prefix ~f:(fun c ->
              Char.equal c ' ' || Char.equal c '+' || Char.equal c '-'))
      then None
      else (
        let added = String.mem prefix '+'
        and removed = String.mem prefix '-' in
        if added && removed
        then None
        else (
          (* Combined format: '-' in column N: in parent N, not in the result; '+' in
             column N: in the result, not in parent N. *)
          let in_new = not removed in
          let in_old =
            Char.equal prefix.[0] '-' || (in_new && not (Char.equal prefix.[0] '+'))
          in
          let kind : Diff.Line.Kind.t =
            if added then Added else if removed then Removed else Context
          in
          take ~kind ~prefix ~in_old ~in_new)))
  ;;
end

module File_builder = struct
  type t =
    { combined : bool
    ; diff_paths : (string * string) option (* From the "diff" line. *)
    ; mutable header_rev : string list
    ; mutable in_hunks : bool
    ; mutable minus : string option option (* From "---": [Some None] = /dev/null. *)
    ; mutable plus : string option option
    ; mutable from_ : string option (* rename/copy from *)
    ; mutable to_ : string option
    ; mutable renamed : bool
    ; mutable copied : bool
    ; mutable similarity : int option
    ; mutable new_file : bool
    ; mutable deleted_file : bool
    ; mutable old_mode : string option
    ; mutable new_mode : string option
    ; mutable binary : bool
    ; mutable worktree_result : bool (* Combined: the result's hash is all zeros. *)
    ; mutable hunks_rev : Diff.Hunk.t list
    ; mutable kept_lines : int
    ; mutable kept_bytes : int
    ; mutable omitted_hunks : int
    ; mutable omitted_lines : int
    ; mutable cut : bool
    ; mutable current : Hunk_builder.t option
    }

  let create ~line_number line =
    let combined, diff_paths =
      match String.chop_prefix line ~prefix:"diff --git " with
      | Some rest -> false, git_line_paths rest
      | None ->
        let rest =
          match String.chop_prefix line ~prefix:"diff --cc " with
          | Some rest -> rest
          | None -> String.chop_prefix_exn line ~prefix:"diff --combined "
        in
        (match Quoted.field rest with
         | Some path -> true, Some (path, path)
         | None -> fail ~line_number "bad quoted path" line)
    in
    { combined
    ; diff_paths
    ; header_rev = [ line ]
    ; in_hunks = false
    ; minus = None
    ; plus = None
    ; from_ = None
    ; to_ = None
    ; renamed = false
    ; copied = false
    ; similarity = None
    ; new_file = false
    ; deleted_file = false
    ; old_mode = None
    ; new_mode = None
    ; binary = false
    ; worktree_result = false
    ; hunks_rev = []
    ; kept_lines = 0
    ; kept_bytes = 0
    ; omitted_hunks = 0
    ; omitted_lines = 0
    ; cut = false
    ; current = None
    }
  ;;

  let is_mode s =
    (not (String.is_empty s))
    && String.for_all s ~f:(fun c -> Char.between c ~low:'0' ~high:'7')
  ;;

  let is_hash s = (not (String.is_empty s)) && String.for_all s ~f:Char.is_hex_digit

  (* Modes of a combined header ("a,b..c"): the first parent's and the result's. *)
  let combined_modes text =
    match String.substr_index text ~pattern:".." with
    | Some i ->
      let parents = String.prefix text i |> String.split ~on:',' in
      let result = String.drop_prefix text (i + 2) in
      (match parents with
       | first :: _ -> Some (first, result)
       | [] -> None)
    | None -> None
  ;;

  (* One header line (before the first hunk). *)
  let header t ~line_number line =
    let bad () = fail ~line_number "unexpected diff header line" line in
    let mode text = if is_mode text then Some text else bad () in
    let path text =
      match Quoted.field text with
      | Some path when not (String.is_empty path) -> path
      | _ -> bad ()
    in
    let index rest =
      let hashes, index_mode =
        match String.lsplit2 rest ~on:' ' with
        | Some (hashes, index_mode) -> hashes, Some (mode index_mode)
        | None -> rest, None
      in
      (match String.substr_index hashes ~pattern:".." with
       | None -> bad ()
       | Some i ->
         let olds = String.prefix hashes i |> String.split ~on:','
         and result = String.drop_prefix hashes (i + 2) in
         if not (List.for_all (result :: olds) ~f:is_hash) then bad ();
         if t.combined then t.worktree_result <- String.for_all result ~f:(Char.equal '0'));
      Option.iter index_mode ~f:(fun index_mode ->
        if Option.is_none t.old_mode then t.old_mode <- index_mode;
        if Option.is_none t.new_mode then t.new_mode <- index_mode)
    in
    let handlers : (string * (string -> unit)) list =
      [ ("old mode ", fun v -> t.old_mode <- mode v)
      ; ("new mode ", fun v -> t.new_mode <- mode v)
      ; ( "new file mode "
        , fun v ->
            t.new_file <- true;
            match combined_modes v with
            | Some (_, result) when t.combined -> t.new_mode <- mode result
            | _ -> t.new_mode <- mode v )
      ; ( "deleted file mode "
        , fun v ->
            t.deleted_file <- true;
            match String.lsplit2 v ~on:',' with
            | Some (first, _) when t.combined -> t.old_mode <- mode first
            | _ -> t.old_mode <- mode v )
      ; ( "mode "
        , fun v ->
            match combined_modes v with
            | Some (old_mode, new_mode) when t.combined ->
              t.old_mode <- mode old_mode;
              t.new_mode <- mode new_mode
            | _ -> bad () )
      ; ( "similarity index "
        , fun v ->
            match Option.bind (String.chop_suffix v ~suffix:"%") ~f:Int.of_string_opt with
            | Some n -> t.similarity <- Some n
            | None -> bad () )
      ; ("dissimilarity index ", fun _ -> ())
      ; ( "rename from "
        , fun v ->
            t.renamed <- true;
            t.from_ <- Some (path v) )
      ; ( "rename to "
        , fun v ->
            t.renamed <- true;
            t.to_ <- Some (path v) )
      ; ( "copy from "
        , fun v ->
            t.copied <- true;
            t.from_ <- Some (path v) )
      ; ( "copy to "
        , fun v ->
            t.copied <- true;
            t.to_ <- Some (path v) )
      ; "index ", index
      ; ("--- ", fun v -> t.minus <- Some (side_path ~prefix:"a/" ~line_number line v))
      ; ("+++ ", fun v -> t.plus <- Some (side_path ~prefix:"b/" ~line_number line v))
      ]
    in
    t.header_rev <- line :: t.header_rev;
    match
      List.find_map handlers ~f:(fun (prefix, handle) ->
        Option.map (String.chop_prefix line ~prefix) ~f:(fun value -> handle, value))
    with
    | Some (handle, value) -> handle value
    | None ->
      if String.is_prefix line ~prefix:"Binary files "
         && String.is_suffix line ~suffix:" differ"
      then t.binary <- true
      else bad ()
  ;;

  (* Close the hunk in progress (complete, or [~incomplete] at a cut). *)
  let close_hunk t ~incomplete =
    match t.current with
    | None -> ()
    | Some hunk ->
      t.current <- None;
      if hunk.keep && not incomplete
      then (
        t.hunks_rev <- Hunk_builder.to_hunk hunk :: t.hunks_rev;
        t.kept_lines <- t.kept_lines + hunk.line_count;
        t.kept_bytes <- t.kept_bytes + hunk.byte_count)
      else (
        t.omitted_hunks <- t.omitted_hunks + 1;
        t.omitted_lines <- t.omitted_lines + hunk.line_count)
  ;;

  let start_hunk t ~line_number line =
    t.in_hunks <- true;
    let hunk = Hunk_builder.create ~line_number line in
    let expected_parents = if t.combined then hunk.parents >= 2 else hunk.parents = 1 in
    if not expected_parents
    then fail ~line_number "hunk header does not match the diff" line;
    (* Once a hunk was dropped, the rest of the file is. *)
    if t.omitted_hunks > 0 then hunk.keep <- false;
    t.current <- Some hunk
  ;;

  (* Add a hunk line, dropping the hunk once the file's kept lines or bytes would exceed
     the limits. *)
  let add_line t (limits : Diff.Limits.t) (hunk : Hunk_builder.t) (line : Diff.Line.t) =
    hunk.line_count <- hunk.line_count + 1;
    hunk.byte_count <- hunk.byte_count + String.length line.text;
    if hunk.keep
    then
      if t.kept_lines + hunk.line_count > limits.file_lines
         || t.kept_bytes + hunk.byte_count > limits.file_bytes
      then (
        hunk.keep <- false;
        hunk.lines_rev <- [])
      else hunk.lines_rev <- line :: hunk.lines_rev
  ;;

  (* The file type bits: "100644" -> "10", "120000" -> "12". *)
  let mode_type mode = String.drop_suffix mode 4

  let finish t : Diff.File.t =
    let git_old, git_new =
      match t.diff_paths with
      | Some (a, b) -> Some a, Some b
      | None -> None, None
    in
    let pick ~from_header ~side ~git =
      match from_header, side with
      | Some path, _ -> Some path
      | None, Some side -> side
      | None, None -> git
    in
    let old_path = pick ~from_header:t.from_ ~side:t.minus ~git:git_old in
    let new_path = pick ~from_header:t.to_ ~side:t.plus ~git:git_new in
    let change : Diff.File.Change.t =
      if t.combined && t.worktree_result
      then Unmerged
      else if t.new_file
      then Added
      else if t.deleted_file
      then Deleted
      else if t.renamed
      then Renamed { similarity = t.similarity }
      else if t.copied
      then Copied { similarity = t.similarity }
      else (
        match t.old_mode, t.new_mode with
        | Some old_mode, Some new_mode
          when not (String.equal (mode_type old_mode) (mode_type new_mode)) ->
          Type_changed
        | _ -> Modified)
    in
    let old_path, new_path =
      match change with
      | Added -> None, new_path
      | Deleted -> old_path, None
      | _ -> old_path, new_path
    in
    let gitlink = Option.equal String.equal (Some "160000") in
    { old_path
    ; new_path
    ; change
    ; old_mode = t.old_mode
    ; new_mode = t.new_mode
    ; header = List.rev t.header_rev
    ; hunks = List.rev t.hunks_rev
    ; binary = t.binary
    ; submodule = gitlink t.old_mode || gitlink t.new_mode
    ; combined = t.combined
    ; truncated =
        (if t.omitted_hunks > 0 || t.cut
         then
           Some
             { omitted_hunks = t.omitted_hunks
             ; omitted_lines = t.omitted_lines
             ; cut = t.cut
             }
         else None)
    }
  ;;
end

(* ["* Unmerged path X"]: git's diff and diff --cached print this for a conflicted path
   they cannot show (e.g. deleted on one side, or any conflict for --cached). *)
let unmerged_file line path : Diff.File.t =
  { old_path = Some path
  ; new_path = Some path
  ; change = Unmerged
  ; old_mode = None
  ; new_mode = None
  ; header = [ line ]
  ; hunks = []
  ; binary = false
  ; submodule = false
  ; combined = false
  ; truncated = None
  }
;;

let is_file_start line =
  String.is_prefix line ~prefix:"diff --git "
  || String.is_prefix line ~prefix:"diff --cc "
  || String.is_prefix line ~prefix:"diff --combined "
;;

let parse_exn (limits : Diff.Limits.t) ~cut text =
  let lines = String.split text ~on:'\n' in
  let lines =
    match List.rev lines with
    | "" :: rev -> List.rev rev
    | _ :: rev when cut -> List.rev rev (* The incomplete last line. *)
    | _ -> lines
  in
  let preamble_rev = ref [] in
  let files_rev = ref [] in
  let current : File_builder.t option ref = ref None in
  let finish_current () =
    Option.iter !current ~f:(fun file ->
      File_builder.close_hunk file ~incomplete:false;
      files_rev := File_builder.finish file :: !files_rev);
    current := None
  in
  List.iteri lines ~f:(fun index line ->
    let line_number = index + 1 in
    let new_file () =
      match String.chop_prefix line ~prefix:"* Unmerged path " with
      | Some path ->
        finish_current ();
        files_rev := unmerged_file line path :: !files_rev;
        true
      | None ->
        if is_file_start line
        then (
          finish_current ();
          current := Some (File_builder.create ~line_number line);
          true)
        else false
    in
    match !current with
    | None ->
      if not (new_file ())
      then
        if List.is_empty !files_rev
        then preamble_rev := line :: !preamble_rev
        else fail ~line_number "unexpected line after a file" line
    | Some file ->
      let hunk_line =
        match file.current with
        | None -> None
        | Some hunk ->
          (match Hunk_builder.line hunk line with
           | Some parsed ->
             File_builder.add_line file limits hunk parsed;
             Some ()
           | None -> None)
      in
      (match hunk_line with
       | Some () -> ()
       | None ->
         (match file.current with
          | Some hunk when not (Hunk_builder.complete hunk) ->
            fail ~line_number "hunk ended early" line
          | _ -> ());
         if String.is_prefix line ~prefix:"@@"
         then (
           File_builder.close_hunk file ~incomplete:false;
           File_builder.start_hunk file ~line_number line)
         else if new_file ()
         then ()
         else if file.in_hunks
         then fail ~line_number "unexpected line in a diff" line
         else File_builder.header file ~line_number line));
  (match !current with
   | Some file ->
     let incomplete =
       match file.current with
       | Some hunk -> not (Hunk_builder.complete hunk)
       | None -> false
     in
     if incomplete && not cut
     then fail ~line_number:(List.length lines) "the last hunk is incomplete" "";
     if cut then file.cut <- true;
     File_builder.close_hunk file ~incomplete;
     files_rev := File_builder.finish file :: !files_rev;
     current := None
   | None -> ());
  { Diff.preamble = List.rev !preamble_rev; files = List.rev !files_rev; cut }
;;

let parse limits ~cut text =
  match parse_exn limits ~cut text with
  | diff -> Ok diff
  | exception Malformed (what, line_number, line) ->
    Or_error.error_s
      [%message "cannot parse diff output" what (line_number : int) (line : string)]
;;
