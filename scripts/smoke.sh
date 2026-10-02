#!/usr/bin/env bash
# Terminal smoke test: drives the built `ches` binary inside tmux and checks what
# reaches the screen, the cursor, the files written, and the terminal state left for
# the shell. See mvp0_plan.md, "Terminal smoke script".
#
# Usage: scripts/smoke.sh [PATH-TO-CHES]   (default: _build/default/bin/ches.exe)
#
# Needs tmux (tested with 3.4) and a UTF-8 locale. Run `dune build` first. It uses a
# private tmux server (-L ches-smoke) and a temporary directory, both removed on exit,
# and leaves colored captures of review screens in a directory it prints.
#
# Not checkable here: cursor shape (tmux does not report it), how the palette looks,
# and flicker. Check those in a real terminal.

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
ches=${1:-$root/_build/default/bin/ches.exe}
ches=$(cd "$(dirname "$ches")" && pwd)/$(basename "$ches")

if ! command -v tmux >/dev/null; then
  echo "smoke: tmux is required" >&2
  exit 2
fi
if [ ! -x "$ches" ]; then
  echo "smoke: $ches is not built; run dune build" >&2
  exit 2
fi
export LC_ALL=C.UTF-8

work=$(mktemp -d "${TMPDIR:-/tmp}/ches-smoke.XXXXXX")
screens=$(mktemp -d "${TMPDIR:-/tmp}/ches-smoke-screens.XXXXXX")
tmux_cmd=(tmux -L ches-smoke -f /dev/null)
session=smoke

