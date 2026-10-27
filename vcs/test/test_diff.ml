open! Core
open Ches_vcs

let file ?(change = Diff.File.Change.Modified) ?(hunks = 0) ?(binary = false)
      ?(submodule = false) ?(combined = false) ?old_mode ?new_mode () : Diff.File.t
  =
  let hunk : Diff.Hunk.t =
    { header = "@@ -1 +1 @@"
    ; old_start = 1
    ; old_count = 1
    ; new_start = 1
    ; new_count = 1
    ; section = ""
    ; lines = []
    }
  in
  { old_path = Some "a"
  ; new_path = Some "b"
  ; change
  ; old_mode
  ; new_mode
  ; header = []
  ; hunks = List.init hunks ~f:(Fn.const hunk)
  ; binary
  ; submodule
  ; combined
  ; truncated = None
  }
;;

let%expect_test "file classification for headers without line actions" =
  let show name f =
    print_s
      [%sexp
        (name : string)
      , { mode_only = (Diff.File.mode_only f : bool)
        ; rename_only = (Diff.File.rename_only f : bool)
        ; line_actions = (Diff.File.line_actions f : bool)
        }]
  in
  show "content" (file ~hunks:1 ());
  show "mode only" (file ~old_mode:"100644" ~new_mode:"100755" ());
  show "mode and content" (file ~hunks:1 ~old_mode:"100644" ~new_mode:"100755" ());
  show "rename only" (file ~change:(Renamed { similarity = Some 100 }) ());
  show "rename with edits" (file ~change:(Renamed { similarity = Some 90 }) ~hunks:1 ());
  show "copy only" (file ~change:(Copied { similarity = Some 100 }) ());
  show "binary" (file ~binary:true ());
  show "submodule" (file ~submodule:true ~hunks:1 ());
  show "combined" (file ~change:Unmerged ~combined:true ~hunks:1 ());
  show "merge commit combined" (file ~combined:true ~hunks:1 ());
  show "unmerged path line" (file ~change:Unmerged ());
  show "unmerged with hunks, not combined" (file ~change:Unmerged ~hunks:1 ());
  [%expect
    {|
    (content ((mode_only false) (rename_only false) (line_actions true)))
    ("mode only" ((mode_only true) (rename_only false) (line_actions false)))
    ("mode and content"
     ((mode_only false) (rename_only false) (line_actions true)))
    ("rename only" ((mode_only false) (rename_only true) (line_actions false)))
    ("rename with edits"
     ((mode_only false) (rename_only false) (line_actions true)))
    ("copy only" ((mode_only false) (rename_only true) (line_actions false)))
    (binary ((mode_only false) (rename_only false) (line_actions false)))
    (submodule ((mode_only false) (rename_only false) (line_actions false)))
    (combined ((mode_only false) (rename_only false) (line_actions false)))
    ("merge commit combined"
     ((mode_only false) (rename_only false) (line_actions false)))
    ("unmerged path line"
     ((mode_only false) (rename_only false) (line_actions false)))
    ("unmerged with hunks, not combined"
     ((mode_only false) (rename_only false) (line_actions false)))
    |}];
  print_s
    [%sexp
      (Diff.File.path (file ()) : string)
    , (Diff.File.path { (file ()) with new_path = None } : string)];
  [%expect {| (b a) |}]
;;
