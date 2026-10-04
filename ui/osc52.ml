open! Core

let set_clipboard text = sprintf "\027]52;c;%s\007" (Base64.encode_string text)
