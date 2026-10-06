open! Core
open! Async

let command =
  Command.async
    ~summary:"Edit a UTF-8, LF text file"
    ~readme:(fun () ->
      "Opens PATH, or starts an empty document if nothing exists there; saving \
       creates it.\n\
       Normal mode: h/j/k/l move, w/b/e and W/B/E move by words, 0/^/$ to the\n\
       line start/first non-blank/end, _/g_ to the first/last non-blank,\n\
       gg/G to the first/last line, % to the matching (), [] or {}; a count\n\
       first (20j, 3w, 20G) repeats or picks the line. i/a insert before/after\n\
       the cursor, I/A at the line's first non-blank/end, o/O open a line\n\
       below/above; x deletes, u undoes, Ctrl-r redoes, Space w saves, Space q\n\
       quits, Space Q quits discarding changes. Ctrl-e/Ctrl-y scroll the view a\n\
       line, Ctrl-d/Ctrl-u half a screen with the cursor, zz/zt/zb put the cursor\n\
       line at the middle/top/bottom.\n\
       Space v c/h/l/H/L/-/+/r: toggle centering, move, resize, reset the layout;\n\
        Space v n/N toggle absolute/relative line numbers; Space v s toggles the smear cursor;\n\
        Space v t toggles status; Space v p h/l/k/j places it, p -/+ sizes it;\n\
         Space v z toggles zen; Space v g toggles tile chrome (classic/open);\n\
         Space v e cycles retained problems; idle Escape acknowledges.\n\
         Space v b toggles the problems preview; Space v f filters workspace/current document;\n\
         Space v o focuses problems: j/k, gg/G, Ctrl-d/u navigate, e inspects, a acknowledges,\n\
         Enter jumps to a supported current-file location; Escape cancels/back/returns.\n\
         --demo-problems seeds eight labelled, jumpable synthetic problems without editing PATH.\n\
         --demo-report installs a static report: Space v d shows it, Space v D focuses it.")
    (let%map_open.Command path = anon ("PATH" %: Filename_unix.arg_type)
     and demo_problems = flag "--demo-problems" no_arg
       ~doc:" Seed synthetic problems with locations for manual pane/navigation testing"
     and demo_report = flag "--demo-report" no_arg
       ~doc:" Install a static, error-free report view for manual tile testing" in
     fun () ->
       let fail error =
         eprintf "ches: %s\n" (Error.to_string_hum error);
         exit 1
       in
       (* Bonsai_term reads keys from stdin; without a terminal there it fails with a
          long message meant for its developers. *)
       if not (Core_unix.isatty Core_unix.stdin)
       then fail (Error.of_string "standard input is not a terminal")
       else (
         match
           Ches_app.Controller.open_file ~cell_width:Ches_screen.Cell_map.width path
         with
         | Error error -> fail error
          | Ok controller ->
            let controller = if demo_problems
              then Ches_app.Demo_problems.install controller else controller in
           let report =
             Option.some_if demo_report Ches_screen.Report_tile.demo in
           (match%bind Ches_ui.Editor_view.run ?report controller with
            | Ok () -> return ()
            | Error error -> fail error)))
;;

let () = Command_unix.run command
