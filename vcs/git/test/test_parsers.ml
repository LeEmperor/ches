(* Pure tests of the git parsers over literal captured output (git 2.43), including edge
   cases a fixture cannot easily produce. No process runs here. *)

open! Core
open Ches_vcs
open Ches_vcs_git

let print_spec (spec : Exec.Spec.t) =
  print_s
    [%sexp
      { argv = (Exec.Spec.argv spec : string list)
      ; cwd : string = spec.cwd
      ; env : (string * string) list = spec.env
      ; kind : Exec.Kind.t = spec.kind
      ; stdin : Exec.Stdin.t = spec.stdin
      ; timeout : Time_ns.Span.t option = spec.timeout
      ; stdout_limit : int = spec.stdout_limit
      ; stream : bool = spec.stream
      }]
;;

let%expect_test "Cli: the prefix, read environment, and kinds" =
  print_spec (Cli.read ~cwd:"/r" [ "status" ]);
  print_spec (Cli.read ~stdout_limit:10 ~cwd:"/r" [ "log" ]);
  print_spec (Cli.mutate ~stdin:(Data "patch") ~cwd:"/r" [ "apply"; "--cached" ]);
  print_spec (Cli.network ~cwd:"/r" [ "fetch" ]);
  [%expect
    {|
    ((argv (git --no-pager -c color.ui=false -c core.quotepath=false status))
     (cwd /r) (env ((GIT_OPTIONAL_LOCKS 0) (LC_ALL C))) (kind Read) (stdin Null)
     (timeout (30s)) (stdout_limit 33554432) (stream false))
    ((argv (git --no-pager -c color.ui=false -c core.quotepath=false log))
     (cwd /r) (env ((GIT_OPTIONAL_LOCKS 0) (LC_ALL C))) (kind Read) (stdin Null)
     (timeout (30s)) (stdout_limit 10) (stream false))
    ((argv
      (git --no-pager -c color.ui=false -c core.quotepath=false apply --cached))
     (cwd /r) (env ()) (kind Mutate) (stdin (Data patch)) (timeout (10m))
     (stdout_limit 33554432) (stream false))
    ((argv (git --no-pager -c color.ui=false -c core.quotepath=false fetch))
     (cwd /r) (env ()) (kind Network) (stdin Null) (timeout (10m))
     (stdout_limit 33554432) (stream true))
    |}]
;;

(* Repository detection *)

let detect_with result =
  let reports =
    List.map (Repository.detect ~cwd:"/w/sub") ~f:(fun step ->
      match step with
      | Run spec -> Show.ran spec result
      | Read_file _ -> assert false)
  in
  print_s
    [%sexp
      (Repository.detected ~cwd:"/w/sub" reports
       : Repository.t Ches_vcs.Backend.Detection.t)]
;;

