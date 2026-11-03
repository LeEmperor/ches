open! Core
module Stamp = Ches_app.Navigation_file_stamp

let%test_unit "navigation stamps follow regular symlinks without opening special files" =
  let root = Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "ches-navigation-stamp-") in
  let path = root ^ "/file" and link = root ^ "/link" and fifo = root ^ "/fifo" in
  Exn.protect ~f:(fun () ->
    Out_channel.write_all path ~data:"source";
    Core_unix.symlink ~target:path ~link_name:link;
    Core_unix.mkfifo fifo ~perm:0o600;
    let stamp = Stamp.read path |> Option.value_exn in
    assert (Option.equal Stamp.equal (Some stamp) (Stamp.read link));
    assert (String.equal (Stamp.to_string stamp)
      (Stamp.to_string (Stamp.read link |> Option.value_exn)));
    List.iter [fifo; root; "/dev/null"; root ^ "/missing"] ~f:(fun path ->
      assert (Option.is_none (Stamp.read path)));
    Core_unix.unlink path;
    assert (Option.is_none (Stamp.read link)))
    ~finally:(fun () ->
      List.iter [link; fifo; path] ~f:(fun p ->
        try Core_unix.unlink p with Core_unix.Unix_error (ENOENT, _, _) -> ());
      Core_unix.rmdir root)
;;
