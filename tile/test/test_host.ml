open! Core
open Ches_input
open Ches_tile

let document = View_id.of_string "document"
let status = View_id.of_string "status"
let report = View_id.of_string "report"
let other = View_id.of_string "other"

let host () =
  Host.create
    ~leader:(Key.char ' ')
    ~primary:document
    [ Spec.primary document ~title:"Document"
    ; Spec.companion status ~title:"Status"
    ; Spec.read_only report ~title:"Report"
    ; Spec.read_only other ~title:"Other"
    ]
;;

let keys s =
  List.map (Key_notation.keys s) ~f:(function
    | Key key -> key
    | Paste _ -> assert false)
;;

let all _ = true

let%test_unit "Tab delegation is explicit, not implied by accepting text or paste" =
  List.iter
    [ Spec.read_only report ~title:"Report", false
    ; Spec.text_input report ~title:"Prompt", false
    ; Spec.result_picker report ~title:"Results", true
    ] ~f:(fun (spec, delegates) ->
      let t = Host.create ~leader:(Key.char ' ') ~primary:document
        [ Spec.primary document ~title:"Document"; spec ] |> fun t -> Host.focus t report in
      let route key = snd (Host.key t key ~lookup:(fun _ -> Bindings.Unbound)
        ~content:(function
          | [ Key.Tab ] -> Content_key.Action `Next
          | [ Key.Shift_tab ] -> Action `Previous
          | _ -> Unbound)
        ~escape:None ~hint:"hint") in
      assert (match route Key.Tab with
        | Content `Next -> delegates
        | Return -> not delegates
        | _ -> false);
      assert (match route Key.Shift_tab with
        | Content `Previous -> delegates
        | Handled -> not delegates
        | _ -> false);
      assert (match route Key.Escape with Return -> true | _ -> false))
;;

(* A content adapter that knows only [x] and the shared list motions, and closes
   something on Escape when [open_] is set. *)
let content keys : [ `X | `Close | `Move of Navigation.Motion.t ] Content_key.t =
  match keys with
  | [ key ] when Key.equal key (Key.char 'x') -> Action `X
  | keys -> Content_key.map (Navigation.interpret keys) ~f:(fun m -> `Move m)
;;

(* The default keymap, plus a leader-bound document scroll. *)
let lookup = function
  | [ space; s ] when Key.equal space (Key.char ' ') && Key.equal s (Key.char 's') ->
    Bindings.Bound (Scroll Line_down)
  | keys -> Bindings.find Bindings.default keys
;;

let type_ ?(open_ = false) t s =
  List.fold_map (keys s) ~init:t ~f:(fun t key ->
    let t, decision =
      Host.key
        t
        key
        ~lookup
        ~content
        ~escape:(Option.some_if open_ `Close)
        ~hint:"hint"
    in
    let t =
      match decision with
      | Notice text -> Host.with_notice t text
      | Return -> Host.return t
      | Handled | Workspace _ | Content _ -> t
    in
    t, decision)
;;