let%expect_test "Repository.detect and detected" =
  List.iter (Repository.detect ~cwd:"/w/sub") ~f:(fun step ->
    print_s [%sexp (step : Job.Step.t)]);
  detect_with (Show.result "/w\n/w/.git\n");
  detect_with (Show.result "/w/odd\nname\n/w/odd\nname/.git\n");
  detect_with (Show.result "");
  detect_with
    (Show.result
       ~status:(Exited 128)
       ~stderr:"fatal: not a git repository (or any of the parent directories): .git\n"
       "");
  detect_with
    (Show.result
       ~status:(Exited 128)
       ~stderr:"fatal: this operation must be run in a work tree\nsecond line\n"
       "");
  detect_with
    (Show.result
       ~status:(Exited 128)
       ~stderr:
         "fatal: detected dubious ownership in repository at '/w'\n\
          To add an exception for this directory, call:\n"
       "");
  detect_with (Show.result ~status:(Not_started "No such file or directory") "");
  print_s
    [%sexp (Repository.detected ~cwd:"/w" [] : Repository.t Ches_vcs.Backend.Detection.t)];
  [%expect
    {|
    (Run
     ((prog git)
      (args
       (--no-pager -c color.ui=false -c core.quotepath=false rev-parse
        --show-toplevel --absolute-git-dir))
      (cwd /w/sub) (env ((GIT_OPTIONAL_LOCKS 0) (LC_ALL C))) (kind Read)
      (stdin Null) (timeout (30s)) (stdout_limit 33554432) (stderr_limit 65536)
      (stream false)))
    (Found ((root /w) (git_dir /w/.git)))
    (Failed
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --show-toplevel --absolute-git-dir: cannot read the repository paths (a path containing a newline is not supported): \"/w/odd\\nname\\n/w/odd\\nname/.git\\n\"")
    (Failed
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --show-toplevel --absolute-git-dir: cannot read the repository paths (a path containing a newline is not supported): \"\"")
    (Not_a_repository (cwd /w/sub))
    (No_work_tree (cwd /w/sub)
     (message "fatal: this operation must be run in a work tree"))
    (Failed
      "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --show-toplevel --absolute-git-dir: exit 128: fatal: detected dubious ownership in repository at '/w'\
     \nTo add an exception for this directory, call:")
    (Failed
     "git --no-pager -c color.ui=false -c core.quotepath=false rev-parse --show-toplevel --absolute-git-dir: could not start: No such file or directory")
    (Failed "git repository detection: expected one command report, got: ")
    |}]
;;

(* Status *)

let status ?(cut = false) text =
  Show.or_error
    (fun (t : Status.t) -> print_s [%sexp (t : Status.t)])
    (Status.parse ~cut text)
;;

let%expect_test "Status.command" =
  print_s [%sexp (Exec.Spec.argv (Status.command ~cwd:"/w" ()) : string list)];
  print_s
    [%sexp (Exec.Spec.argv (Status.command ~ignored:true ~cwd:"/w" ()) : string list)];
  [%expect
    {|
    (git --no-pager -c color.ui=false -c core.quotepath=false status
     --porcelain=v2 -z --branch --untracked-files=all --find-renames)
    (git --no-pager -c color.ui=false -c core.quotepath=false status
     --porcelain=v2 -z --branch --untracked-files=all --find-renames
     --ignored=matching)
    |}]
;;

let%expect_test "Status: an empty repository, and staged files before the first commit" =
  status "# branch.oid (initial)\000# branch.head main\000";
  status
    "# branch.oid (initial)\000# branch.head main\0001 A. N... 000000 100644 100644 \
     0000000000000000000000000000000000000000 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 \
     empty\0001 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 \
     23eb407b644b0e362fa224168ecd0adfa02b022a new file.txt\000";
  [%expect
    {|
    ((branch ((oid ()) (head (main)) (upstream ()) (ahead_behind ())))
     (entries ()) (truncated false))
    ((branch ((oid ()) (head (main)) (upstream ()) (ahead_behind ())))
     (entries
      ((Changed (index Added) (worktree Unmodified) (submodule ())
        (head_mode 000000) (index_mode 100644) (worktree_mode 100644)
        (path empty))
       (Changed (index Added) (worktree Unmodified) (submodule ())
        (head_mode 000000) (index_mode 100644) (worktree_mode 100644)
        (path "new file.txt"))))
     (truncated false))
    |}]
;;

