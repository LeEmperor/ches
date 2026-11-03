open! Core
module Vcd = Ches_harness.Vcd
let id = Ches_tile.View_id.of_string "harness-waveform"
let spec = Ches_tile.Spec.read_only id ~title:"Quick-Harness waveform"
type t =
  { wave : Vcd.t; run : Ches_harness.Protocol.run; path : string
  ; cursor : int; start : int; step : int; top : int }
[@@deriving sexp_of]

let create wave run path =
  { wave; run; path; cursor = 0; start = 0; step = Int.max 1 ((wave.Vcd.last + 59) / 60); top = 0 }
;;

let key t (key : Ches_input.Key.t) ~width ~rows =
  let columns = Int.max 1 (width - 38) in
  let clamp n = Int.clamp_exn n ~min:0 ~max:t.wave.last in
  let cursor, step, start, top = match key with
    | Escape -> t.cursor, t.step, t.start, t.top
    | Left -> clamp (t.cursor - t.step), t.step, t.start, t.top
    | Right -> clamp (t.cursor + t.step), t.step, t.start, t.top
    | Home -> 0, t.step, 0, t.top
    | End -> t.wave.last, t.step, t.start, t.top
    | Ctrl 'u' -> t.cursor, t.step, t.start, t.top - Int.max 1 (rows - 3)
    | Ctrl 'd' -> t.cursor, t.step, t.start, t.top + Int.max 1 (rows - 3)
    | Char c ->
      (match Uchar.to_scalar c with
       | 104 -> clamp (t.cursor - t.step), t.step, t.start, t.top (* h *)
       | 108 -> clamp (t.cursor + t.step), t.step, t.start, t.top (* l *)
       | 106 -> t.cursor, t.step, t.start, t.top + 1
       | 107 -> t.cursor, t.step, t.start, t.top - 1
       | 43 | 61 -> t.cursor, Int.max 1 (t.step / 2), t.cursor, t.top
       | 45 -> t.cursor, Int.min Vcd.max_tick (t.step * 2), t.cursor, t.top
       | 91 -> clamp (t.cursor - (columns * t.step)), t.step, clamp (t.start - (columns * t.step)), t.top
       | 93 -> clamp (t.cursor + (columns * t.step)), t.step, clamp (t.start + (columns * t.step)), t.top
       | 48 -> 0, Int.max 1 ((t.wave.last + columns - 1) / columns), 0, t.top
       | _ -> t.cursor, t.step, t.start, t.top)
    | _ -> t.cursor, t.step, t.start, t.top in
  let start = if cursor < start then cursor
    else if cursor >= start + columns * step then Int.max 0 (cursor - (columns - 1) * step)
    else start in
  { t with cursor; step; start; top = Int.clamp_exn top ~min:0 ~max:(Int.max 0 (Array.length t.wave.signals - Int.max 1 (rows - 3))) }
;;

let render t ~width ~rows : Tile_shell.Content.t =
  let short n text = if String.length text <= n then text
    else String.prefix text (Int.max 0 (n - 1)) ^ "~" in
  let columns = Int.max 0 (width - 38) in
  let end_time = Int.min t.wave.last (t.start + columns * t.step) in
  let lines =
    [ sprintf "cursor=%d (%s/tick)  window=%d..%d  %d ticks/col" t.cursor t.wave.timescale t.start end_time t.step
    ; sprintf "run %s [%s, exit %d]" t.run.run_id t.run.status t.run.exit_code
    ; t.path ]
    @ (Array.to_list t.wave.signals |> Fn.flip List.drop t.top |> Fn.flip List.take (Int.max 0 (rows - 3))
      |> List.map ~f:(fun signal ->
        let trace = String.init columns ~f:(fun column ->
          let at = t.start + column * t.step in
          if at > t.wave.last then ' '
          else if t.cursor >= at && t.cursor < at + t.step then '|'
          else if Vcd.index_at signal (Int.min t.wave.last (at + t.step - 1)) <> Vcd.index_at signal at then ':'
          else let value = Vcd.value_at signal at in
            if String.mem value 'x' then 'x' else if String.mem value 'z' then 'z'
            else if signal.width > 1 then '=' else if String.equal value "1" then '^' else '_') in
        sprintf "%-22s %-14s %s" (short 22 signal.name) (short 14 (Vcd.value_at signal t.cursor)) trace)) in
  { title = "Quick-Harness waveform"
  ; footer = Some (Tile_shell.Label.footer ~notice:None ~pending:None
      ~default:"h/l time j/k signals +/- zoom [] pan 0 fit q/Esc close | cursor : activity x/z literal ~ clipped")
  ; body = List.take lines (Int.max 0 rows) |> List.map ~f:(fun text ->
      Span.of_glyphs (Cell_map.glyphs text) ~left:0 ~cols:(Int.max 0 width) ~text:Status ~special:Status_special)
  }
;;
