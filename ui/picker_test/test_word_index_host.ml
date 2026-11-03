open! Core
open! Async
module Expect_test_config = Async.Expect_test_config
module Host = Ches_ui.Word_index_host
module S = Ches_screen.Ui_state
module M = Ches_completion.Model

let request () =
  let text = Ches_core.Text_buffer.of_string ("\n" ^ String.concat
      (List.init 100000 ~f:(fun _ -> "alpha alpine\n"))) |> Result.ok |> Option.value_exn in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~path:"/index-test" ~cell_width:Ches_screen.Cell_map.width text) in
  let ui = S.create ~tiles_visible:false controller in
  let ui, _ = S.apply_all ui ~width:80 ~height:24
      (List.map (String.to_list "ial") ~f:(fun c -> S.Input.Key (Ches_input.Key.char c))) in
  snd (S.take_word_index_request ui) |> Option.value_exn
;;

let%expect_test "cancelling an active build releases its snapshot at the next yield" =
  let host = Host.create () in
  let weak = Stdlib.Weak.create 1 in
  let () =
    let r = request () in
    Stdlib.Weak.set weak 0 (Some r.text);
    Host.follow host (Some r) in
  let%bind () = Scheduler.yield () in
  Host.follow host None;
  let%bind () = Scheduler.yield () in
  let%bind () = Scheduler.yield () in
  Stdlib.Gc.full_major ();
  assert (not (Stdlib.Weak.check weak 0));
  Host.stop host;
  [%expect {| |}];
  return ()
;;

let%expect_test "host yields before completion, coalesces typing, and cancellation wakes waiters" =
  let r = request () in
  let cancelled = Host.create () in
  Host.follow cancelled (Some r);
  let cancelled_reply = Host.next cancelled in
  let%bind () = Scheduler.yield () in
  Host.follow cancelled None;
  let%bind () = Scheduler.yield () in
  let%bind () = Scheduler.yield () in
  assert (not (Deferred.is_determined cancelled_reply));
  Host.stop cancelled;
  let%bind stopped = cancelled_reply in
  assert (Option.is_none stopped);
  let host = Host.create () in
  Host.follow host (Some r);
  let reply = Host.next host in
  let%bind () = Scheduler.yield () in
  assert (not (Deferred.is_determined reply));
  (* Replace the token every scheduler turn: the original base must still finish. *)
   let latest_token = ref r.request.token.request in
   let rec type_more n =
     if Deferred.is_determined reply then return () else (
       assert (n < 10000);
       let text = Ches_core.Text_buffer.replace r.text ~pos:(Ches_core.Text_buffer.length r.text)
           ~len:0 (sprintf "albatross%d" n) |> Result.ok |> Option.value_exn in
       latest_token := r.request.token.request + n;
      Host.follow host (Some { r with text; request = { r.request with
        token = { r.request.token with request = r.request.token.request + n } } });
       let%bind () = Scheduler.yield () in type_more (n + 1)) in
   let%bind () = type_more 1 in
  let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) reply in
  let original, _ = match result with `Result (Some result) -> result | _ -> failwith "index timed out" in
  assert (M.Token.equal original.request.token r.request.token);
  let%bind latest = Host.next host in
  let latest, words = Option.value_exn latest in
   assert (latest.request.token.request = !latest_token);
  assert (List.exists (M.Buffer_words.candidates words ~text:latest.text
       ~cursor:latest.request.cursor ~limit:100) ~f:(fun c ->
         String.equal c.label (sprintf "albatross%d" (!latest_token - r.request.token.request))));
  Host.follow host None;
  let waiting = Host.next host in
  Host.stop host;
  let%bind stopped = waiting in
  assert (Option.is_none stopped);
  print_endline "yield, base progress, cancellation passed";
  [%expect {| yield, base progress, cancellation passed |}];
  return ()
;;
