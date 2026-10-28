open! Core
open Ches_vcs

module Selection = struct
  type t =
    | Whole
    | Lines of int list
  [@@deriving sexp, equal]

  let is_change (line : Diff.Line.t) =
    match line.kind with
    | Added | Removed -> true
    | Context | No_newline -> false
  ;;

  (* Whether line [i] of a hunk of [n] lines is selected. *)
  let selects t ~n =
    match t with
    | Whole -> fun _ -> true
    | Lines indices ->
      let selected = Array.create ~len:n false in
      List.iter indices ~f:(fun i -> if i >= 0 && i < n then selected.(i) <- true);
      fun i -> selected.(i)
  ;;

  let changes (hunk : Diff.Hunk.t) t =
    let selected = selects t ~n:(List.length hunk.lines) in
    List.counti hunk.lines ~f:(fun i line -> is_change line && selected i)
  ;;
end

(* Git's C-style quoting (quote.c, [quote_c_style]) for the bytes it quotes even with
   core.quotepath=false: the double quote, the backslash and control bytes. *)
let needs_quoting c =
  match c with
  | '"' | '\\' -> true
  | c -> Char.to_int c < 0x20 || Char.to_int c = 0x7f
;;

let quote ~prefix path =
  let name = prefix ^ path in
  if not (String.exists name ~f:needs_quoting)
  then name
  else (
    let buffer = Buffer.create (String.length name + 8) in
    Buffer.add_char buffer '"';
    String.iter name ~f:(fun c ->
      match c with
      | '\007' -> Buffer.add_string buffer "\\a"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\011' -> Buffer.add_string buffer "\\v"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | c when needs_quoting c ->
        Buffer.add_string buffer (sprintf "\\%03o" (Char.to_int c))
      | c -> Buffer.add_char buffer c);
    Buffer.add_char buffer '"';
    Buffer.contents buffer)
;;

(* Why a file has no hunk actions, for the error; [None] when it has them. *)
let unsupported (file : Diff.File.t) =
  if file.binary
  then Some "it is binary"
  else if file.submodule
  then Some "it is a submodule"
  else if file.combined || Diff.File.Change.equal file.change Unmerged
  then Some "it is conflicted"
  else if Diff.File.mode_only file
  then Some "only its mode changed"
  else if Diff.File.rename_only file
  then (
    match file.change with
    | Copied _ -> Some "it is only copied"
    | _ -> Some "it is only renamed")
  else if not (Diff.File.line_actions file)
  then Some "it has no line changes"
  else (
    match file.change with
    | Type_changed -> Some "its type changed"
    | Added | Deleted | Modified | Renamed _ | Copied _ | Unmerged -> None)
;;

let prefix_of (line : Diff.Line.t) =
  match line.kind with
  | Context -> " "
  | Added -> "+"
  | Removed -> "-"
  | No_newline -> line.prefix
;;

let fail fmt = ksprintf Or_error.error_string fmt

