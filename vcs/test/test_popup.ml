open! Core
open Ches_vcs

type action =
  | Commit of string list
  | Amend of string list
  | Extend
[@@deriving sexp_of]

let switch ?group key flag description = { Popup.Switch.key; flag; description; group }

let action key description run =
  { Popup.Action.key; description; run = (fun ~enabled -> run enabled) }
;;

(* Phase 5's commit popup, plus a grouped pair to show exclusion. *)
let commit =
  Popup.create
    ~title:"Commit"
    ~switches:
      [ switch 'n' "--no-verify" "Disable hooks"
      ; switch 's' "--signoff" "Add Signed-off-by line"
      ; switch 'e' "--allow-empty" "Allow empty commit"
      ; switch 'r' "--rebase" "Rebase" ~group:"integrate"
      ; switch 'f' "--ff-only" "Fast-forward only" ~group:"integrate"
      ]
    ~actions:
      [ action 'c' "Commit" (fun enabled -> Commit enabled)
      ; action 'a' "Amend" (fun enabled -> Amend enabled)
      ; action 'e' "Extend" (fun _ -> Extend)
      ]
  |> Or_error.ok_exn
;;

let press state key =
  let reply = Popup.press commit state key in
  print_s [%sexp (reply : action Popup.Reply.t)];
  match reply with
  | Updated state | Unbound { state; _ } -> state
  | Run _ -> state
;;

let%expect_test "switches toggle with a dash; actions run with the enabled flags" =
  let state = Popup.initial commit in
  let state = press state '-' in
  let state = press state 'n' in
  let state = press state '-' in
  let state = press state '-' in
  let state = press state 'e' in
  let (_ : Popup.State.t) = press state 'c' in
  let state = press state '-' in
  let state = press state 'n' in
  let (_ : Popup.State.t) = press state 'a' in
  let (_ : Popup.State.t) = press state 'e' in
  [%expect
    {|
    (Updated ((enabled ()) (dash true)))
    (Updated ((enabled (--no-verify)) (dash false)))
    (Updated ((enabled (--no-verify)) (dash true)))
    (Updated ((enabled (--no-verify)) (dash true)))
    (Updated ((enabled (--no-verify --allow-empty)) (dash false)))
    (Run (Commit (--no-verify --allow-empty)))
    (Updated ((enabled (--no-verify --allow-empty)) (dash true)))
    (Updated ((enabled (--allow-empty)) (dash false)))
    (Run (Amend (--allow-empty)))
    (Run Extend)
    |}]
;;

let%expect_test "groups exclude, unknown keys are unbound, escape clears the dash first" =
  let state = Popup.initial commit in
  let state = press (press state '-') 'f' in
  let state = press (press state '-') 's' in
  let state = press (press state '-') 'r' in
  let state = press state 'x' in
  let state = press (press state '-') 'x' in
  [%expect
    {|
    (Updated ((enabled ()) (dash true)))
    (Updated ((enabled (--ff-only)) (dash false)))
    (Updated ((enabled (--ff-only)) (dash true)))
    (Updated ((enabled (--signoff --ff-only)) (dash false)))
    (Updated ((enabled (--signoff --ff-only)) (dash true)))
    (Updated ((enabled (--signoff --rebase)) (dash false)))
    (Unbound (state ((enabled (--signoff --rebase)) (dash false))) (key x))
    (Updated ((enabled (--signoff --rebase)) (dash true)))
    (Unbound (state ((enabled (--signoff --rebase)) (dash false))) (key -x))
    |}];
  print_s
    [%sexp
      (List.map (Popup.enabled commit state) ~f:(fun s -> s.flag) : string list)
    , (Popup.escape { state with dash = true }
       : [ `Close | `Updated of Popup.State.t ])
    , (Popup.escape state : [ `Close | `Updated of Popup.State.t ])];
  [%expect
    {|
    ((--signoff --rebase) (Updated ((enabled (--signoff --rebase)) (dash false)))
     Close)
    |}]
;;

let%expect_test "initial switches are filtered, ordered, and grouped" =
  print_s
    [%sexp
      (Popup.initial commit ~enabled:[ "--rebase"; "--bogus"; "--ff-only"; "--no-verify" ]
       : Popup.State.t)];
  [%expect {| ((enabled (--no-verify --rebase)) (dash false)) |}]
;;

let%expect_test "help lists switches then actions" =
  List.iter (Popup.help commit) ~f:(fun (keys, description) ->
    printf "%-3s %s\n" keys description);
  [%expect
    {|
    -n  Disable hooks (--no-verify)
    -s  Add Signed-off-by line (--signoff)
    -e  Allow empty commit (--allow-empty)
    -r  Rebase (--rebase)
    -f  Fast-forward only (--ff-only)
    c   Commit
    a   Amend
    e   Extend
    |}]
;;

let%expect_test "creation is validated" =
  let try_create ?(title = "T") switches actions =
    match Popup.create ~title ~switches ~actions with
    | Ok _ -> print_endline "ok"
    | Error error -> print_s [%sexp (error : Error.t)]
  in
  let run = action 'c' "Commit" (fun _ -> Extend) in
  try_create [] [ run ];
  try_create ~title:"" [] [ run ];
  try_create [] [ action 'q' "Quit?" (fun _ -> Extend) ];
  try_create [ switch '-' "--x" "X" ] [];
  try_create [] [ action '?' "Help" (fun _ -> Extend) ];
  try_create [] [ action ' ' "Space" (fun _ -> Extend) ];
  try_create [] [ run; action 'c' "Again" (fun _ -> Extend) ];
  try_create [ switch 'n' "--a" "A"; switch 'n' "--b" "B" ] [];
  try_create [ switch 'n' "--a" "A"; switch 'm' "--a" "B" ] [];
  try_create [ switch 'n' "" "A" ] [];
  try_create [ switch 'n' "--a" "" ] [];
  try_create [ switch 'n' "--a" "A" ~group:"" ] [];
  [%expect
    {|
    ok
    "Popup title is empty"
    ("Popup key is reserved or not printable" (key q))
    ("Popup key is reserved or not printable" (key -))
    ("Popup key is reserved or not printable" (key ?))
    ("Popup key is reserved or not printable" (key " "))
    "Popup action key used twice"
    "Popup switch key used twice"
    "Popup switch flags must be nonempty and unique"
    "Popup switch flags must be nonempty and unique"
    "Popup entry description is empty"
    "Popup switch group is empty"
    |}]
;;
