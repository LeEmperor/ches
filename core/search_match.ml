open! Core

let small_word_class text offset =
  if offset < 0 || offset >= Text_buffer.length text then None
  else
    let code = Uchar.to_scalar (Text_buffer.uchar_at text offset) in
    if code = 0x20 || code = 0x09 || code = 0x0A then None
    else if code >= 0x80 || Char.is_alphanum (Char.of_int_exn code) || code = Char.to_int '_'
    then Some `Identifier else Some `Punctuation
;;

let matches text ~query ~whole_word ~case_sensitive ~at =
  let source = Text_buffer.to_string text in
  let lower c =
    if Char.(c >= 'A' && c <= 'Z') then Char.of_int_exn (Char.to_int c + 32) else c
  in
  not (String.is_empty query)
  && at + String.length query <= String.length source
  && String.for_alli query ~f:(fun i c ->
    if case_sensitive then Char.equal source.[at + i] c
    else Char.equal (lower source.[at + i]) (lower c))
  && (not whole_word
      || let class_ = small_word_class text at in
         let before = Option.bind (Text_buffer.prev_boundary text at) ~f:(small_word_class text) in
         let after = small_word_class text (at + String.length query) in
         not ([%equal: [ `Identifier | `Punctuation ] option] class_ before)
         && not ([%equal: [ `Identifier | `Punctuation ] option] class_ after))
;;