let mixed_status =
  "# branch.oid f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49\000# branch.head main\000# \
   branch.upstream origin/main\000# branch.ab +2 -1\000# stash 3\0001 MM N... 100644 \
   100644 100644 2019eda923040a79f52fe4bf49e0a106f4f658ae \
   f8931154cdb1943d21b033ada5ff4cab77349c41 a.txt\0001 D. N... 100644 000000 000000 \
   286c5f5776916d7d7d5849988ca9d83e722cf9c2 0000000000000000000000000000000000000000 \
   del.txt\0001 MM N... 100644 100755 100644 fa11a6a9c54797a8f68963af8ffc4d92bbffc660 \
   fa11a6a9c54797a8f68963af8ffc4d92bbffc660 mode.sh\0002 R. N... 100644 100644 100644 \
   600d48ac740e0e5904838e02446d117c410ec089 600d48ac740e0e5904838e02446d117c410ec089 \
   R100 moved \195\169.txt\000move me.txt\0002 CM N... 100644 100644 100644 \
   600d48ac740e0e5904838e02446d117c410ec089 600d48ac740e0e5904838e02446d117c410ec089 C75 \
   copy\000orig\0001 .T N... 100644 100644 120000 \
   1c1206e8bf4337e96dad9a6d139628852077558d 1c1206e8bf4337e96dad9a6d139628852077558d \
   link\0001 .M SC.U 160000 160000 160000 b308c3e56c484d4daeb357bae251e8e8ac99b4ed \
   b308c3e56c484d4daeb357bae251e8e8ac99b4ed sub\000? dir/\195\188 file.txt\000? new\n\
   line.txt\000? q\"uote.txt\000! build/out.o\000"
;;

let%expect_test "Status: ordinary, renamed, copied, type change, submodule, untracked, \
                 ignored"
  =
  status mixed_status;
  [%expect
    {|
    ((branch
      ((oid (f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49)) (head (main))
       (upstream (origin/main)) (ahead_behind ((2 1)))))
     (entries
      ((Changed (index Modified) (worktree Modified) (submodule ())
        (head_mode 100644) (index_mode 100644) (worktree_mode 100644)
        (path a.txt))
       (Changed (index Deleted) (worktree Unmodified) (submodule ())
        (head_mode 100644) (index_mode 000000) (worktree_mode 000000)
        (path del.txt))
       (Changed (index Modified) (worktree Modified) (submodule ())
        (head_mode 100644) (index_mode 100755) (worktree_mode 100644)
        (path mode.sh))
       (Renamed_or_copied (index Renamed) (worktree Unmodified) (submodule ())
        (head_mode 100644) (index_mode 100644) (worktree_mode 100644) (score 100)
        (path "moved \195\169.txt") (original "move me.txt"))
       (Renamed_or_copied (index Copied) (worktree Modified) (submodule ())
        (head_mode 100644) (index_mode 100644) (worktree_mode 100644) (score 75)
        (path copy) (original orig))
       (Changed (index Unmodified) (worktree Type_changed) (submodule ())
        (head_mode 100644) (index_mode 100644) (worktree_mode 120000)
        (path link))
       (Changed (index Unmodified) (worktree Modified)
        (submodule
         (((commit_changed true) (tracked_changes false)
           (untracked_changes true))))
        (head_mode 160000) (index_mode 160000) (worktree_mode 160000) (path sub))
       (Untracked "dir/\195\188 file.txt") (Untracked  "new\
                                                      \nline.txt")
       (Untracked "q\"uote.txt") (Ignored build/out.o)))
     (truncated false))
    |}]
;;

let%expect_test "Status: every unmerged XY code, detached HEAD" =
  let unmerged xy path =
    sprintf
      "u %s N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 \
       b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd \
       %s\000"
      xy
      path
  in
  let text =
    "# branch.oid 4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94\000# branch.head \
     (detached)\000"
    ^ String.concat
        (List.map
           [ "DD", "dd.txt"
           ; "AU", "au.txt"
           ; "UD", "ud.txt"
           ; "UA", "ua.txt"
           ; "DU", "du.txt"
           ; "AA", "aa.txt"
           ; "UU", "u u.txt"
           ]
           ~f:(fun (xy, path) -> unmerged xy path))
  in
  (match Status.parse ~cut:false text with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok t ->
     print_s [%sexp (t.branch : Status.Branch.t)];
     List.iter t.entries ~f:(fun entry ->
       match entry with
       | Unmerged { conflict; path; submodule = None } ->
         printf "%-8s %s\n" path (Status.Conflict.to_string_hum conflict)
       | _ -> print_s [%sexp (entry : Status.Entry.t)]));
  [%expect
    {|
    ((oid (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)) (head ()) (upstream ())
     (ahead_behind ()))
    dd.txt   both deleted
    au.txt   added by us
    ud.txt   deleted by them
    ua.txt   added by them
    du.txt   deleted by us
    aa.txt   both added
    u u.txt  both modified
    |}]
