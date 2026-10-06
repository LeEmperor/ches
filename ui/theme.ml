open! Core
open Bonsai_term

module Preset = struct
  type t =
    | Midnight
    | Crimson
    | Ember
    | Glacier
  [@@deriving sexp_of, equal, enumerate]
end

(* The theme ches draws with. Change it here to switch presets. *)
let selected : Preset.t = Crimson

module Role = struct
  type t =
    | Backdrop
    | Background
    | Foreground
    | Surface
    | Muted
    | Border
    | Current_line
    | Normal_accent
    | Insert_accent
    | Special
    | Warning
    | Error
    | Block_cursor
    | Block_copy
    | Smear
    | Syntax_keyword
    | Syntax_string
    | Syntax_number
    | Syntax_comment
    | Syntax_type
    | Syntax_function
    | Syntax_module
    | Syntax_constant
  [@@deriving sexp_of, enumerate]

  (* Neutral near-black gray, cool accents, multi-hue syntax. *)
  let midnight = function
    | Backdrop -> 0x0b, 0x0b, 0x0c
    | Background -> 0x11, 0x11, 0x13
    | Foreground -> 0xd0, 0xd0, 0xd0
    | Surface -> 0x1c, 0x1c, 0x1f
    | Muted -> 0x5a, 0x5a, 0x60
    | Border -> 0x3a, 0x3a, 0x40
    | Current_line -> 0x1d, 0x1d, 0x21
    | Normal_accent -> 0x7a, 0xa2, 0xf7
    | Insert_accent -> 0x9e, 0xce, 0x6a
    | Special -> 0xbb, 0x9a, 0xf7
    | Warning -> 0xe0, 0xaf, 0x68
    | Error -> 0xf7, 0x76, 0x8e
    | Block_cursor -> 0x7a, 0xa2, 0xf7
    | Block_copy -> 0xd0, 0xd0, 0xd0
    | Smear -> 0xf5, 0xf5, 0xf5
    | Syntax_keyword -> 0xbb, 0x9a, 0xf7
    | Syntax_string -> 0x9e, 0xce, 0x6a
    | Syntax_number -> 0xff, 0x9e, 0x64
    | Syntax_comment -> 0x7a, 0x89, 0x94
    | Syntax_type -> 0x7d, 0xcf, 0xff
    | Syntax_function -> 0x7a, 0xa2, 0xf7
    | Syntax_module -> 0x73, 0xda, 0xca
    | Syntax_constant -> 0xe0, 0xaf, 0x68
  ;;

  (* A faintly warm ground with syntax spread across reds: crimson, rose, coral, and
     salmon, warming to amber and gold for literals. Insert stays green and specials
     lavender so they never blend into the code. *)
  let crimson = function
    | Backdrop -> 0x0c, 0x0a, 0x0a
    | Background -> 0x13, 0x10, 0x10
    | Foreground -> 0xe0, 0xd2, 0xd2
    | Surface -> 0x20, 0x1a, 0x1b
    | Muted -> 0x66, 0x55, 0x58
    | Border -> 0x44, 0x36, 0x39
    | Current_line -> 0x21, 0x1a, 0x1b
    | Normal_accent -> 0xe8, 0x5d, 0x75
    | Insert_accent -> 0x9e, 0xce, 0x6a
    | Special -> 0xc9, 0xa0, 0xff
    | Warning -> 0xff, 0xb8, 0x6c
    | Error -> 0xff, 0x33, 0x55
    | Block_cursor -> 0xe8, 0x5d, 0x75
    | Block_copy -> 0xe0, 0xd2, 0xd2
    | Smear -> 0xd1, 0x1f, 0x3c
    | Syntax_keyword -> 0xff, 0x4f, 0x5e
    | Syntax_string -> 0xf2, 0xa0, 0x7b
    | Syntax_number -> 0xff, 0x9e, 0x64
    | Syntax_comment -> 0x8c, 0x6f, 0x75
    | Syntax_type -> 0xf7, 0x6e, 0x9e
    | Syntax_function -> 0xff, 0x7b, 0x54
    | Syntax_module -> 0xd9, 0x8a, 0xa0
    | Syntax_constant -> 0xff, 0xcb, 0x6b
  ;;

  (* Warm brown-gray ground with earthy, gruvbox-like syntax. *)
  let ember = function
    | Backdrop -> 0x14, 0x14, 0x12
    | Background -> 0x1d, 0x20, 0x21
    | Foreground -> 0xeb, 0xdb, 0xb2
    | Surface -> 0x28, 0x28, 0x28
    | Muted -> 0x66, 0x5c, 0x54
    | Border -> 0x50, 0x49, 0x45
    | Current_line -> 0x28, 0x28, 0x28
    | Normal_accent -> 0x83, 0xa5, 0x98
    | Insert_accent -> 0xb8, 0xbb, 0x26
    | Special -> 0xd3, 0x86, 0x9b
    | Warning -> 0xfa, 0xbd, 0x2f
    | Error -> 0xfb, 0x49, 0x34
    | Block_cursor -> 0x83, 0xa5, 0x98
    | Block_copy -> 0xeb, 0xdb, 0xb2
    | Smear -> 0xfa, 0xbd, 0x2f
    | Syntax_keyword -> 0xfb, 0x49, 0x34
    | Syntax_string -> 0xb8, 0xbb, 0x26
    | Syntax_number -> 0xd3, 0x86, 0x9b
    | Syntax_comment -> 0x92, 0x83, 0x74
    | Syntax_type -> 0xfa, 0xbd, 0x2f
    | Syntax_function -> 0x8e, 0xc0, 0x7c
    | Syntax_module -> 0x83, 0xa5, 0x98
    | Syntax_constant -> 0xfe, 0x80, 0x19
  ;;

  (* Blue-black ground with icy blues, teals, and pale violet. *)
  let glacier = function
    | Backdrop -> 0x09, 0x0c, 0x10
    | Background -> 0x0f, 0x14, 0x19
    | Foreground -> 0xc8, 0xd3, 0xe0
    | Surface -> 0x17, 0x1e, 0x26
    | Muted -> 0x4e, 0x5a, 0x68
    | Border -> 0x2e, 0x3a, 0x48
    | Current_line -> 0x17, 0x1e, 0x26
    | Normal_accent -> 0x5c, 0xc8, 0xff
    | Insert_accent -> 0x7f, 0xe0, 0xc0
    | Special -> 0xf0, 0x8f, 0xc0
    | Warning -> 0xe6, 0xc3, 0x84
    | Error -> 0xff, 0x6b, 0x7f
    | Block_cursor -> 0x5c, 0xc8, 0xff
    | Block_copy -> 0xc8, 0xd3, 0xe0
    | Smear -> 0xbf, 0xe8, 0xff
    | Syntax_keyword -> 0x82, 0xaa, 0xff
    | Syntax_string -> 0xa3, 0xe4, 0xd7
    | Syntax_number -> 0xc3, 0xa6, 0xff
    | Syntax_comment -> 0x63, 0x77, 0x8a
    | Syntax_type -> 0x89, 0xdd, 0xff
    | Syntax_function -> 0x5c, 0xc8, 0xff
    | Syntax_module -> 0x6b, 0xd8, 0xc8
    | Syntax_constant -> 0xb4, 0xc6, 0xff
  ;;

  let color ?(preset = selected) t =
    let r, g, b =
      (match (preset : Preset.t) with
       | Midnight -> midnight
       | Crimson -> crimson
       | Ember -> ember
       | Glacier -> glacier)
        t
    in
    Attr.Color.rgb ~r ~g ~b
  ;;
