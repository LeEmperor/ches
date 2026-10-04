open! Core
open Bonsai_term

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
    | Syntax_keyword
    | Syntax_string
    | Syntax_number
    | Syntax_comment
    | Syntax_type
    | Syntax_function
    | Syntax_module
    | Syntax_constant
  [@@deriving sexp_of, enumerate]

  let color t =
    let r, g, b =
      match t with
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
      | Syntax_keyword -> 0xbb, 0x9a, 0xf7
      | Syntax_string -> 0x9e, 0xce, 0x6a
      | Syntax_number -> 0xff, 0x9e, 0x64
      | Syntax_comment -> 0x7a, 0x89, 0x94
      | Syntax_type -> 0x7d, 0xcf, 0xff
      | Syntax_function -> 0x7a, 0xa2, 0xf7
      | Syntax_module -> 0x73, 0xda, 0xca
      | Syntax_constant -> 0xe0, 0xaf, 0x68
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
    | Title_special
    | Status
    | Status_special
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
  | Border -> colors Border Background
  | Title -> colors Foreground Background
  | Title_special -> colors Special Background
  | Status -> colors Foreground Surface
  | Status_special -> colors Special Surface
  | Mode Normal -> colors Background Normal_accent
  | Mode Insert -> colors Background Insert_accent
  | Mode (Visual _) -> colors Background Warning
  | Dirty -> colors Warning Surface
  | Pending -> colors Normal_accent Surface
  | Info -> colors Foreground Surface
  | Warning -> colors Warning Surface
  | Error -> colors Error Surface
  (* Notty cannot query the terminal's native cursor colour.  Ches leaves that cursor
     at the terminal default (normally white), so use an explicit near-white here
     rather than the Normal-mode blue accent while the replacement cursor is moving. *)
  | Smear -> [ Attr.fg (Attr.Color.rgb ~r:0xf5 ~g:0xf5 ~b:0xf5) ]
;;

let attrs ?(font = Font.default) style = colors style @ List.map (font style) ~f:Font.attr
