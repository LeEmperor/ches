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
         Space v z toggles zen; Space v e cycles retained problems; idle Escape acknowledges.\n\
         Space v b toggles the problems preview; Space v f filters workspace/current document;\n\
         Space v o focuses problems: j/k, gg/G, Ctrl-d/u navigate, e inspects, a acknowledges,\n\
         Enter jumps to a supported current-file location; Escape cancels/back/returns.\n\
         Space v m toggles notification history; Space v M focuses it (X clears history).\n\
         --demo-problems seeds eight labelled, jumpable synthetic problems without editing PATH.\n\
         --demo-report installs a static report: Space v d shows it, Space v D focuses it.\n\
         --demo-diagnostics seeds static synthetic checker findings (two sources, another\n\
         file, one stopped source) to review the problems view; edits leave them dimmed.\n\
         --synthetic-checker runs a synthetic checker, one source like ocamllsp: about\n\
         0.4s after an edit, lines containing ERROR/TODO are errors/warnings; about 0.8s\n\
         after a save, ERROR lines again plus a finding in another file, merged into the\n\
         same lists. Space v K crashes it; Space v R restarts it. It replaces ocamllsp.\n\
         For a .ml, .mli, .mll, or .mly PATH, ches runs ocamllsp from PATH as Neovim\n\
         does, rooted at the nearest dune-project (else dune-workspace, *.opam, opam,\n\
         esy.json, package.json, .git, else PATH's directory); its diagnostics go to the\n\
         problems view. It never runs dune: errors needing a build need your own\n\
         `dune build --watch`. Space v R restarts it; --no-lsp turns it off.")
    (let%map_open.Command path = anon ("PATH" %: Filename_unix.arg_type)
     and demo_problems = flag "--demo-problems" no_arg
       ~doc:" Seed synthetic problems with locations for manual pane/navigation testing"
     and demo_diagnostics = flag "--demo-diagnostics" no_arg
       ~doc:" Seed static synthetic diagnostic findings for manual problems-view review"
     and synthetic_checker = flag "--synthetic-checker" no_arg
       ~doc:" Run a synthetic diagnostic checker (ERROR/TODO lines) for manual review"
     and no_lsp = flag "--no-lsp" no_arg
       ~doc:" Do not run a language server (ocamllsp) for OCaml files"
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
            let controller = if demo_diagnostics
              then Ches_app.Demo_diagnostics.install controller else controller in
           let report =
             Option.some_if demo_report Ches_screen.Report_tile.demo in
           (* One source: the synthetic checker, a test flag, replaces the server. *)
           let source =
             let lsp = Ches_source.Lsp_client.Config.ocamllsp in
             if synthetic_checker
             then
               Some
                 (Ches_source.Synthetic.start
                    ~root:(Ches_source.Workspace_root.find path)
                    ())
             else if (not no_lsp) && lsp.applies_to path
             then
               Some
                 (Ches_source.Lsp_client.start
                    ~config:lsp
                    ~cell_width:Ches_screen.Cell_map.width
                    ~root:(Ches_source.Lsp_client.Config.root lsp path)
                    ())
             else None
           in
           (match%bind Ches_ui.Editor_view.run ?report ?source controller with
            | Ok () -> return ()
            | Error error -> fail error)))
;;

let () = Command_unix.run command
