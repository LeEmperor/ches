open! Core
open Ches_vcs

module Selection = struct
  type t = Whole [@@deriving sexp, equal]
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

let hunk (file : Diff.File.t) ~hunk:index (selection : Selection.t) ~reverse:_ =
  let path = Diff.File.path file in
  let fail fmt = ksprintf Or_error.error_string fmt in
  match unsupported file with
  | Some reason -> fail "Hunk actions do not apply to %s: %s" path reason
  | None ->
    (match List.nth file.hunks index with
     | None ->
       fail
         "Hunk %d of %s does not exist (it has %d)"
         (index + 1)
         path
         (List.length file.hunks)
     | Some hunk ->
       let mode_line =
         match file.change, file.old_mode, file.new_mode with
         | Added, _, Some mode -> Ok (Some ("new file mode " ^ mode))
         | Added, _, None -> fail "%s is new but its diff names no mode" path
         | Deleted, Some mode, _ -> Ok (Some ("deleted file mode " ^ mode))
         | Deleted, None, _ -> fail "%s is deleted but its diff names no mode" path
         | (Modified | Renamed _ | Copied _ | Type_changed | Unmerged), _, _ -> Ok None
       in
       let%map.Or_error mode_line in
       let old_name =
         match file.change with
         | Added -> "/dev/null"
         | _ -> quote ~prefix:"a/" path
       in
       let new_name =
         match file.change with
         | Deleted -> "/dev/null"
         | _ -> quote ~prefix:"b/" path
       in
       let lines =
         match selection with
         | Whole ->
           List.map hunk.lines ~f:(fun (line : Diff.Line.t) -> prefix_of line ^ line.text)
       in
       List.concat
         [ [ sprintf
               "diff --git %s %s"
               (quote ~prefix:"a/" path)
               (quote ~prefix:"b/" path)
           ]
         ; Option.to_list mode_line
         ; [ "--- " ^ old_name; "+++ " ^ new_name; hunk.header ]
         ; lines
         ]
       |> List.map ~f:(fun line -> line ^ "\n")
       |> String.concat)
;;