cleanup() {
  "${tmux_cmd[@]}" kill-server 2>/dev/null
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

failures=0
current=""

t() { "${tmux_cmd[@]}" "$@"; }
screen() { t capture-pane -p -t "$session"; }
status_line() { screen | sed -n "$(t display -p -t "$session" '#{pane_height}')p"; }
cursor() { t display -p -t "$session" '#{cursor_x} #{cursor_y} #{cursor_flag}'; }
alternate() { t display -p -t "$session" '#{alternate_on}'; }
row() { screen | sed -n "$(($1 + 1))p"; }

section() {
  current=$1
  echo "== $1"
}

fail() {
  failures=$((failures + 1))
  echo "FAIL [$current]: $*"
  echo "---- screen ----"
  screen | sed 's/^/  | /'
  echo "---- cursor: $(cursor), alternate: $(alternate)"
}

ok() { echo "ok   [$current]: $*"; }

# Polls until COMMAND succeeds, for up to 5 seconds.
poll() {
  local deadline=$((SECONDS + 5))
  until "$@"; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.05
  done
}

screen_has() { screen | grep -qF -- "$1"; }
status_has() { status_line | grep -qF -- "$1"; }
alternate_is() { [ "$(alternate)" = "$1" ]; }

expect_screen() {
  if poll screen_has "$1"; then ok "screen shows '$1'"; else fail "screen never showed '$1'"; fi
}

expect_no_screen() {
  if screen_has "$1"; then fail "screen shows '$1'"; else ok "screen does not show '$1'"; fi
}

expect_status() {
  if poll status_has "$1"; then
    ok "status line shows '$1'"
  else
    fail "status line never showed '$1'"
  fi
}

expect_cursor() {
  local actual
  actual=$(cursor)
  if [ "$actual" = "$1" ]; then
    ok "cursor at $1"
  else
    fail "cursor is '$actual', expected '$1'"
  fi
}

expect_file() {
  if cmp -s "$1" "$2"; then
    ok "$(basename "$1") has the expected bytes"
  else
    fail "$(basename "$1") differs from the expected bytes"
    cmp "$1" "$2"
  fi
}

# Runs a command in the pane's shell and waits for it to finish.
shell_count=0
shell() {
  shell_count=$((shell_count + 1))
  local marker="done-$shell_count"
  # printf, so that the echoed command line does not itself contain the marker and
  # the poll waits for the command to run, not just for it to be typed.
  t send-keys -t "$session" -l "$1; printf 'done-%s\\n' $shell_count"
  t send-keys -t "$session" Enter
  poll screen_has "$marker" || fail "shell command did not finish: $1"
}

launch() {
  shell "clear; stty -g > $work/stty.before"
  t send-keys -t "$session" -l "$ches $*"
  t send-keys -t "$session" Enter
  if poll alternate_is 1 && poll status_has "NORMAL"; then
    ok "launched ches $*"
  else
    fail "ches $* did not start"
  fi
}

keys() { t send-keys -t "$session" "$@"; }
type_text() { t send-keys -t "$session" -l "$1"; }

# After ches exits: the expected exit status, and the terminal as the shell left it.
expect_exit() {
  local expected_status=$1
  if ! poll alternate_is 0; then
    fail "ches did not leave the alternate screen"
    return
  fi
  shell "echo status=\$?:"
  if screen_has "status=$expected_status:"; then
    ok "exit status $expected_status"
  else
    fail "exit status was not $expected_status"
  fi
  shell "stty -g > $work/stty.after"
  if cmp -s "$work/stty.before" "$work/stty.after"; then
    ok "terminal modes restored"
  else
    fail "terminal modes differ after exit"
  fi
  if [ "$(cursor | cut -d' ' -f3)" = 1 ]; then ok "cursor visible"; else fail "cursor hidden"; fi
}

resize() { t resize-window -t "$session" -x "$1" -y "$2"; }

save_screen() {
  t capture-pane -e -p -t "$session" > "$screens/$1.ansi"
}

# The character in the cell under the cursor (cells are characters on ASCII rows).
char_under_cursor() {
  local x y
  read -r x y _ <<< "$(cursor)"
  local line
  line=$(row "$y")
  echo "${line:$x:1}"
}

t new-session -d -s "$session" -x 80 -y 24 \
  "env -i HOME=$HOME PATH=$PATH LC_ALL=C.UTF-8 TERM=tmux-256color PS1='$ ' bash --norc --noprofile"
t set -g window-size manual
t set -g default-terminal tmux-256color
shell "cd $work"

# ---------------------------------------------------------------------------
section "edit, save, quit, reopen"
printf 'hello\nworld\n' > "$work/edit.txt"
printf 'Hi hello\nwold\n' > "$work/edit.expected"
launch edit.txt
expect_cursor "5 1 1"
keys i
type_text "Hi "
keys Escape
poll status_has "NORMAL" || fail "Escape did not return to Normal"
keys j x
expect_status "[+]"
expect_screen "wold"
keys Space w
expect_status "Wrote edit.txt"
poll status_has "[+]" && fail "still dirty after saving" || ok "clean after saving"
expect_file "$work/edit.txt" "$work/edit.expected"
keys Space q
expect_exit 0
launch edit.txt
expect_screen "  1 Hi hello"
expect_screen "  2 wold"

section "undo and redo"
keys x
expect_screen "  1 i hello"
keys u
expect_screen "  1 Hi hello"
keys C-r
expect_screen "  1 i hello"
keys u
expect_screen "  1 Hi hello"
# Undone back to the saved text: clean, so a plain quit works.
keys Space q
expect_exit 0
expect_file "$work/edit.txt" "$work/edit.expected"

# ---------------------------------------------------------------------------
section "Insert-mode editing keys, j k, and an unbound leader key"
printf 'abcd\n' > "$work/ins.txt"
printf 'a\n  cd\n' > "$work/ins.expected"
launch ins.txt
keys l l
expect_status "1:3"
keys h
expect_status "1:2"
expect_cursor "6 1 1"
keys i Enter
expect_status "2:1"
expect_screen "  1 a "
expect_screen "  2 bcd"
# Soft tabs: Tab inserts spaces to the next multiple of 2 columns, and Backspace
# deletes spaces back to the previous one.
keys Tab Tab
expect_status "2:5"
expect_screen "  2     bcd"
keys BSpace
expect_status "2:3"
expect_screen "  2   bcd"
# Backspace after anything but a space deletes one character.
type_text "x"
expect_status "2:4"
keys BSpace
expect_status "2:3"
expect_screen "  2   bcd"
keys DC
expect_screen "  2   cd"
# j is inserted when typed; the k after it takes it back and returns to Normal,
# stepping back one character as Escape does.
type_text "j"
expect_screen "  2   jcd"
type_text "k"
expect_status "NORMAL"
expect_status "2:2"
expect_screen "  2   cd"
expect_no_screen "jcd"
keys k
expect_status "1:1"
keys Space z
expect_status "Space z is not bound"
expect_screen "  2   cd"
keys Space w
expect_status "Wrote ins.txt"
expect_file "$work/ins.txt" "$work/ins.expected"
# The whole Insert session is one undo step.
keys u
expect_screen "  1 abcd"
expect_status "[+]"
keys Space Q
expect_exit 0
expect_file "$work/ins.txt" "$work/ins.expected"

# ---------------------------------------------------------------------------
section "empty and missing files"
: > "$work/empty.txt"
launch empty.txt
expect_screen "  1  "
expect_status "1:1"
expect_cursor "5 1 1"
keys Space q
expect_exit 0
launch new.txt
expect_status "new.txt"
keys Space w
expect_status "Wrote new.txt"
keys Space q
expect_exit 0
expect_file "$work/new.txt" "$work/empty.txt"

# ---------------------------------------------------------------------------
section "pending leader, Ctrl-c, dirty quit refusal, forced quit"
launch edit.txt
keys Space
expect_status "Space"
keys Escape
poll status_has "Space" && fail "Escape did not cancel the leader" || ok "Escape cancels the leader"
keys C-c
expect_status "To quit, use Space q in Normal mode"
keys i C-c
expect_status "INSERT"
expect_status "To quit, use Space q"
keys Escape x Space q
expect_status "Unsaved changes: save them or force quit"
[ "$(alternate)" = 1 ] && ok "still running after refusal" || fail "exited despite refusal"
keys Space Q
expect_exit 0
expect_file "$work/edit.txt" "$work/edit.expected"

# ---------------------------------------------------------------------------
section "save error"
if [ "$(id -u)" = 0 ]; then
  echo "skip [$current]: running as root, permissions are not enforced"
else
  mkdir "$work/ro"
  chmod 555 "$work/ro"
  launch ro/new.txt
  keys i
  type_text "abc"
  keys Escape Space w
  expect_status "Failed to write ro/new.txt: Permission denied"
  expect_status "[+]"
  keys Space Q
  expect_exit 0
  [ -e "$work/ro/new.txt" ] && fail "the file was created" || ok "no file created"
fi

# ---------------------------------------------------------------------------
section "tabs, Unicode, and control characters"
printf 'a\tb\n中文x\n\033[31mred\033[0m \001\177 \302\205 \342\200\256rtl\n' > "$work/controls.txt"
launch controls.txt
expect_screen "  1 a       b"
expect_screen "  2 中文x"
expect_screen '  3 ^[[31mred^[[0m ^A^? <85> <202e>rtl'
if t capture-pane -e -p -t "$session" | grep -qF $'\033[31m'; then
  fail "a raw color sequence reached the terminal"
else
  ok "no raw escape sequence reached the terminal"
fi
line=$(row 3)
if [ "${#line}" = 80 ] && [ "${line: -1}" = "│" ]; then
  ok "control-character row keeps the border aligned"
else
  fail "control-character row is misaligned: '${line}'"
fi
line=$(row 2)
if [ "${#line}" = 78 ] && [ "${line: -1}" = "│" ]; then
  ok "wide-character row keeps the border aligned"
else
  fail "wide-character row is misaligned"
fi
keys l
expect_status "1:2"
expect_cursor "6 1 1"
keys l
expect_status "1:3"
expect_cursor "13 1 1"
keys j
expect_status "2:3"
expect_cursor "9 2 1"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "scrolling a tall file"
for i in $(seq 1 200); do echo "line $i"; done > "$work/tall.txt"
launch tall.txt
keys -N 150 j
expect_status "151:1"
read -r _ y _ <<< "$(cursor)"
row "$y" | grep -qF "151 line 151" && ok "cursor row shows line 151" || fail "cursor row is not line 151"
keys -N 150 k
expect_status "1:1"
expect_cursor "5 1 1"
expect_screen "  1 line 1"

section "resizing, including tiny sizes"
keys -N 100 j
expect_status "101:1"
resize 1 1
poll alternate_is 1 || fail "exited at 1x1"
sleep 0.3
[ "$(cursor | cut -d' ' -f3)" = 0 ] && ok "no cursor at 1x1" || fail "cursor shown at 1x1"
resize 10 3
expect_screen "line 101"
read -r x y flag <<< "$(cursor)"
[ "$flag" = 1 ] && [ "$y" -lt 2 ] && ok "cursor in the text at 10x3" || fail "cursor not in the text at 10x3"
resize 160 48
expect_status "101:1"
row 0 | grep -qE '^ {27}╭─' && ok "tile centered at 160x48" || fail "tile not centered at 160x48"
read -r x y flag <<< "$(cursor)"
[ "$flag" = 1 ] && [ "$x" = 32 ] && [ "$y" -ge 1 ] && [ "$y" -le 45 ] \
  && ok "cursor in the text at 160x48" || fail "cursor not in the text at 160x48: $x $y $flag"
resize 80 24
expect_status "101:1"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "layout commands (Space v)"
# Where the tile's top corners are, in cells from the left.
tile_left() { local line prefix; line=$(row 0); prefix=${line%%╭*}; echo "${#prefix}"; }
tile_right() { local line prefix; line=$(row 0); prefix=${line%%╮*}; echo "${#prefix}"; }
tile_is() { [ "$(tile_left) $(tile_right)" = "$1 $2" ]; }
# Waits for FEEDBACK in the status line, then checks the tile's corners and that the
# cursor is visible on the first text cell of line 1.
expect_layout() {
  local feedback=$1 left=$2 right=$3
  expect_status "$feedback"
  if poll tile_is "$left" "$right"; then
    ok "tile spans $left..$right"
  else
    fail "tile spans $(tile_left)..$(tile_right), expected $left..$right"
  fi
  expect_cursor "$((left + 5)) 1 1"
}
resize 160 48
launch edit.txt
expect_layout "1:1" 27 132
keys Space v
expect_status "Space v"
keys L
expect_layout "Offset +10" 37 142
keys Space v h
expect_layout "Offset +8" 35 140
keys Space v H
expect_layout "Offset -2" 25 130
keys Space v l
expect_layout "Offset 0" 27 132
keys Space v -
expect_layout "Width 90" 32 127
keys Space v =
expect_layout "Width 100" 27 132
keys Space v +
expect_layout "Width 110" 22 137
keys Space v c
expect_layout "Full width" 0 159
keys Space v c
expect_layout "Centered" 22 137
for _ in 1 2 3 4 5 6; do keys Space v L; done
expect_layout "Offset +60 (+22 fit)" 44 159
# A screen too small for the request clamps the tile; a larger one restores it.
resize 100 30
if poll tile_is 0 99; then ok "tile clamped to 100 columns"; else fail "tile not clamped at 100x30"; fi
expect_cursor "5 1 1"
resize 10 3
cursor_is() { [ "$(cursor)" = "$1" ]; }
poll cursor_is "0 0 1" && ok "cursor visible on the text at 10x3" \
  || fail "cursor not on the text at 10x3: $(cursor)"
resize 160 48
if poll tile_is 44 159; then ok "requested placement restored at 160x48"; else fail "placement not restored"; fi
expect_cursor "49 1 1"
# Full width ignores the offset; Space v l from full width centers again.
keys Space v c
expect_layout "Full width" 0 159
keys Space v l
expect_layout "Offset +62 (+22 fit)" 44 159
keys Space v r
expect_layout "Layout reset" 27 132
for _ in 1 2 3 4 5 6 7 8 9 10; do keys Space v -; done
expect_layout "Width 20" 67 92
for _ in $(seq 1 50); do keys Space v +; done
expect_layout "Width 500 (154 fit)" 0 159
keys Space v r
expect_layout "Layout reset" 27 132
keys Space v z
expect_status "Space v z is not bound"
# After Escape, l moves the cursor instead of nudging the tile.
keys Space v Escape l
expect_status "1:2"
poll tile_is 27 132 && ok "Escape cancels Space v" || fail "Escape did not cancel Space v"
keys h
expect_status "1:1"
# None of this touched the document: no dirty marker, nothing to undo, a plain quit.
status_has "[+]" && fail "layout commands made the document dirty" || ok "document still clean"
keys u
expect_status "Already at oldest change"
# In Insert mode the same keys are text.
keys i Space v c Escape
expect_screen "  1  vcHi hello"
expect_status "1:3"
poll tile_is 27 132 && ok "tile unmoved by Insert-mode text" || fail "tile moved"
expect_cursor "34 1 1"
keys u
expect_screen "  1 Hi hello"
keys Space q
expect_exit 0
expect_file "$work/edit.txt" "$work/edit.expected"
resize 80 24

# ---------------------------------------------------------------------------
section "scrolling a wide line"
{ for _ in $(seq 1 40); do printf '0123456789'; done; printf '\nshort\n'; } > "$work/wide.txt"
launch wide.txt
keys -N 250 l
expect_status "1:251"
read -r x _ _ <<< "$(cursor)"
[ "$x" -ge 5 ] && [ "$x" -le 78 ] && ok "cursor inside the text" || fail "cursor outside the text: $x"
[ "$(char_under_cursor)" = 0 ] && ok "cursor on the 251st character" || fail "wrong character under the cursor"
keys j
expect_status "2:5"
expect_cursor "9 2 1"
expect_screen "  1 0123456789"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "a fast burst of keys and pastes while the screen is busy"
for i in $(seq 1 3000); do
  printf 'busy line %d %s\n' "$i" "................................................................................................................................"
done > "$work/busy.txt"
burst1="the quick brown fox jumps over the lazy dog, again and again: 0123456789 "
burst1="$burst1$burst1$burst1$burst1"
paste=$'pasted jk text\twith a tab, space q and Q\n'
burst2="and more typing after the paste xyz"
{ printf '%s%s%s' "$burst1" "$paste" "${burst2%z}"; cat "$work/busy.txt"; } > "$work/busy.expected"
printf '%s' "$paste" > "$work/paste.txt"
t load-buffer -b smoke "$work/paste.txt"
resize 160 48
launch busy.txt
# No waiting between these: they queue up while ches redraws.
keys i
type_text "$burst1"
t paste-buffer -p -b smoke -t "$session"
type_text "$burst2"
# Escape and x in one write arrive as Meta-x, which ches reads as Escape then x.
keys Escape x
keys Space w
expect_status "Wrote busy.txt"
expect_file "$work/busy.txt" "$work/busy.expected"
save_screen busy-160x48
section "paste in Normal mode is ignored"
t paste-buffer -p -b smoke -t "$session"
expect_status "Paste ignored in Normal mode"
keys Space q
expect_exit 0
expect_file "$work/busy.txt" "$work/busy.expected"
resize 80 24

# ---------------------------------------------------------------------------
section "error exits restore the terminal"
launch edit.txt
keys i
expect_status "INSERT"
pane_pid=$(t display -p -t "$session" '#{pane_pid}')
kill -TERM "$(pgrep -P "$pane_pid")"
expect_exit 1
launch edit.txt
keys i
expect_status "INSERT"
kill -HUP "$(pgrep -P "$pane_pid")"
expect_exit 1
shell "clear; stty -g > $work/stty.before"
mkdir -p "$work/adir"
t send-keys -t "$session" -l "$ches adir"
t send-keys -t "$session" Enter
expect_screen "ches: Cannot open adir: is a directory"
expect_exit 1
shell "clear; stty -g > $work/stty.before"
t send-keys -t "$session" -l "$ches edit.txt < /dev/null"
t send-keys -t "$session" Enter
expect_screen "ches: standard input is not a terminal"
expect_exit 1

# ---------------------------------------------------------------------------
section "review screens"
cat > "$work/sample.ml" <<'EOF'
(* A sample for reviewing the screen. *)
let rec fib n =
	if n < 2 then n else fib (n - 1) + fib (n - 2)

let () =
  List.iter [ 1; 2; 3; 10 ] ~f:(fun n -> printf "fib %d = %d\n" n (fib n))
EOF
for size in 80x24 160x48; do
  resize "${size%x*}" "${size#*x}"
  launch sample.ml
  keys j
  expect_status "2:1"
  save_screen "normal-$size"
  keys Space
  expect_status "Space"
  save_screen "pending-$size"
  keys Escape i
  type_text "  "
  expect_status "INSERT"
  save_screen "insert-dirty-$size"
  keys Escape Space v
  expect_status "Space v"
  save_screen "pending-view-$size"
  keys L
  expect_status "Offset +10"
  save_screen "offset-$size"
  keys Space Q
  expect_exit 0
done
if [ "$(id -u)" != 0 ]; then
  mkdir "$work/review-ro"
  cp "$work/sample.ml" "$work/review-ro/"
  chmod 444 "$work/review-ro/sample.ml"
  for size in 80x24 160x48; do
    resize "${size%x*}" "${size#*x}"
    launch review-ro/sample.ml
    keys x Space w
    expect_status "Permission denied"
    save_screen "error-$size"
    keys Space Q
    expect_exit 0
  done
fi
resize 80 24
launch sample.ml
keys j
expect_status "2:1"
for size in 40x10 20x6 10x3 1x1; do
  resize "${size%x*}" "${size#*x}"
  sleep 0.3
  poll alternate_is 1 || fail "exited at $size"
  save_screen "tiny-$size"
done
resize 80 24
expect_status "2:1"
keys Space q
expect_exit 0

echo
echo "review screens (view with: cat FILE): $screens"
if [ "$failures" -gt 0 ]; then
  echo "smoke: $failures check(s) FAILED"
  exit 1
fi
echo "smoke: all checks passed"
