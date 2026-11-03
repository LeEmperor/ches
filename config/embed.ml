let () =
  let channel = open_in_bin Sys.argv.(1) in
  let source = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Printf.printf "let source = %S\n" source
