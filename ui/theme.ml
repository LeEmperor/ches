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

let colors (style : Ches_screen.Style.t) =
  let colors fg bg = [ Attr.fg (Role.color fg); Attr.bg (Role.color bg) ] in
  match style with
  | Backdrop -> colors Foreground Backdrop
  | Document { syntax = Plain; current_line; special; overlay } ->
    (match overlay with
     | Some Search_match -> colors Background Normal_accent
     | Some Search_current -> colors Background Insert_accent
     | Some Selection -> colors Background Warning
     | Some Insert_cursor -> colors Background Block_cursor
     | Some Insert_point -> colors Background Block_copy
     | None ->
       colors
         (if special then Special else Foreground)
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
  (* Notty cannot query the terminal's native cursor colour.  Ches leaves that cursor
     at the terminal default (normally white), so use an explicit near-white here
     rather than the Normal-mode blue accent while the replacement cursor is moving. *)
  | Smear -> [ Attr.fg (Attr.Color.rgb ~r:0xf5 ~g:0xf5 ~b:0xf5) ]
;;

let attrs ?(font = Font.default) style = colors style @ List.map (font style) ~f:Font.attr
