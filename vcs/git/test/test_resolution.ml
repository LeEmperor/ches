(* Whole-file conflict resolution (phase 7): Resolution.has_file, labels and the resolve
   popup as pure functions; then the Resolve plans against a fixture merge with every kind
   of conflict git produces (both modified, both added, modified/deleted both ways, and a
   rename/rename conflict for added by us, added by them and both deleted), each side
   taken and run. Helpers in plan_fixture.ml. *)

open! Core
open Ches_vcs
open Plan_fixture
module Resolution = Ches_vcs_git.Resolution
module Conflict = Ches_vcs_git.Status.Conflict

let conflicts : Conflict.t list =
  [ Both_modified
  ; Both_added
  ; Added_by_us
  ; Deleted_by_them
  ; Added_by_them
  ; Deleted_by_us
  ; Both_deleted
  ]
;;

let print_popup (popup : _ Popup.t) =
  print_endline popup.title;
  List.iter popup.actions ~f:(fun action ->
    printf
      "  %c %-45s -> %s\n"
      action.key
      action.description
      (Sexp.to_string [%sexp (action.run ~enabled:[] : Resolution.Side.t)]))
;;

let%expect_test "has_file: which sides have the file" =
  List.iter conflicts ~f:(fun conflict ->
    printf
      "%-16s ours %-5b theirs %-5b markers %b\n"
      (Conflict.to_string_hum conflict)
      (Resolution.has_file conflict Ours)
      (Resolution.has_file conflict Theirs)
      (Resolution.has_file conflict Markers));
  [%expect
    {|
    both modified    ours true  theirs true  markers true
    both added       ours true  theirs true  markers true
    added by us      ours true  theirs false markers false
    deleted by them  ours true  theirs false markers false
    added by them    ours false theirs true  markers false
    deleted by us    ours false theirs true  markers false
    both deleted     ours false theirs false markers false
    |}]
;;

let%expect_test "labels: from the first operation in progress" =
  let hash = "0123456789abcdef0123456789abcdef01234567" in
  let rebase : Git.In_progress.t =
    Rebase { interactive_backend = true; branch = Some "main"; onto = Some hash }
  in
  List.iter
    ~f:(fun operations ->
      let ours, theirs = Resolution.labels operations in
      printf
        "%-34s ours %S, theirs %S\n"
        (match operations with
         | [] -> "(nothing)"
         | _ -> String.concat ~sep:", " (List.map operations ~f:Git.In_progress.describe))
        ours
        theirs)
    [ [ rebase ]
    ; [ Rebase { interactive_backend = false; branch = None; onto = None } ]
    ; [ Merge { head = Some hash } ]
    ; [ Merge { head = None } ]
    ; [ Merge { head = Some "abc" } ]
    ; [ Cherry_pick { commit = Some hash } ]
    ; [ Revert { commit = None } ]
    ; [ Apply_mailbox ]
    ; [ Bisect ]
    ; []
    ; [ rebase; Merge { head = Some hash } ]
    ; [ Merge { head = Some hash }; Bisect ]
    ];
  [%expect
    {|
    Rebasing main onto 0123456         ours "the upstream", theirs "your commit"
    Rebasing detached HEAD             ours "the upstream", theirs "your commit"
    Merging 0123456                    ours "HEAD", theirs "0123456"
    Merging                            ours "HEAD", theirs "the merged branch"
    Merging abc                        ours "HEAD", theirs "abc"
    Cherry-picking 0123456             ours "HEAD", theirs "the other side"
    Reverting                          ours "HEAD", theirs "the other side"
    Applying patches                   ours "HEAD", theirs "the other side"
    Bisecting                          ours "HEAD", theirs "the other side"
    (nothing)                          ours "HEAD", theirs "the other side"
    Rebasing main onto 0123456, Merging 0123456 ours "the upstream", theirs "your commit"
    Merging 0123456, Bisecting         ours "HEAD", theirs "0123456"
    |}]
;;