(* The mode line of an added or deleted file's header, checked whatever the patch. *)
let mode_line (file : Diff.File.t) =
  let path = Diff.File.path file in
  match file.change, file.old_mode, file.new_mode with
  | Added, _, Some mode -> Ok (Some ("new file mode " ^ mode))
  | Added, _, None -> fail "%s is new but its diff names no mode" path
  | Deleted, Some mode, _ -> Ok (Some ("deleted file mode " ^ mode))
  | Deleted, None, _ -> fail "%s is deleted but its diff names no mode" path
  | (Modified | Renamed _ | Copied _ | Type_changed | Unmerged), _, _ -> Ok None
;;

(* The header lines, given whether the patch's old and new sides have lines: an added file
   is created only from an empty old side, a deleted one removed only to an empty new
   side; otherwise the patch modifies the path. *)
let file_header (file : Diff.File.t) ~mode_line ~old_empty ~new_empty =
  let path = Diff.File.path file in
  let created = Diff.File.Change.equal file.change Added && old_empty in
  let removed = Diff.File.Change.equal file.change Deleted && new_empty in
  List.concat
    [ [ sprintf "diff --git %s %s" (quote ~prefix:"a/" path) (quote ~prefix:"b/" path) ]
    ; (if created || removed then Option.to_list mode_line else [])
    ; [ ("--- " ^ if created then "/dev/null" else quote ~prefix:"a/" path)
      ; ("+++ " ^ if removed then "/dev/null" else quote ~prefix:"b/" path)
      ]
    ]
;;

let finish lines = List.map lines ~f:(fun line -> line ^ "\n") |> String.concat

(* One line of a patch hunk, with whether each side it is on ends in a newline. *)
type entry =
  | Both of
      { text : string
      ; old_newline : bool
      ; new_newline : bool
      }
  | Old of
      { text : string
      ; newline : bool
      }
  | New of
      { text : string
      ; newline : bool
      }

let on_old = function
  | Both _ | Old _ -> true
  | New _ -> false
;;

let on_new = function
  | Both _ | New _ -> true
  | Old _ -> false
;;

(* The entries of [hunk] under [selection]: forward, unselected removals stay as context
   and unselected additions go; reversed, the other way round. A line keeps the newline
   state of the side it came from; then every line but the last of each side gets its
   newline (a line without one must end its side). *)
let entries (hunk : Diff.Hunk.t) selection ~reverse =
  let lines = Array.of_list hunk.lines in
  let n = Array.length lines in
  let selected = Selection.selects selection ~n in
  let newline i =
    not (i + 1 < n && Diff.Line.Kind.equal lines.(i + 1).Diff.Line.kind No_newline)
  in
  let entries =
    Array.to_list lines
    |> List.filter_mapi ~f:(fun i (line : Diff.Line.t) ->
      let text = line.text in
      let newline = newline i in
      let both = Both { text; old_newline = newline; new_newline = newline } in
      match line.kind, selected i, reverse with
      | Context, _, _ -> Some both
      | No_newline, _, _ -> None
      | Removed, true, _ -> Some (Old { text; newline })
      | Added, true, _ -> Some (New { text; newline })
      | Removed, false, false | Added, false, true -> Some both
      | Removed, false, true | Added, false, false -> None)
  in
  let last on =
    List.foldi entries ~init:None ~f:(fun i last entry ->
      if on entry then Some i else last)
  in
  let last_old = last on_old in
  let last_new = last on_new in
  let is_last last i = Option.equal Int.equal last (Some i) in
  List.mapi entries ~f:(fun i entry ->
    let old_newline newline = newline || not (is_last last_old i) in
    let new_newline newline = newline || not (is_last last_new i) in
    match entry with
    | Both { text; old_newline = o; new_newline = n } ->
      Both { text; old_newline = old_newline o; new_newline = new_newline n }
    | Old { text; newline } -> Old { text; newline = old_newline newline }
    | New { text; newline } -> New { text; newline = new_newline newline })
;;

let marker (hunk : Diff.Hunk.t) =
  match
    List.find hunk.lines ~f:(fun (line : Diff.Line.t) ->
      Diff.Line.Kind.equal line.kind No_newline)
  with
  | Some line -> line.prefix ^ line.text
  | None -> "\\ No newline at end of file"
;;

(* The body lines of [entries] and the old and new counts. *)
let body entries ~marker =
  let with_marker prefix text newline =
    if newline then [ prefix ^ text ] else [ prefix ^ text; marker ]
  in
  let lines =
    List.concat_map entries ~f:(function
      | Both { text; old_newline; new_newline } when Bool.equal old_newline new_newline ->
        with_marker " " text old_newline
      | Both { text; old_newline; new_newline } ->
        with_marker "-" text old_newline @ with_marker "+" text new_newline
      | Old { text; newline } -> with_marker "-" text newline
      | New { text; newline } -> with_marker "+" text newline)
  in
  lines, List.count entries ~f:on_old, List.count entries ~f:on_new
;;

(* Why [file] has no hunk or line actions, as an error naming [actions]. *)
let check_file file ~actions =
  match unsupported file with
  | Some reason ->
    fail "%s actions do not apply to %s: %s" actions (Diff.File.path file) reason
  | None -> Ok ()
;;

(* The hunks of [selections] after the checks: each hunk with its selection. *)
let checked (file : Diff.File.t) selections =
  let path = Diff.File.path file in
  let%bind.Or_error () = check_file file ~actions:"Line" in
  let total = List.length file.hunks in
  let%bind.Or_error hunks =
    List.map selections ~f:(fun (index, (selection : Selection.t)) ->
      match List.nth file.hunks index with
      | None -> fail "Hunk %d of %s does not exist (it has %d)" (index + 1) path total
      | Some (hunk : Diff.Hunk.t) ->
        let n = List.length hunk.lines in
        (match selection with
         | Whole -> Ok (hunk, selection)
         | Lines indices ->
           (match List.find indices ~f:(fun i -> i < 0 || i >= n) with
            | Some i ->
              fail
                "Line %d of hunk %d/%d of %s does not exist (it has %d)"
                (i + 1)
                (index + 1)
                total
                path
                n
            | None -> Ok (hunk, selection))))
    |> Or_error.all
  in
  let rec ascending = function
    | a :: (b :: _ as rest) -> a < b && ascending rest
    | [] | [ _ ] -> true
  in
  if ascending (List.map selections ~f:fst)
  then Ok hunks
  else fail "Hunks of %s must be listed once each, in order" path
;;

let changes file selections =
  let%map.Or_error hunks = checked file selections in
  List.sum (module Int) hunks ~f:(fun (hunk, selection) ->
    Selection.changes hunk selection)
;;

let hunks (file : Diff.File.t) selections ~reverse =
  let path = Diff.File.path file in
  let%bind.Or_error hunks = checked file selections in
  let%bind.Or_error mode_line = mode_line file in
  let hunks =
    List.filter hunks ~f:(fun (hunk, selection) -> Selection.changes hunk selection > 0)
  in
  match hunks with
  | [] -> fail "No changes selected in %s" path
  | _ :: _ ->
    (* The side git matches against keeps the diff's start; the other is shifted by the
       earlier hunks of this patch. A start names the line before an empty side. *)
    let _, bodies =
      List.fold_map hunks ~init:0 ~f:(fun shift ((hunk : Diff.Hunk.t), selection) ->
        let lines, old_count, new_count =
          body (entries hunk selection ~reverse) ~marker:(marker hunk)
        in
        let base_start, base_count, other_count =
          if reverse
          then hunk.new_start, new_count, old_count
          else hunk.old_start, old_count, new_count
        in
        let before = if base_count = 0 then base_start else base_start - 1 in
        let other_before = before + shift in
        let other_start = if other_count = 0 then other_before else other_before + 1 in
        let old_start, new_start =
          if reverse then other_start, base_start else base_start, other_start
        in
        let header =
          sprintf "@@ -%d,%d +%d,%d @@" old_start old_count new_start new_count
          ^ if String.is_empty hunk.section then "" else " " ^ hunk.section
        in
        shift + other_count - base_count, (header :: lines, old_count, new_count))
    in
    let old_empty = List.for_all bodies ~f:(fun (_, old_count, _) -> old_count = 0) in
    let new_empty = List.for_all bodies ~f:(fun (_, _, new_count) -> new_count = 0) in
    Ok
      (finish
         (file_header file ~mode_line ~old_empty ~new_empty
          @ List.concat_map bodies ~f:(fun (lines, _, _) -> lines)))
;;

let hunk (file : Diff.File.t) ~hunk:index (selection : Selection.t) ~reverse =
  match selection with
  | Lines _ -> hunks file [ index, selection ] ~reverse
  | Whole ->
    let path = Diff.File.path file in
    let%bind.Or_error () = check_file file ~actions:"Hunk" in
    (match List.nth file.hunks index with
     | None ->
       fail
         "Hunk %d of %s does not exist (it has %d)"
         (index + 1)
         path
         (List.length file.hunks)
     | Some hunk ->
       let%map.Or_error mode_line = mode_line file in
       let lines =
         List.map hunk.lines ~f:(fun (line : Diff.Line.t) -> prefix_of line ^ line.text)
       in
       finish
         (file_header
            file
            ~mode_line
            ~old_empty:(Diff.File.Change.equal file.change Added)
            ~new_empty:(Diff.File.Change.equal file.change Deleted)
          @ (hunk.header :: lines)))
;;