;;

let%expect_test "Status: a gone upstream has no ahead/behind header" =
  status
    "# branch.oid a757577ac7f79aa5fd48614f00553a6319b37a4a\000# branch.head doomed\000# \
     branch.upstream origin/doomed\000";
  [%expect
    {|
    ((branch
      ((oid (a757577ac7f79aa5fd48614f00553a6319b37a4a)) (head (doomed))
       (upstream (origin/doomed)) (ahead_behind ())))
     (entries ()) (truncated false))
    |}]
;;

let%expect_test "Status: output cut at its limit" =
  let head = "# branch.oid (initial)\000# branch.head main\000? a\000" in
  (* Cut inside a record: it is dropped. *)
  status ~cut:true (head ^ "? par");
  (* Cut between a rename's two paths: the rename is dropped. *)
  status
    ~cut:true
    (head
     ^ "2 R. N... 100644 100644 100644 600d48ac740e0e5904838e02446d117c410ec089 \
        600d48ac740e0e5904838e02446d117c410ec089 R100 new\000ol");
  status
    ~cut:true
    (head
     ^ "2 R. N... 100644 100644 100644 600d48ac740e0e5904838e02446d117c410ec089 \
        600d48ac740e0e5904838e02446d117c410ec089 R100 new\000");
  (* Without [~cut], the same output is an error. *)
  status (head ^ "? par");
  [%expect
    {|
    ((branch ((oid ()) (head (main)) (upstream ()) (ahead_behind ())))
     (entries ((Untracked a))) (truncated true))
    ((branch ((oid ()) (head (main)) (upstream ()) (ahead_behind ())))
     (entries ((Untracked a))) (truncated true))
    ((branch ((oid ()) (head (main)) (upstream ()) (ahead_behind ())))
     (entries ((Untracked a))) (truncated true))
    (Error ("unterminated status record" (tail "? par")))
    |}]
;;

let%expect_test "Status: malformed output is an error" =
  let head = "# branch.oid (initial)\000# branch.head main\000" in
  status "";
  status "# branch.head main\000";
  status "# branch.oid (initial)\000";
  status (head ^ "3 what\000");
  status (head ^ "1 XY N... 100644 100644 100644 h h path\000");
  status (head ^ "1 .M N... 100644 100644 100644 h h\000");
  status (head ^ "1 .M Sxyz 100644 100644 100644 h h p\000");
  status (head ^ "1 .M N... 1006a4 100644 100644 h h p\000");
  status (head ^ "2 R. N... 100644 100644 100644 h h X100 new\000old\000");
  status (head ^ "2 R. N... 100644 100644 100644 h h R100 new\000");
  status (head ^ "u MM N... 100644 100644 100644 100644 h h h p\000");
  status (head ^ "? \000");
  status "# branch.oid (initial)\000# branch.head main\000# branch.ab 1 2\000";
  [%expect
    {|
    (Error "status output has no branch.oid header")
    (Error "status output has no branch.oid header")
    (Error "status output has no branch.head header")
    (Error ("unknown status record" (record "3 what")))
    (Error
     ("malformed status record"
      (record "1 XY N... 100644 100644 100644 h h path")))
    (Error
     ("malformed status record" (record "1 .M N... 100644 100644 100644 h h")))
    (Error
     ("malformed status record" (record "1 .M Sxyz 100644 100644 100644 h h p")))
    (Error
     ("malformed status record" (record "1 .M N... 1006a4 100644 100644 h h p")))
    (Error
     ("malformed status record"
      (record "2 R. N... 100644 100644 100644 h h X100 new")))
    (Error
     ("malformed status record"
      (record "2 R. N... 100644 100644 100644 h h R100 new")))
    (Error
     ("malformed status record"
      (record "u MM N... 100644 100644 100644 100644 h h h p")))
    (Error ("malformed status record" (record "? ")))
    (Error ("malformed status record" (record "# branch.ab 1 2")))
    |}]
;;

(* Branch list *)

let branches ?(cut = false) text =
  Show.or_error
    (fun branches -> print_s [%sexp (branches : Branch_list.Branch.t list)])
    (Branch_list.parse ~cut text)
;;

let%expect_test "Branch_list.command" =
  print_s [%sexp (Exec.Spec.argv (Branch_list.command ~cwd:"/w") : string list)];
  [%expect
    {|
    (git --no-pager -c color.ui=false -c core.quotepath=false for-each-ref
     "--format=%(refname:short)%00%(objectname)%00%(HEAD)%00%(upstream)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(contents:subject)%00%(upstream:remotename)%00%(upstream:remoteref)%00"
     refs/heads)
    |}]
;;

let%expect_test "Branch_list: upstreams in sync, ahead, behind, both, gone, local, none" =
  (* [upstream] is ["<remote>/<branch>"], or [""] for none; a local upstream (remote
     ["."]) is given as [~local]. *)
  let line ?local name head upstream track subject =
    let refname, short, remote, merge =
      match local, String.lsplit2 upstream ~on:'/' with
      | Some branch, _ -> "refs/heads/" ^ branch, branch, ".", "refs/heads/" ^ branch
      | None, None -> "", "", "", ""
      | None, Some (remote, branch) ->
        "refs/remotes/" ^ upstream, upstream, remote, "refs/heads/" ^ branch
    in
    sprintf
      "%s\000a757577ac7f79aa5fd48614f00553a6319b37a4a\000%s\000%s\000%s\000%s\0001767225600\000%s\000%s\000%s\000\n"
      name
      head
      refname
      short
      track
      subject
      remote
      merge
  in
  branches
    (String.concat
       [ line "doomed" " " "origin/doomed" "gone" "Second"
       ; line "in-sync" " " "origin/main" "" "First"
       ; line "main" "*" "origin/main" "ahead 1" "Second"
       ; line "old" " " "origin/main" "behind 12" "Old"
       ; line "on-main" " " ~local:"main" "" "behind 1" "Old"
       ; line "split" " " "fork/feature/x" "ahead 3, behind 4" "Fix: a, b and c"
       ; line "user/local" " " "" "" ""
       ]);
  [%expect
    {|
    (((name doomed) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (current false)
      (upstream
       (((name origin/doomed) (refname refs/remotes/origin/doomed)
         (tracking Gone) (remote origin) (merge refs/heads/doomed))))
      (subject Second) (committer_time 1767225600))
     ((name in-sync) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (current false)
      (upstream
       (((name origin/main) (refname refs/remotes/origin/main) (tracking In_sync)
         (remote origin) (merge refs/heads/main))))
      (subject First) (committer_time 1767225600))
     ((name main) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a) (current true)
      (upstream
       (((name origin/main) (refname refs/remotes/origin/main)
         (tracking (Ahead_behind (ahead 1) (behind 0))) (remote origin)
         (merge refs/heads/main))))
      (subject Second) (committer_time 1767225600))
     ((name old) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a) (current false)
      (upstream
       (((name origin/main) (refname refs/remotes/origin/main)
         (tracking (Ahead_behind (ahead 0) (behind 12))) (remote origin)
         (merge refs/heads/main))))
      (subject Old) (committer_time 1767225600))
     ((name on-main) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (current false)
      (upstream
       (((name main) (refname refs/heads/main)
         (tracking (Ahead_behind (ahead 0) (behind 1))) (remote .)
         (merge refs/heads/main))))
      (subject Old) (committer_time 1767225600))
     ((name split) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a) (current false)
      (upstream
       (((name fork/feature/x) (refname refs/remotes/fork/feature/x)
         (tracking (Ahead_behind (ahead 3) (behind 4))) (remote fork)
         (merge refs/heads/feature/x))))
      (subject "Fix: a, b and c") (committer_time 1767225600))
     ((name user/local) (oid a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (current false) (upstream ()) (subject "") (committer_time 1767225600)))
    |}]
