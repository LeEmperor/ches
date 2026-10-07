open! Core
open Ches_core
module Lines = Ches_line_picker.Lines
let now () = Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic
let elapsed start = Int63.to_float (Int63.( - ) (now ()) start) /. 1e6
let () =
  List.iter [ 1000; 10000; 50000 ] ~f:(fun count ->
    let text = List.init count ~f:(fun i -> sprintf "let item_%05d = module_value_%05d (* cached model *)" i i)
      |> String.concat ~sep:"\n" |> Text_buffer.of_string |> Result.ok |> Option.value_exn in
    let controller = Ches_app.Controller.create (Editor.create ~cell_width:(fun _ -> 1) text) in
    let t = Lines.create controller in
    List.iter [ ""; "m"; "model"; "let value"; "zzzz" ] ~f:(fun query ->
      while not (String.is_empty (Lines.query t)) do Lines.update t Delete_word done;
      Lines.update t (Paste query);
      let start = now () in
      let longest = ref 0. in
      let turns = ref 0 in
      while Lines.busy t do
        let turn = now () in Lines.work t ~budget:128;
        longest := Float.max !longest (elapsed turn); incr turns
      done;
      assert (Lines.prepared_count t = count);
      printf "%d query=%S total=%.3fms longest=%.3fms turns=%d matches=%d prepared=%d\n%!"
        count query (elapsed start) !longest !turns
        (List.length (Lines.results t)) (Lines.prepared_count t));
    Ches_app.Controller.close controller)