end

module Font = struct
  type t =
    | Bold
    | Italic
    | Underline
  [@@deriving sexp_of, equal, enumerate]

  let attr = function
    | Bold -> Attr.bold
    | Italic -> Attr.italic
    | Underline -> Attr.underline
  ;;

  let default : Ches_screen.Style.t -> t list = function
    | Title | Mode _ | Dirty | Pending | Error -> [ Bold ]
    | Backdrop
    | Document _
    | Gutter
    | Gutter_cursor_line
    | Border
    | Border_focused
    | Title_special
    | Status
    | Status_special
    | Hint
    | Info
    | Warning
    | Smear -> []
  ;;
end

let syntax_role : Ches_screen.Style.Syntax.t -> Role.t = function
  | Plain | Variable | Operator | Punctuation -> Foreground
  | Keyword -> Syntax_keyword
  | String -> Syntax_string
  | Number -> Syntax_number
  | Comment -> Syntax_comment
  | Type | Property -> Syntax_type
  | Function -> Syntax_function
  | Module -> Syntax_module
  | Constructor | Constant | Escape -> Syntax_constant
;;

let colors (style : Ches_screen.Style.t) =
  let colors fg bg = [ Attr.fg (Role.color fg); Attr.bg (Role.color bg) ] in
  match style with
  | Backdrop -> colors Foreground Backdrop
  | Document { syntax; current_line; special; overlay } ->
    (match overlay with
     | Some Search_match -> colors Background Normal_accent
     | Some Search_current -> colors Background Insert_accent
     | Some Selection -> colors Background Warning
     | Some Insert_cursor -> colors Background Block_cursor
     | Some Insert_point -> colors Background Block_copy
     | None ->
       colors
         (if special then Special else syntax_role syntax)
         (if current_line then Current_line else Background))
  | Gutter -> colors Muted Background
  | Gutter_cursor_line -> colors Foreground Current_line
  (* Frame cells (borders and the labels set into them) sit on the backdrop, so rounded
     corners read as round and the borders alone separate tiles across a gap. *)
  | Border -> colors Border Backdrop
  | Border_focused -> colors Normal_accent Backdrop
  | Title -> colors Foreground Backdrop
  | Title_special -> colors Special Backdrop
  | Status -> colors Foreground Surface
  | Status_special -> colors Special Surface
  | Hint -> colors Muted Backdrop
  | Mode Normal -> colors Background Normal_accent
  | Mode Insert -> colors Background Insert_accent
  | Mode (Visual _) -> colors Background Warning
  | Dirty -> colors Warning Surface
  | Pending -> colors Normal_accent Surface
  | Info -> colors Foreground Surface
  | Warning -> colors Warning Surface
  | Error -> colors Error Surface
  | Smear -> [ Attr.fg (Role.color Smear) ]
;;

let attrs ?(font = Font.default) style = colors style @ List.map (font style) ~f:Font.attr