;;

let%expect_test "Branch_list: empty, cut, malformed" =
  branches "";
  branches ~cut:true "main\000aaaa\000*\000\000\000\0001\000s\000\000\000\nnext\000bb";
  branches "main\000aaaa\000*\000\000\000\0001\000s\000\000\000\nnext\000bb";
  branches "main\000aaaa\000*\000\000\000\0001\000s\000\000\000\n";
  branches "main\000aaaa\000*\000\000\000\000\000s\000\000\000\n";
  branches "main\000aaaa\000?\000\000\000\0001\000s\000\000\000\n";
  branches
    "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000sideways 2\0001\000s\000o\000refs/heads/m\000\n";
  branches
    "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000ahead 0\0001\000s\000o\000refs/heads/m\000\n";
  print_endline "-- an upstream without its remote name or remote ref";
  branches
    "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000\0001\000s\000\000refs/heads/m\000\n";
  branches "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000\0001\000s\000o\000\000\n";
  print_endline "-- the phase 5 format (two fields short)";
  branches "main\000aaaa\000*\000\000\000\0001\000s\000\n";
  [%expect
    {|
    ()
    (((name main) (oid aaaa) (current true) (upstream ()) (subject s)
      (committer_time 1)))
    (Error ("unterminated branch line" (tail "next\000bb")))
    (((name main) (oid aaaa) (current true) (upstream ()) (subject s)
      (committer_time 1)))
    (Error
     ("malformed branch line"
      (line "main\000aaaa\000*\000\000\000\000\000s\000\000\000")))
    (Error
     ("malformed branch line"
      (line "main\000aaaa\000?\000\000\000\0001\000s\000\000\000")))
    (Error
     ("malformed branch line"
      (line
       "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000sideways 2\0001\000s\000o\000refs/heads/m\000")))
    (Error
     ("malformed branch line"
      (line
       "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000ahead 0\0001\000s\000o\000refs/heads/m\000")))
    -- an upstream without its remote name or remote ref
    (Error
     ("malformed branch line"
      (line
       "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000\0001\000s\000\000refs/heads/m\000")))
    (Error
     ("malformed branch line"
      (line
       "main\000aaaa\000*\000refs/remotes/o/m\000o/m\000\0001\000s\000o\000\000")))
    -- the phase 5 format (two fields short)
    (Error
     ("malformed branch line"
      (line "main\000aaaa\000*\000\000\000\0001\000s\000")))
    |}]
