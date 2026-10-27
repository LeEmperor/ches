open! Core
open Ches_vcs
module Cursor = Panel.Cursor
module Position = Panel.Position

let section_id = Panel.Section_id.of_string

(* [panel [ "unstaged", [ "a"; "b" ]; ... ]]: items carry their key as the value. *)
let panel sections : string Panel.t =
  { id = Panel.Id.of_string "files"
  ; title = "Files"
  ; sections =
      List.map sections ~f:(fun (id, keys) ->
        { Panel.Section.id = section_id id
        ; title = id
        ; items = List.map keys ~f:(fun key -> { Panel.Item.key; value = key })
        })
  }
;;

let item section key = Position.Item { section = section_id section; key }
let header section = Position.Header (section_id section)

let position_hum = function
  | None -> "none"
  | Some (Position.Header section) -> sprintf "[%s]" (Panel.Section_id.to_string section)
  | Some (Position.Item { section; key }) ->
    sprintf "%s/%s" (Panel.Section_id.to_string section) key
;;

let cursor ?(folded = []) selected =
  { Cursor.selected; folded = Panel.Section_id.Set.of_list (List.map folded ~f:section_id) }
;;

let reconcile ?folded selected ~previous ~current =
  let cursor = Cursor.reconcile (cursor ?folded selected) ~previous ~current in
  print_endline (position_hum cursor.selected)
;;

let files = panel [ "unstaged", [ "a"; "b"; "c"; "d" ]; "staged", [ "x"; "y" ] ]

let%expect_test "a selection still present keeps its identity, whatever moved around it" =
  reconcile
    (Some (item "unstaged" "c"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "0"; "a"; "c"; "e" ]; "staged", [ "x" ] ]);
  [%expect {| unstaged/c |}];
  reconcile
    (Some (header "staged"))
    ~previous:files
    ~current:(panel [ "untracked", [ "n" ]; "staged", [ "z" ] ]);
  [%expect {| [staged] |}]
;;