let show ?open_ t s =
  let t, decisions = type_ ?open_ t s in
  List.iter decisions ~f:(fun decision ->
    print_s [%sexp (decision : [ `X | `Close | `Move of Navigation.Motion.t ] Host.Decision.t)]);
  t
;;

let%expect_test "capture precedence: prefixes, workspace bindings, content, and return" =
  let t = Host.focus (host ()) report in
  let t = show t "xjggG<C-d>" in
  [%expect
    {|
    (Content X)
    (Content (Move Down))
    Handled
    (Content (Move First))
    (Content (Move Last))
    (Content (Move Half_down))
    |}];
  (* Leader sequences use the configured keymap; editor commands and document
     scrolling never run from capture. *)
  let t = show t " w s vQ ve" in
  [%expect
    {|
    Handled
    (Notice "Editor command unavailable; Escape returns to editor")
    Handled
    (Notice "Document scrolling is unavailable here")
    Handled
    Handled
    (Notice "Unbound workspace key")
    Handled
    Handled
    (Workspace Inspect_problems)
    |}];
  ignore (show t " v" : Host.t);
  [%expect {|
    Handled
    Handled
    |}];
  let t, _ = type_ t " v" in
  print_s [%sexp (Host.pending t : Key.t list)];
  [%expect {| ((Char U+0020) (Char U+0076)) |}];
  (* Escape cancels the prefix before anything else; then the content's own escape;
     then it returns. *)
  let t = show ~open_:true t "<Esc><Esc>" in
  [%expect {|
    Handled
    (Content Close)
    |}];
  (* [Space q] (quit) is an editor command, so it never runs from capture. *)
  let t = show t "gqq q<C-c><Esc>" in
  [%expect
    {|
    Handled
    (Notice "Cancelled prefix")
    (Notice hint)
    Handled
    (Notice "Editor command unavailable; Escape returns to editor")
    (Notice "Escape returns to the editor")
    Return
    |}];
  print_s [%sexp (Host.focused t ~available:all : View_id.t)];
  [%expect {| document |}];
  let t = Host.focus t report in
  ignore (show t "<Tab>" : Host.t);
  [%expect {| Return |}]
;;

let%expect_test "focus is a request: availability, reconciliation, and cursor ownership" =
  let t = host () in
  let show t ~available =
    print_s
      [%sexp
        { focused : View_id.t = Host.focused t ~available
        ; capturing : View_id.t option = Host.capturing t ~available
        ; cursor : View_id.t option = Host.cursor_owner t ~available
        }]
  in
  show t ~available:all;
  [%expect {| ((focused document) (capturing ()) (cursor (document))) |}];
  (* Status is a non-focusable companion. *)
  show (Host.focus t status) ~available:all;
  [%expect {| ((focused document) (capturing ()) (cursor (document))) |}];
  let t = Host.focus t report in
  show t ~available:all;
  [%expect {| ((focused report) (capturing (report)) (cursor ())) |}];
  let hidden id = not (View_id.equal id report) in
  show t ~available:hidden;
  [%expect {| ((focused document) (capturing ()) (cursor (document))) |}];
  (match Host.reconcile t ~available:all with
   | _, `Kept -> print_endline "kept while available"
   | _, `Returned _ -> assert false);
  [%expect {| kept while available |}];
  let t, returned = Host.reconcile t ~available:hidden in
  print_s [%sexp (returned : [ `Kept | `Returned of View_id.t ])];
  show t ~available:all;
  [%expect
    {|
    (Returned report)
    ((focused document) (capturing ()) (cursor (document)))
    |}]
;;

let%expect_test "a paste belongs to the view that started it" =
  let paste t ~available =
    let t = Host.paste_start t ~available in
    (* Focus changes mid-paste; keys without text are dropped. *)
    let t = Host.focus (Host.return t) other in
    let t = List.fold (keys "ab<Esc>c<CR>") ~init:t ~f:Host.paste_key in
    let t, result = Host.paste_end t in
    print_s
      [%sexp
        (result
         : [ `Deliver of View_id.t * string | `Reject of View_id.t * string | `Not_pasting ])];
    assert (not (Host.pasting t))
  in
  paste (Host.focus (host ()) report) ~available:all;
  paste (host ()) ~available:all;
  paste (Host.focus (host ()) report) ~available:(fun id -> not (View_id.equal id report));
  print_s [%sexp (snd (Host.paste_end (host ())) : [ `Deliver of View_id.t * string | `Reject of View_id.t * string | `Not_pasting ])];
  [%expect
    {|
    (Reject (report "Report: read-only; paste ignored"))
    (Deliver (document "abc\n"))
    (Deliver (document "abc\n"))
    Not_pasting
    |}]
;;

let%expect_test "a text-input view takes the leader as text; Escape still returns" =
  let prompt = View_id.of_string "prompt" in
  let t =
    Host.create
      ~leader:(Key.char ' ')
      ~primary:document
      [ Spec.primary document ~title:"Document"; Spec.text_input prompt ~title:"Prompt" ]
  in
  let t = Host.focus t prompt in
  print_s [%sexp (Host.cursor_owner t ~available:all : View_id.t option)];
  [%expect {| (prompt) |}];
  (* Every key is text: no workspace sequence starts, and [j] is not a list motion. *)
  let text keys : Key.t Content_key.t =
    match keys with
    | [ key ] -> Action key
    | _ -> Unbound
  in
  let t =
    List.fold (keys " vj<Tab>") ~init:t ~f:(fun t key ->
      let t, decision = Host.key t key ~lookup ~content:text ~escape:None ~hint:"hint" in
      print_s [%sexp (decision : Key.t Host.Decision.t)];
      match decision with
      | Return -> Host.return (Host.focus t prompt)
      | _ -> t)
  in
  let t, decision = Host.key t Escape ~lookup ~content:text ~escape:None ~hint:"hint" in
  print_s [%sexp (decision : Key.t Host.Decision.t), (Host.pending t : Key.t list)];
  [%expect
    {|
    (Content (Char U+0020))
    (Content (Char U+0076))
    (Content (Char U+006A))
    Return
    (Return ())
    |}];
  (* A paste started there is delivered. *)
  let t = Host.paste_start (Host.focus t prompt) ~available:all in
  let t = List.fold (keys "a b") ~init:t ~f:Host.paste_key in
  print_s
    [%sexp
      (snd (Host.paste_end t)
       : [ `Deliver of View_id.t * string | `Reject of View_id.t * string | `Not_pasting ])];
  [%expect {| (Deliver (prompt "a b")) |}]
;;

let%expect_test "selection follows opaque keys and picks a neighbor when one disappears" =
  let module S = Navigation.Selection in
  let show (s : string S.t) =
    print_s [%sexp (s.selected : string option), (s.index : int), (s.top : int)]
  in
  let fit s keys = S.fit s keys ~equal:String.equal ~rows:3 in
  let keys = [ "a"; "b"; "c"; "d"; "e"; "f" ] in
  let s = S.move (fit S.empty keys) keys ~equal:String.equal ~rows:3 Last in
  show s;
  let s = S.move s keys ~equal:String.equal ~rows:3 Half_up in
  show s;
  (* "e" moves, and the selection follows it. *)
  show (fit s [ "e"; "a"; "b" ]);
  (* "e" is gone: the item now at its index, or the last. *)
  show (fit s [ "a"; "b"; "c"; "d"; "f" ]);
  show (fit s [ "a"; "b" ]);
  show (fit s []);
  [%expect
    {|
    ((f) 5 3)
    ((e) 4 3)
    ((e) 0 0)
    ((f) 4 2)
    ((b) 1 0)
    (() 0 0)
    |}];
  List.iter
    Navigation.Motion.[ Down; Half_down; Last; Up; Half_up; First ]
    ~f:(fun motion ->
      printf "%d " (Navigation.move_offset 3 ~total:10 ~rows:4 motion));
  printf "| %d\n" (Navigation.move_offset 0 ~total:2 ~rows:4 Last);
  [%expect {| 4 5 6 2 1 0 | 0 |}]
;;