;;

(* Log *)

let log ?(cut = false) text =
  Show.or_error
    (fun commits -> print_s [%sexp (commits : Log.Commit.t list)])
    (Log.parse ~cut text)
;;

let%expect_test "Log.command" =
  print_s [%sexp (Exec.Spec.argv (Log.command ~cwd:"/w" ~limit:200) : string list)];
  print_s
    [%sexp
      (Or_error.try_with (fun () -> Log.command ~cwd:"/w" ~limit:0) |> Result.is_error
       : bool)];
  [%expect
    {|
    (git --no-pager -c color.ui=false -c core.quotepath=false log -z --no-color
     --no-show-signature --max-count=200
     --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s HEAD --)
    true
    |}]
;;

let two_commits =
  "a757577ac7f79aa5fd48614f00553a6319b37a4a\000f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49 \
   90c5cb54338b3e966f85a53c2456c64507430730\000Ches \
   Test\000ches-test@example.invalid\0001767225600\000Merge: \"x\" into \
   y\000f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49\000\000Zo\195\171\000zoe@example.invalid\0001767225500\000First\000"
;;

let%expect_test "Log: a merge and a root commit, empty, cut, malformed" =
  log two_commits;
  log "";
  log ~cut:true (String.prefix two_commits 200);
  log ~cut:true (String.prefix two_commits 20);
  log (String.prefix two_commits 200);
  log "a\000\000n\000e\000t\000s\000";
  log "\000\000n\000e\0001\000s\000";
  log "a\000\000n\000e\000s\000";
  (match Log.parse ~cut:false two_commits with
   | Ok (commit :: _) -> print_endline (Log.Commit.short_hash commit)
   | _ -> ());
  [%expect
    {|
    (((hash a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (parents
       (f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49
        90c5cb54338b3e966f85a53c2456c64507430730))
      (author_name "Ches Test") (author_email ches-test@example.invalid)
      (author_time 1767225600) (subject "Merge: \"x\" into y"))
     ((hash f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49) (parents ())
      (author_name "Zo\195\171") (author_email zoe@example.invalid)
      (author_time 1767225500) (subject First)))
    ()
    (((hash a757577ac7f79aa5fd48614f00553a6319b37a4a)
      (parents
       (f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49
        90c5cb54338b3e966f85a53c2456c64507430730))
      (author_name "Ches Test") (author_email ches-test@example.invalid)
      (author_time 1767225600) (subject "Merge: \"x\" into y")))
    ()
    (Error ("unterminated log record" (tail f6f211b39c22)))
    (Error ("malformed log record" (fields (a "" n e t s))))
    (Error ("malformed log record" (fields ("" "" n e 1 s))))
    (Error ("malformed log record" (fields (a "" n e s))))
    a757577
    |}]
;;

(* In-progress operations *)

let in_progress present =
  let git_dir = "/w/.git" in
  let outcomes =
    List.map (In_progress.reads ~git_dir) ~f:(fun (read : Job.File_read.t) ->
      let name = String.chop_prefix_exn read.path ~prefix:(git_dir ^ "/") in
      ( read
      , match List.Assoc.find present name ~equal:String.equal with
        | Some text -> Job.File_read.Result.Contents { text; truncated = false }
        | None -> Missing ))
  in
  match In_progress.parse ~git_dir outcomes with
  | Error error -> print_s [%sexp (error : Error.t)]
  | Ok operations ->
    print_s
      [%sexp
        (List.map operations ~f:(fun operation ->
           operation, In_progress.describe operation)
         : (In_progress.t * string) list)]
;;

let%expect_test "In_progress.reads" =
  List.iter (In_progress.reads ~git_dir:"/w/.git") ~f:(fun read ->
    print_s [%sexp (read : Job.File_read.t)]);
  [%expect
    {|
    ((path /w/.git/rebase-merge/head-name) (limit 4096))
    ((path /w/.git/rebase-merge/onto) (limit 4096))
    ((path /w/.git/rebase-apply/head-name) (limit 4096))
    ((path /w/.git/rebase-apply/onto) (limit 4096))
    ((path /w/.git/rebase-apply/applying) (limit 4096))
    ((path /w/.git/MERGE_HEAD) (limit 4096))
    ((path /w/.git/CHERRY_PICK_HEAD) (limit 4096))
    ((path /w/.git/REVERT_HEAD) (limit 4096))
    ((path /w/.git/BISECT_LOG) (limit 4096))
    |}]
;;

let%expect_test "In_progress: each operation and their combinations" =
  let onto = "4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94\n" in
  in_progress [];
  in_progress [ "rebase-merge/head-name", "refs/heads/main\n"; "rebase-merge/onto", onto ];
  in_progress [ "rebase-merge/head-name", "detached HEAD\n"; "rebase-merge/onto", onto ];
  in_progress [ "rebase-merge/head-name", "refs/heads/topic\n" ];
  in_progress [ "rebase-apply/head-name", "refs/heads/old\n"; "rebase-apply/onto", onto ];
  in_progress [ "rebase-apply/applying", "" ];
  in_progress
    [ "MERGE_HEAD", "90c5cb54338b3e966f85a53c2456c64507430730\nsecond\n"
    ; "BISECT_LOG", "git bisect start\n"
    ];
  in_progress [ "MERGE_HEAD", "\n" ];
  in_progress
    [ "rebase-merge/head-name", "refs/heads/main\n"
    ; "CHERRY_PICK_HEAD", "  4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94  \n"
    ];
  in_progress [ "REVERT_HEAD", "4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94\n" ];
  [%expect
    {|
    ()
    (((Rebase (interactive_backend true) (branch (main))
       (onto (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)))
      "Rebasing main onto 4e98047"))
    (((Rebase (interactive_backend true) (branch ())
       (onto (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)))
      "Rebasing detached HEAD onto 4e98047"))
    (((Rebase (interactive_backend true) (branch (topic)) (onto ()))
      "Rebasing topic"))
    (((Rebase (interactive_backend false) (branch (old))
       (onto (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)))
      "Rebasing old onto 4e98047"))
    ((Apply_mailbox "Applying patches"))
    (((Merge (head (90c5cb54338b3e966f85a53c2456c64507430730)))
      "Merging 90c5cb5")
     (Bisect Bisecting))
    (((Merge (head ())) Merging))
    (((Rebase (interactive_backend true) (branch (main)) (onto ()))
      "Rebasing main")
     ((Cherry_pick (commit (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)))
      "Cherry-picking 4e98047"))
    (((Revert (commit (4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)))
      "Reverting 4e98047"))
    |}]
;;

let%expect_test "In_progress: failed or mismatched reads are errors" =
  let git_dir = "/w/.git" in
  let reads = In_progress.reads ~git_dir in
  let missing = List.map reads ~f:(fun read -> read, Job.File_read.Result.Missing) in
  let failed =
    List.mapi reads ~f:(fun i read ->
      read, if i = 5 then Job.File_read.Result.Failed "Permission denied" else Missing)
  in
  let show outcomes =
    print_s [%sexp (In_progress.parse ~git_dir outcomes : In_progress.t list Or_error.t)]
  in
  show failed;
  show (List.tl_exn missing);
  print_s
    [%sexp (In_progress.parse ~git_dir:"/other/.git" missing |> Result.is_error : bool)];
  print_s [%sexp (In_progress.describe (Cherry_pick { commit = None }) : string)];
  print_s [%sexp (In_progress.describe (Revert { commit = None }) : string)];
  print_s
    [%sexp
      (In_progress.describe
         (Rebase { interactive_backend = true; branch = None; onto = None })
       : string)];
  [%expect
    {|
    (Error
     ("cannot read state file" (path /w/.git/MERGE_HEAD) "Permission denied"))
    (Error
     ("state-file reads do not match In_progress.reads" (git_dir /w/.git)
      (got
       (((path /w/.git/rebase-merge/onto) (limit 4096))
        ((path /w/.git/rebase-apply/head-name) (limit 4096))
        ((path /w/.git/rebase-apply/onto) (limit 4096))
        ((path /w/.git/rebase-apply/applying) (limit 4096))
        ((path /w/.git/MERGE_HEAD) (limit 4096))
        ((path /w/.git/CHERRY_PICK_HEAD) (limit 4096))
        ((path /w/.git/REVERT_HEAD) (limit 4096))
        ((path /w/.git/BISECT_LOG) (limit 4096))))))
    true
    Cherry-picking
    Reverting
    "Rebasing detached HEAD"
    |}]
;;
