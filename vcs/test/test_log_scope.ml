(* Log scopes (phase 8): the Commits section's title, [+]'s doubling up to the cap, and
   when the graph is drawn. *)

open! Core
open Ches_vcs

let default = Log_scope.default

let%expect_test "default" =
  print_s [%sexp (default : Log_scope.t)];
  print_s [%sexp (Log_scope.default_limit : int), (Log_scope.max_limit : int)];
  [%expect
    {|
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
    (200 12800)
    |}]
;;

let%expect_test "title: each range, a path, the qualifiers, the first <n> boundary" =
  let title ?(shown = 3) scope = print_endline (Log_scope.title scope ~shown) in
  title default;
  title { default with range = Branch "feature/x" };
  title { default with range = All };
  (* A path names the history whatever the range. *)
  title { default with path = Some "src/a b.ml" };
  title { default with range = Branch "dev"; path = Some "a*.txt" };
  title { default with range = All; merges = false };
  title { default with first_parent = true };
  title { default with range = Branch "main"; merges = false; first_parent = true };
  (* [first <limit>] once the read gave as many commits as it asked for. *)
  title ~shown:199 default;
  title ~shown:200 default;
  title ~shown:201 default;
  title ~shown:3 { default with limit = 3 };
  title ~shown:2 { default with limit = 3 };
  title ~shown:200 { default with range = Branch "main"; merges = false };
  title
    ~shown:400
    { default with path = Some "f.ml"; merges = false; first_parent = true; limit = 400 };
  (* The graph switch does not show. *)
  title { default with graph = false };
  [%expect
    {|
    Recent commits
    Commits on feature/x
    All branches
    History of src/a b.ml
    History of a*.txt
    All branches (no merges)
    Recent commits (first parent)
    Commits on main (no merges, first parent)
    Recent commits
    Recent commits (first 200)
    Recent commits (first 200)
    Recent commits (first 3)
    Recent commits
    Commits on main (no merges, first 200)
    History of f.ml (no merges, first parent, first 400)
    Recent commits
    |}]
;;

let%expect_test "more doubles the limit up to the cap, then None" =
  let rec go scope =
    match Log_scope.more scope with
    | None -> printf "None at %d\n" scope.Log_scope.limit
    | Some (next : Log_scope.t) ->
      printf "%d -> %d\n" scope.limit next.limit;
      assert (Log_scope.equal next { scope with limit = next.limit });
      go next
  in
  go default;
  [%expect
    {|
    200 -> 400
    400 -> 800
    800 -> 1600
    1600 -> 3200
    3200 -> 6400
    6400 -> 12800
    None at 12800
    |}];
  (* A limit that does not double onto the cap stops at it. *)
  go { default with limit = 7000 };
  go { default with limit = 12799 };
  [%expect
    {|
    7000 -> 12800
    None at 12800
    12799 -> 12800
    None at 12800
    |}]
;;

let%expect_test "graph_shown: the graph switch, without a path, with merges" =
  List.iter
    [ "default", default
    ; "graph off", { default with graph = false }
    ; "a path", { default with path = Some "f.ml" }
    ; "no merges", { default with merges = false }
    ; "first parent", { default with first_parent = true }
    ; "all branches", { default with range = All }
    ; "a branch", { default with range = Branch "dev" }
    ]
    ~f:(fun (name, scope) -> printf "%s: %b\n" name (Log_scope.graph_shown scope));
  [%expect
    {|
    default: true
    graph off: false
    a path: false
    no merges: false
    first parent: true
    all branches: true
    a branch: true
    |}]
;;