let%expect_test "popup: every conflict kind, merging and rebasing" =
  let merging : Git.In_progress.t list =
    [ Merge { head = Some "fedcba9876543210fedcba9876543210fedcba98" } ]
  in
  List.iter conflicts ~f:(fun conflict ->
    print_popup (Resolution.popup ~path:"dir/a b.txt" conflict merging));
  print_endline "-- rebasing: ours is the upstream";
  List.iter [ Conflict.Both_modified; Deleted_by_us ] ~f:(fun conflict ->
    print_popup
      (Resolution.popup
         ~path:"f.txt"
         conflict
         [ Rebase { interactive_backend = true; branch = Some "main"; onto = None } ]));
  print_endline "-- nothing in progress (a stash that did not apply)";
  print_popup (Resolution.popup ~path:"f.txt" Both_modified []);
  [%expect
    {|
    Resolve dir/a b.txt
      o Take ours (HEAD)                              -> Ours
      t Take theirs (fedcba9)                         -> Theirs
      m Restore the conflict markers                  -> Markers
    Resolve dir/a b.txt
      o Take ours (HEAD)                              -> Ours
      t Take theirs (fedcba9)                         -> Theirs
      m Restore the conflict markers                  -> Markers
    Resolve dir/a b.txt
      o Take ours (HEAD)                              -> Ours
      t Take theirs: delete the file (fedcba9)        -> Theirs
    Resolve dir/a b.txt
      o Take ours (HEAD)                              -> Ours
      t Take theirs: delete the file (fedcba9)        -> Theirs
    Resolve dir/a b.txt
      o Take ours: delete the file (HEAD)             -> Ours
      t Take theirs (fedcba9)                         -> Theirs
    Resolve dir/a b.txt
      o Take ours: delete the file (HEAD)             -> Ours
      t Take theirs (fedcba9)                         -> Theirs
    Resolve dir/a b.txt
      o Take ours: delete the file (HEAD)             -> Ours
      t Take theirs: delete the file (fedcba9)        -> Theirs
    -- rebasing: ours is the upstream
    Resolve f.txt
      o Take ours (the upstream)                      -> Ours
      t Take theirs (your commit)                     -> Theirs
      m Restore the conflict markers                  -> Markers
    Resolve f.txt
      o Take ours: delete the file (the upstream)     -> Ours
      t Take theirs (your commit)                     -> Theirs
    -- nothing in progress (a stash that did not apply)
    Resolve f.txt
      o Take ours (HEAD)                              -> Ours
      t Take theirs (the other side)                  -> Theirs
      m Restore the conflict markers                  -> Markers
    |}]
;;

(* Fixtures *)

(* A merge of [other] into [main] stopping with one conflict of each kind git produces,
   the file named after its status code: uu.txt, aa.txt, ud.txt (we modified, they
   deleted), du.txt (we deleted, they modified), and a rename/rename conflict of dd.txt
   (both deleted) to dd-main.txt (added by us) and dd-other.txt (added by them). *)
let conflicted_merge t =
  List.iter [ "uu.txt"; "ud.txt"; "du.txt"; "dd.txt" ] ~f:(fun path ->
    Fixture.write t path "base\n");
  commit t "Base";
  git t [ "switch"; "-q"; "-c"; "other" ];
  Fixture.write t "uu.txt" "theirs\n";
  Fixture.write t "aa.txt" "theirs\n";
  Fixture.write t "du.txt" "theirs\n";
  git t [ "rm"; "-q"; "ud.txt" ];
  git t [ "mv"; "dd.txt"; "dd-other.txt" ];
  commit t "Theirs";
  git t [ "switch"; "-q"; "main" ];
  Fixture.write t "uu.txt" "ours\n";
  Fixture.write t "aa.txt" "ours\n";
  Fixture.write t "ud.txt" "ours\n";
  git t [ "rm"; "-q"; "du.txt" ];
  git t [ "mv"; "dd.txt"; "dd-main.txt" ];
  commit t "Ours";
  (* Stops on the conflicts (exit 1); --no-edit: no editor, whatever the environment. *)
  ignore
    (Fixture.run
       t
       (Exec.Spec.create
          ~kind:Mutate
          ~cwd:t.work
          "git"
          [ "merge"; "--no-edit"; "-q"; "other" ])
     : Exec.Result.t)
;;

let paths =
  [ "uu.txt"; "aa.txt"; "ud.txt"; "du.txt"; "dd-main.txt"; "dd-other.txt"; "dd.txt" ]
;;