let%expect_test "a removed item selects the next item of its section" =
  reconcile
    (Some (item "unstaged" "b"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a"; "c"; "d" ]; "staged", [ "x"; "y" ] ]);
  [%expect {| unstaged/c |}];
  (* The next items are gone too: the first survivor after it. *)
  reconcile
    (Some (item "unstaged" "a"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "d" ]; "staged", [ "x"; "y" ] ]);
  [%expect {| unstaged/d |}];
  (* Order is the previous snapshot's: a new item in its place is not "next". *)
  reconcile
    (Some (item "unstaged" "b"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a"; "b2"; "c"; "d" ] ]);
  [%expect {| unstaged/c |}]
;;

let%expect_test "an item that moved to another section counts as removed from its own" =
  (* Staging b: it is now staged/b, but the selection stays in Unstaged. *)
  reconcile
    (Some (item "unstaged" "b"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a"; "c"; "d" ]; "staged", [ "b"; "x"; "y" ] ]);
  [%expect {| unstaged/c |}]
;;

let%expect_test "with no next survivor, the nearest previous one" =
  reconcile
    (Some (item "unstaged" "d"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a"; "b"; "c" ]; "staged", [ "x"; "y" ] ]);
  [%expect {| unstaged/c |}];
  reconcile
    (Some (item "unstaged" "c"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a" ]; "staged", [ "x"; "y" ] ]);
  [%expect {| unstaged/a |}]
;;

let%expect_test "with no survivor in a section that still exists, its header" =
  reconcile
    (Some (item "staged" "y"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a" ]; "staged", [ "z" ] ]);
  [%expect {| [staged] |}];
  (* An empty section that the backend keeps. *)
  reconcile
    (Some (item "staged" "x"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a" ]; "staged", [] ]);
  [%expect {| [staged] |}];
  (* A selection the previous panel did not have (inconsistent input). *)
  reconcile
    (Some (item "staged" "q"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a" ]; "staged", [ "x" ] ]);
  [%expect {| [staged] |}]
;;

let%expect_test "a section that disappeared: the nearest following header, else preceding" =
  let previous = panel [ "conflicted", [ "m" ]; "unstaged", [ "a" ]; "staged", [ "x" ] ] in
  reconcile
    (Some (item "unstaged" "a"))
    ~previous
    ~current:(panel [ "conflicted", [ "m" ]; "staged", [ "a"; "x" ] ]);
  [%expect {| [staged] |}];
  reconcile
    (Some (item "staged" "x"))
    ~previous
    ~current:(panel [ "conflicted", [ "m" ]; "unstaged", [ "a"; "x" ] ]);
  [%expect {| [unstaged] |}];
  (* Following sections are gone too: skip to the next one that exists. *)
  reconcile
    (Some (item "conflicted" "m"))
    ~previous
    ~current:(panel [ "staged", [ "m"; "x" ] ]);
  [%expect {| [staged] |}];
  (* A header whose section disappeared moves the same way. *)
  reconcile
    (Some (header "staged"))
    ~previous
    ~current:(panel [ "untracked", [ "n" ]; "unstaged", [ "a" ] ]);
  [%expect {| [unstaged] |}];
  (* None of the previous sections survive: the first row. *)
  reconcile
    (Some (item "unstaged" "a"))
    ~previous
    ~current:(panel [ "untracked", [ "n" ] ]);
  [%expect {| [untracked] |}];
  (* Nothing left at all. *)
  reconcile (Some (item "unstaged" "a")) ~previous ~current:(panel []);
  [%expect {| none |}]
;;

let%expect_test "no selection selects the first row once there is one" =
  reconcile None ~previous:(panel []) ~current:(panel []);
  [%expect {| none |}];
  reconcile None ~previous:(panel []) ~current:files;
  [%expect {| [unstaged] |}]
;;

let%expect_test "a target inside a folded section selects its header" =
  reconcile
    ~folded:[ "unstaged" ]
    None
    ~previous:(panel [])
    ~current:files;
  [%expect {| [unstaged] |}];
  (* An item kept in a section that is folded (the fold was remembered by id while
     the section was absent) shows as the header. *)
  reconcile
    ~folded:[ "staged" ]
    (Some (item "staged" "x"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a" ]; "staged", [ "x" ] ]);
  [%expect {| [staged] |}];
  (* The first row when nothing survives is the first visible one. *)
  reconcile
    ~folded:[ "untracked" ]
    (Some (item "unstaged" "a"))
    ~previous:(panel [ "unstaged", [ "a" ] ])
    ~current:(panel [ "untracked", [ "n" ]; "staged", [ "a" ] ]);
  [%expect {| [untracked] |}];
  (* Folded neighbours do not matter to an unfolded section's rule. *)
  reconcile
    ~folded:[ "staged" ]
    (Some (item "unstaged" "b"))
    ~previous:files
    ~current:(panel [ "unstaged", [ "a"; "c" ]; "staged", [ "x" ] ]);
  [%expect {| unstaged/c |}]
;;

let print_rows cursor panel =
  Cursor.rows cursor panel
  |> List.map ~f:(fun row -> position_hum (Some row))
  |> String.concat ~sep:" "
  |> print_endline
;;

let%expect_test "rows, select and folding" =
  let c = Cursor.reconcile Cursor.empty ~previous:files ~current:files in
  print_rows c files;
  [%expect {| [unstaged] unstaged/a unstaged/b unstaged/c unstaged/d [staged] staged/x staged/y |}];
  let c = Cursor.select c files (item "unstaged" "c") in
  print_endline (position_hum c.selected);
  [%expect {| unstaged/c |}];
  (* Not in the panel: unchanged. *)
  let c = Cursor.select c files (item "unstaged" "q") in
  print_endline (position_hum c.selected);
  [%expect {| unstaged/c |}];
  (* Folding the selection's section moves it to the header. *)
  let c = Cursor.toggle_fold c files (section_id "unstaged") in
  print_rows c files;
  print_endline (position_hum c.selected);
  [%expect
    {|
    [unstaged] [staged] staged/x staged/y
    [unstaged]
    |}];
  (* Selecting into a folded section selects its header. *)
  let c = Cursor.select c files (item "unstaged" "d") in
  print_endline (position_hum c.selected);
  [%expect {| [unstaged] |}];
  (* Folding another section leaves the selection; an absent section is ignored. *)
  let c = Cursor.select c files (item "staged" "y") in
  let c = Cursor.toggle_fold c files (section_id "untracked") in
  let c = Cursor.toggle_fold c files (section_id "unstaged") in
  print_rows c files;
  print_endline (position_hum c.selected);
  [%expect
    {|
    [unstaged] unstaged/a unstaged/b unstaged/c unstaged/d [staged] staged/x staged/y
    staged/y
    |}]
;;

let%expect_test "find, mem and validate" =
  print_s [%sexp (Panel.find files (item "staged" "x") : string Panel.Item.t option)];
  print_s [%sexp (Panel.find files (header "staged") : string Panel.Item.t option)];
  print_s
    [%sexp
      (List.map
         [ header "staged"; header "untracked"; item "staged" "a" ]
         ~f:(Panel.mem files)
       : bool list)];
  print_s [%sexp (Panel.validate files : unit Or_error.t)];
  print_s [%sexp (Panel.validate (panel [ "a", [ "1" ]; "a", [] ]) : unit Or_error.t)];
  print_s [%sexp (Panel.validate (panel [ "a", [ "1"; "2"; "1" ] ]) : unit Or_error.t)];
  [%expect
    {|
    (((key x) (value x)))
    ()
    (true false false)
    (Ok ())
    (Error ("Duplicate section" (section a)))
    (Error ("Duplicate key in section" (section a) (key 1)))
    |}]
;;
