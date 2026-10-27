(* Compact printers and report builders shared by the git backend tests. *)

open! Core
open Ches_vcs

(* A command result as a runner would report it. *)
let result ?(status = Exec.Status.Exited 0) ?(stderr = "") ?(cut = false) stdout
  : Exec.Result.t
  =
  { status
  ; stdout
  ; stdout_truncated = cut
  ; stderr
  ; stderr_truncated = false
  ; timed_out = false
  ; cancelled = false
  ; elapsed = Time_ns.Span.zero
  }
;;

let ran spec result : Job.Step_report.t = { step = Run spec; outcome = Ran result }

let or_error print = function
  | Ok value -> print value
  | Error error -> print_s [%message "Error" ~_:(error : Error.t)]
;;

let line_kind : Diff.Line.Kind.t -> string = function
  | Context -> "ctx"
  | Added -> "add"
  | Removed -> "del"
  | No_newline -> "eof"
;;

let number = function
  | Some n -> Int.to_string n
  | None -> "."
;;

let path = function
  | Some path -> sprintf "%S" path
  | None -> "-"
;;

(* One line per file and per hunk line; hunk lines as kind, old and new numbers, prefix
   and text. *)
let diff ?(header = false) (diff : Diff.t) =
  List.iter diff.preamble ~f:(fun line -> printf "preamble |%s\n" line);
  List.iter diff.files ~f:(fun (file : Diff.File.t) ->
    let flags =
      List.filter_opt
        [ Option.some_if file.binary "binary"
        ; Option.some_if file.submodule "submodule"
        ; Option.some_if file.combined "combined"
        ; Option.some_if (Diff.File.mode_only file) "mode-only"
        ; Option.some_if (Diff.File.rename_only file) "rename-only"
        ; Option.some_if (not (Diff.File.line_actions file)) "no-line-actions"
        ]
    in
    printf
      "file %s -> %s %s modes %s..%s%s\n"
      (path file.old_path)
      (path file.new_path)
      (Sexp.to_string [%sexp (file.change : Diff.File.Change.t)])
      (Option.value file.old_mode ~default:"-")
      (Option.value file.new_mode ~default:"-")
      (String.concat (List.map flags ~f:(fun flag -> " " ^ flag)));
    Option.iter file.truncated ~f:(fun truncated ->
      printf
        "  truncated %s\n"
        (Sexp.to_string_hum [%sexp (truncated : Diff.File.Truncated.t)]));
    if header then List.iter file.header ~f:(fun line -> printf "  header |%s\n" line);
    List.iter file.hunks ~f:(fun hunk ->
      printf
        "  %s  [-%d,%d +%d,%d] section=%S\n"
        hunk.header
        hunk.old_start
        hunk.old_count
        hunk.new_start
        hunk.new_count
        hunk.section;
      List.iter hunk.lines ~f:(fun line ->
        printf
          "    %s %3s %3s %-4s %S\n"
          (line_kind line.kind)
          (number line.old_line)
          (number line.new_line)
          (sprintf "%S" line.prefix)
          line.text)));
  if diff.cut then print_endline "(output cut)"
;;