(* The path's status line and its work-tree contents. *)
let show_path t path =
  let status =
    match output t [ "status"; "--porcelain"; "--"; path ] with
    | "" -> "(clean)"
    | line -> line
  in
  let contents =
    match In_channel.read_all (Fixture.path t path) with
    | text -> sprintf "%S" text
    | exception _ -> "absent"
  in
  printf "  -> %s; work tree: %s\n" status contents
;;

let resolve_each t side =
  let s = snapshot t in
  List.iter paths ~f:(fun path ->
    act ~snapshot:s t (Resolve { path; side });
    show_path t path)
;;

let%expect_test "resolve: take ours for every kind" =
  Fixture.with_repo (fun t ->
    conflicted_merge t;
    head t;
    resolve_each t Ours;
    status t);
  [%expect
    {|
      head: main; Merging 8fa8851; conflicted aa.txt; conflicted dd-main.txt; conflicted dd-other.txt; conflicted dd.txt; conflicted du.txt; conflicted ud.txt; conflicted uu.txt
    confirm "Resolve uu.txt": Take ours (HEAD) for uu.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for uu.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- uu.txt (Mutate)
      $ --literal-pathspecs add --all -- uu.txt (Mutate)
      ok
      -> (clean); work tree: "ours\n"
    confirm "Resolve aa.txt": Take ours (HEAD) for aa.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for aa.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- aa.txt (Mutate)
      $ --literal-pathspecs add --all -- aa.txt (Mutate)
      ok
      -> (clean); work tree: "ours\n"
    confirm "Resolve ud.txt": Take ours (HEAD) for ud.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for ud.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- ud.txt (Mutate)
      $ --literal-pathspecs add --all -- ud.txt (Mutate)
      ok
      -> (clean); work tree: "ours\n"
    confirm "Resolve du.txt": Resolve du.txt by deleting it, as ours (HEAD) did? Any edits to the file are lost.
      plan "Delete du.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- du.txt (Mutate)
      ok
      -> (clean); work tree: absent
    confirm "Resolve dd-main.txt": Take ours (HEAD) for dd-main.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take ours for dd-main.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --ours -- dd-main.txt (Mutate)
      $ --literal-pathspecs add --all -- dd-main.txt (Mutate)
      ok
      -> (clean); work tree: "base\n"
    confirm "Resolve dd-other.txt": Resolve dd-other.txt by deleting it, as ours (HEAD) did? Any edits to the file are lost.
      plan "Delete dd-other.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- dd-other.txt (Mutate)
      ok
      -> (clean); work tree: absent
    confirm "Resolve dd.txt": Resolve dd.txt by deleting it, as ours (HEAD) did? Any edits to the file are lost.
      plan "Delete dd.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- dd.txt (Mutate)
      ok
      -> (clean); work tree: absent
      status: clean
    |}]
;;

let%expect_test "resolve: take theirs for every kind" =
  Fixture.with_repo (fun t ->
    conflicted_merge t;
    resolve_each t Theirs;
    status t);
  [%expect
    {|
    confirm "Resolve uu.txt": Take theirs (8fa8851) for uu.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for uu.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- uu.txt (Mutate)
      $ --literal-pathspecs add --all -- uu.txt (Mutate)
      ok
      -> M  uu.txt; work tree: "theirs\n"
    confirm "Resolve aa.txt": Take theirs (8fa8851) for aa.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for aa.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- aa.txt (Mutate)
      $ --literal-pathspecs add --all -- aa.txt (Mutate)
      ok
      -> M  aa.txt; work tree: "theirs\n"
    confirm "Resolve ud.txt": Resolve ud.txt by deleting it, as theirs (8fa8851) did? Any edits to the file are lost.
      plan "Delete ud.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- ud.txt (Mutate)
      ok
      -> D  ud.txt; work tree: absent
    confirm "Resolve du.txt": Take theirs (8fa8851) for du.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for du.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- du.txt (Mutate)
      $ --literal-pathspecs add --all -- du.txt (Mutate)
      ok
      -> A  du.txt; work tree: "theirs\n"
    confirm "Resolve dd-main.txt": Resolve dd-main.txt by deleting it, as theirs (8fa8851) did? Any edits to the file are lost.
      plan "Delete dd-main.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- dd-main.txt (Mutate)
      ok
      -> D  dd-main.txt; work tree: absent
    confirm "Resolve dd-other.txt": Take theirs (8fa8851) for dd-other.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for dd-other.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- dd-other.txt (Mutate)
      $ --literal-pathspecs add --all -- dd-other.txt (Mutate)
      ok
      -> A  dd-other.txt; work tree: "base\n"
    confirm "Resolve dd.txt": Resolve dd.txt by deleting it, as theirs (8fa8851) did? Any edits to the file are lost.
      plan "Delete dd.txt (resolved)" (rewrites the work tree)
      $ --literal-pathspecs rm --quiet -- dd.txt (Mutate)
      ok
      -> (clean); work tree: absent
      status |M  aa.txt
      status |R  dd-main.txt -> dd-other.txt
      status |A  du.txt
      status |D  ud.txt
      status |M  uu.txt
    |}]
;;

let%expect_test "resolve: restore markers (both modified, both added); refused otherwise" =
  Fixture.with_repo (fun t ->
    conflicted_merge t;
    (* Half-resolved in the editor, unsaved work aside: the markers come back. *)
    Fixture.write t "uu.txt" "half resolved\n";
    git t [ "checkout"; "--theirs"; "--"; "aa.txt" ];
    resolve_each t Markers;
    print_endline "-- the markers are git's checkout --merge labels";
    print_string (In_channel.read_all (Fixture.path t "uu.txt"));
    print_endline "-- staged (resolved): no longer conflicted, so refused";
    git t [ "add"; "--"; "uu.txt" ];
    act t (Resolve { path = "uu.txt"; side = Markers });
    act t (Resolve { path = "uu.txt"; side = Ours });
    (* git 2.43 itself would not fail here: checkout --merge recreates the conflict from
       the index's resolve-undo record, so the refusal above is what keeps a resolved file
       resolved. *)
    git t [ "checkout"; "--merge"; "--"; "uu.txt" ];
    printf
      "  git checkout --merge after add: %s\n"
      (output t [ "status"; "--porcelain"; "uu.txt" ]);
    print_endline "-- not listed at all";
    act t (Resolve { path = "nowhere.txt"; side = Theirs }));
  [%expect
    {|
    confirm "Resolve uu.txt": Restore the conflict markers in uu.txt? Edits to the file are lost.
      plan "Restore conflict markers in uu.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --merge -- uu.txt (Mutate)
      ok
      -> UU uu.txt; work tree: "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
    confirm "Resolve aa.txt": Restore the conflict markers in aa.txt? Edits to the file are lost.
      plan "Restore conflict markers in aa.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --merge -- aa.txt (Mutate)
      ok
      -> AA aa.txt; work tree: "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
    refused: ud.txt has no conflict markers to restore (deleted by them); nothing ran
      -> UD ud.txt; work tree: "ours\n"
    refused: du.txt has no conflict markers to restore (deleted by us); nothing ran
      -> DU du.txt; work tree: "theirs\n"
    refused: dd-main.txt has no conflict markers to restore (added by us); nothing ran
      -> AU dd-main.txt; work tree: "base\n"
    refused: dd-other.txt has no conflict markers to restore (added by them); nothing ran
      -> UA dd-other.txt; work tree: "base\n"
    refused: dd.txt has no conflict markers to restore (both deleted); nothing ran
      -> DD dd.txt; work tree: absent
    -- the markers are git's checkout --merge labels
    <<<<<<< ours
    ours
    =======
    theirs
    >>>>>>> theirs
    -- staged (resolved): no longer conflicted, so refused
    refused: uu.txt is not conflicted; nothing ran
    refused: uu.txt is not conflicted; nothing ran
      git checkout --merge after add: UU uu.txt
    -- not listed at all
    refused: nowhere.txt is not conflicted; nothing ran
    |}]
;;

let%expect_test "resolve: odd paths are literal pathspecs" =
  Fixture.with_repo (fun t ->
    let path = "*-[x] :odd.txt" in
    Fixture.write t path "base\n";
    Fixture.write t "a-x.txt" "bystander\n";
    commit t "Base";
    git t [ "switch"; "-q"; "-c"; "other" ];
    Fixture.write t path "theirs\n";
    commit t "Theirs";
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t path "ours\n";
    commit t "Ours";
    ignore
      (Fixture.run
         t
         (Exec.Spec.create
            ~kind:Mutate
            ~cwd:t.work
            "git"
            [ "merge"; "--no-edit"; "-q"; "other" ])
       : Exec.Result.t);
    act t (Resolve { path; side = Theirs });
    show_path t path;
    status t);
  [%expect
    {|
    confirm "Resolve *-[x] :odd.txt": Take theirs (c98b42a) for *-[x] :odd.txt? The other side's changes and any edits to the file are lost; it is marked resolved.
      plan "Take theirs for *-[x] :odd.txt" (rewrites the work tree)
      $ --literal-pathspecs checkout --theirs -- '*-[x] :odd.txt' (Mutate)
      $ --literal-pathspecs add --all -- '*-[x] :odd.txt' (Mutate)
      ok
      -> M  "*-[x] :odd.txt"; work tree: "theirs\n"
      status |M  "*-[x] :odd.txt"
    |}]
;;
