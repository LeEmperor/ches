#!/usr/bin/env bash
# Terminal smoke test: drives the built `ches` binary inside tmux and checks what
# reaches the screen, the cursor, the files written, and the terminal state left for
# the shell. See mvp0_plan.md, "Terminal smoke script".
#
# Usage: scripts/smoke.sh [PATH-TO-CHES]   (default: _build/default/bin/ches.exe)
#
# Needs tmux (tested with 3.4) and a UTF-8 locale. Run `dune build` first. It uses a
# private per-run tmux server (-L ches-smoke-PID) and a temporary directory, both removed on exit,
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
# A unique socket prevents another checkout's smoke run from sharing this session.
tmux_cmd=(tmux -L "ches-smoke-$$" -f /dev/null)
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

# Whether the row the cursor is on contains TEXT.
cursor_row_has() {
  local y visible
  read -r _ y visible <<< "$(cursor)"
  [ "$visible" = 1 ] && row "$y" | grep -qF -- "$1"
}
expect_cursor_row() {
  if poll cursor_row_has "$1"; then ok "cursor row shows '$1'"; else fail "cursor row never showed '$1'"; fi
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

cursor_is() { [ "$(cursor)" = "$1" ]; }

expect_cursor() {
  if poll cursor_is "$1"; then
    ok "cursor at $1"
  else
    fail "cursor is '$(cursor)', expected '$1'"
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

# Turns on hybrid line numbers from none, the default.
hybrid_numbers() {
  t send-keys -t "$session" Space v n Space v N
  poll status_has "Line numbers: hybrid" || fail "hybrid line numbers did not turn on"
}

# Starts ches with hybrid line numbers, which the checks here are written against.
launch() {
  shell "clear; stty -g > $work/stty.before"
  t send-keys -t "$session" -l "$ches $*"
  t send-keys -t "$session" Enter
  if poll alternate_is 1 && poll status_has "NORMAL"; then
    ok "launched ches $*"
    hybrid_numbers
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
  local x y visible
  read -r x y visible <<< "$(cursor)"
  [ "$visible" = 1 ] || return 1
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
expect_cursor "7 1 1"
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
expect_screen "1   Hi hello"
expect_screen "  1 wold"

section "undo and redo"
keys x
expect_screen "1   i hello"
keys u
expect_screen "1   Hi hello"
keys C-r
expect_screen "1   i hello"
keys u
expect_screen "1   Hi hello"
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
expect_cursor "8 1 1"
keys i Enter
expect_status "2:1"
expect_screen "  1 a "
expect_screen "2   bcd"
# Soft tabs: Tab inserts spaces to the next multiple of 2 columns, and Backspace
# deletes spaces back to the previous one.
keys Tab Tab
expect_status "2:5"
expect_screen "2       bcd"
keys BSpace
expect_status "2:3"
expect_screen "2     bcd"
# Backspace after anything but a space deletes one character.
type_text "x"
expect_status "2:4"
keys BSpace
expect_status "2:3"
expect_screen "2     bcd"
keys DC
expect_screen "2     cd"
# j is inserted when typed; the k after it takes it back and returns to Normal,
# stepping back one character as Escape does.
type_text "j"
expect_screen "2     jcd"
type_text "k"
expect_status "NORMAL"
expect_status "2:2"
expect_screen "2     cd"
expect_no_screen "jcd"
keys k
expect_status "1:1"
keys Space z
expect_status "Space z is not bound"
expect_screen "  1   cd"
keys Space w
expect_status "Wrote ins.txt"
expect_file "$work/ins.txt" "$work/ins.expected"
# The whole Insert session is one undo step.
keys u
expect_screen "1   abcd"
expect_status "[+]"
keys Space Q
expect_exit 0
expect_file "$work/ins.txt" "$work/ins.expected"

# ---------------------------------------------------------------------------
section "empty and missing files"
: > "$work/empty.txt"
launch empty.txt
expect_screen "1    "
expect_status "1:1"
expect_cursor "7 1 1"
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
expect_screen "1   a       b"
expect_screen "  1 中文x"
expect_screen '  2 ^[[31mred^[[0m ^A^? <85> <202e>rtl'
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
expect_cursor "8 1 1"
keys l
expect_status "1:3"
expect_cursor "15 1 1"
keys j
expect_status "2:3"
expect_cursor "11 2 1"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "scrolling a tall file"
for i in $(seq 1 200); do echo "line $i"; done > "$work/tall.txt"
launch tall.txt
keys -N 150 j
expect_status "151:1"
expect_cursor_row "151 line 151"
keys -N 150 k
expect_status "1:1"
expect_cursor "7 1 1"
expect_screen "1   line 1"

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
row 0 | grep -qE '^ {26}╭─' && ok "tile centered at 160x48" || fail "tile not centered at 160x48"
read -r x y flag <<< "$(cursor)"
[ "$flag" = 1 ] && [ "$x" = 33 ] && [ "$y" -ge 1 ] && [ "$y" -le 45 ] \
  && ok "cursor in the text at 160x48" || fail "cursor not in the text at 160x48: $x $y $flag"
resize 80 24
expect_status "101:1"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "counted movement"
launch tall.txt
# The pending count is shown until its command runs.
keys 2
expect_status "2"
keys 0
expect_status "20"
keys j
expect_status "21:1"
status_line | grep -qE ' 20 ' && fail "status line still shows the count" || ok "count cleared"
expect_cursor_row "21  line 21"
keys 5 l
expect_status "21:6"
keys 5 h
expect_status "21:1"
keys 2 0 k
expect_status "1:1"
# Counts clamp at the ends of the document and the line, scrolling as needed. The
# file ends with LF, so its last line is the empty line 201.
keys 9 9 9 j
expect_status "201:1"
expect_screen "  1 line 200"
keys k 9 9 9 9 9 9 l
expect_status "200:8"
# Line 1 is shorter, so the cursor stops at its last column.
keys 9 9 9 9 9 9 k
expect_status "1:6"
expect_screen "1   line 1"
# An oversized count, Escape, an unbound continuation, and a command that takes no
# count each cancel the count; none of it leaks into the next key.
keys 1 0 0 0 0 0 0
expect_status "Count is too large"
keys j
expect_status "2:6"
keys 1 2 Escape j
expect_status "3:6"
keys 3 q
expect_status "3 q is not bound"
keys j
expect_status "4:6"
keys 3 x
expect_status "[+]"
keys u j
expect_status "5:6"
expect_no_screen "[+]"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "delete operators"
printf 'one two\nthree\nfour\n' > "$work/operators.txt"
launch operators.txt
keys d w
expect_screen "1   two"
keys u
expect_screen "1   one two"
# A doubled operator is linewise and the count applies to lines.
keys 2 d d
expect_screen "1   four"
keys u
expect_screen "1   one two"
# A failed operator motion is feedback-only.
keys d %
expect_status "No delimiter on this line"
# The narrow command prompt force-reloads instead of saving the accidental edit.
keys i
type_text X
keys Escape
expect_screen "1   Xone two"
keys : e ! Enter
expect_status "Reloaded operators.txt"
expect_screen "1   one two"
keys Space q
expect_exit 0

# Counted vertical moves keep the column across shorter lines.
section "counted vertical movement"
printf 'abcdefgh\nab\nabcdefgh\n' > "$work/columns.txt"
launch columns.txt
keys 5 l 2 j
expect_status "3:6"
keys k
expect_status "2:2"
keys j
expect_status "3:6"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "word, line, and document motions"
{
  printf 'let foo_bar = baz(1, 2);\n'
  printf '  \tindented line\n'
  printf '\n'
  for i in $(seq 4 120); do printf 'line %s\n' "$i"; done
} > "$work/motions.txt"
launch motions.txt
keys w
expect_status "1:5"
keys w w
expect_status "1:15"
keys e
expect_status "1:17"
keys W
expect_status "1:22"
keys b B
expect_status "1:15"
keys 3 w
expect_status "1:20"
keys '$'
expect_status "1:24"
keys 0
expect_status "1:1"
keys j '^'
expect_status "2:4"
keys 2 '$'
expect_status "3:1"
keys w
expect_status "4:1"
# G alone is the last line (the empty one after the final LF); a count picks a line.
keys G
expect_status "121:1"
expect_screen "  1 line 120"
keys 5 0 G
expect_status "50:1"
expect_cursor_row "50  line 50"
keys g
expect_status "g"
keys Escape j
expect_status "51:1"
keys g g
expect_status "1:1"
expect_screen "1   let foo_bar"
keys 2 0 g g
expect_status "20:1"
keys 1 0 j 0
expect_status "30:1"
keys 3 '^'
expect_status "does not take a count"
# _ and g_ go to the first and last non-blank, a count picking a later line.
keys g g '$' 2 _
expect_status "2:4"
keys g _
expect_status "2:16"
keys g g 3 g _
expect_status "3:1"
expect_no_screen "[+]"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "matching delimiters (%)"
{
  echo 'let f x = ('
  for i in $(seq 1 148); do echo "  [ $i ];"; done
  echo ') (* end *)'
  echo 'no brackets here'
} > "$work/match.txt"
launch match.txt
# From before the delimiter, % goes to the mate of the first one on the line, far
# below, and the view scrolls to show it.
keys %
expect_status "150:1"
expect_cursor_row "│  150 ) (* end *)"
keys %
expect_status "1:11"
expect_cursor_row "1   let f x = ("
# Inside the block, from the line start: the first delimiter from the cursor is the [.
keys j 0 %
expect_status "2:7"
keys %
expect_status "2:3"
# No delimiter on the line, and a rejected count, leave the cursor where it is.
keys G k
expect_status "151:1"
keys %
expect_status "No delimiter on this line"
expect_status "151:1"
keys 5 0 %
expect_status "% does not take a count"
expect_status "151:1"
status_has "[+]" && fail "% made the document dirty" || ok "document still clean"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "Insert entry (a, A, I, o, O) and autoindent"
printf 'if x:\n  call()\n' > "$work/insert.txt"
launch insert.txt
keys j I
expect_status "INSERT"
type_text do_
keys Escape
expect_status "2:5"
keys A
type_text ' # ok'
keys Escape
expect_status "2:16"
# o and O copy the line's indentation, which stays if nothing more is typed.
keys o
expect_status "3:3"
type_text 'next()'
keys Escape
expect_status "3:8"
keys O
expect_status "3:3"
keys Escape
expect_status "3:2"
expect_screen "  1   next()"
# Undoing the opened line restores the cursor from before O.
keys u
expect_status "3:8"
expect_screen "3     next()"
# Enter copies the indentation too.
keys A Enter
expect_status "4:3"
type_text 'end()'
keys Escape
expect_status "4:7"
keys g g w a
type_text y
keys Escape
expect_status "1:5"
keys 3 o
expect_status "o does not take a count"
keys Space w
expect_status "Wrote"
printf 'if xy:\n  do_call() # ok\n  next()\n  end()\n' > "$work/insert.expected"
expect_file "$work/insert.txt" "$work/insert.expected"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "yank and paste"
printf 'alpha\nbeta\n' > "$work/yank.txt"
printf 'alpha\nalpha\nbeta\n' > "$work/yank.expected"
launch yank.txt
# No register yet; then yy/p inserts the yanked line below as one edit.
keys p
expect_status "Nothing in register"
keys y y p
expect_screen "  1 alpha"
expect_screen "2   alpha"
keys Space w
expect_file "$work/yank.txt" "$work/yank.expected"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "blockwise Visual selection (Ctrl-v)"
printf 'abcdefgh\n\tab\nab\nabcdefgh\n' > "$work/block.txt"
cp "$work/block.txt" "$work/block.expected"
launch block.txt
colored_row_has() { t capture-pane -e -p -t "$session" | grep -qF -- "$1"; }
# Block from column 2 down to line 4, column 4.
keys 2 l C-v 3 j l l
expect_status "VISUAL BLOCK"
expect_status "4:5"
char_under_cursor_is() { [ "$(char_under_cursor)" = "$1" ]; }
# Polled: the smear animation hides the cursor while it runs.
if poll char_under_cursor_is e; then ok "cursor on the block's corner"; else fail "cursor not on e"; fi
# The selected cells are drawn in another style, so the first line no longer comes
# out as one run of text.
if poll colored_row_has "cde" && ! colored_row_has "abcdefgh"; then
  ok "block cells highlighted"
else
  fail "block cells not highlighted"
fi
save_screen "block-selection"
# $ puts the Visual cursor on the line break and the block reaches each line's end.
keys '$'
expect_status "4:9"
save_screen "block-selection-dollar"
# Escape keeps the cursor, stepping back off the line break; nothing was edited, so a
# plain quit works.
keys Escape
expect_status "NORMAL"
expect_status "4:8"
if poll colored_row_has "abcdefgh"; then ok "highlight cleared"; else fail "highlight remains"; fi
keys Space q
expect_exit 0
expect_file "$work/block.txt" "$work/block.expected"

# ---------------------------------------------------------------------------
section "blockwise delete, yank, and paste"
printf 'abcdefgh\nab\nabcdefgh\n' > "$work/blockop.txt"
printf 'defabcgh\n   ab\ndefabcgh\n' > "$work/blockop.expected"
launch blockop.txt
# Delete columns 4-6 of all three lines; the short middle line is untouched, and the
# cursor goes to the block's top-left.
keys 3 l C-v 2 j l l d
expect_status "NORMAL"
expect_status "1:4"
expect_screen "1   abcgh"
expect_screen "  1 ab"
expect_screen "  2 abcgh"
# One undo step restores all three lines (and the cursor, on the third); redo
# deletes them again.
keys u
expect_screen "  2 abcdefgh"
expect_screen "3   abcdefgh"
keys C-r
expect_screen "1   abcgh"
# P puts the register's rows (with spaces for the short line) at the start of each
# line, lined up.
keys 0 P
expect_screen "1   defabcgh"
expect_screen "  1    ab"
expect_screen "  2 defabcgh"
expect_status "1:1"
keys Space w
expect_file "$work/blockop.txt" "$work/blockop.expected"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "block insert (I, A, c)"
printf 'abcdefgh\nab\nabcdefgh\n' > "$work/blockins.txt"
printf 'ZcXYdefgh.\nZ.\nZcXYdefgh.\n' > "$work/blockins.expected"
launch blockins.txt
# Row N (from 0) of the screen with its colors.
colored_row() { t capture-pane -e -p -t "$session" | sed -n "$(($1 + 1))p"; }
colored_line_has() { colored_row "$1" | grep -qF -- "$2"; }
# I before column 4 of all three lines (the short middle line is skipped). Typing
# shows on every line at once, before leaving Insert mode.
keys 3 l C-v 2 j I
expect_status "INSERT"
keys X Y
expect_screen "1   abcXYdefgh"
expect_screen "  2 abcXYdefgh"
expect_status "INSERT"
# Every insertion point, the cursor's own included, is drawn as a styled cell that
# splits its line's text; the terminal cursor is hidden meanwhile.
if poll colored_line_has 3 "abcXY" && ! colored_line_has 3 "abcXYdefgh" \
   && colored_line_has 1 "abcXY" && ! colored_line_has 1 "abcXYdefgh"; then
  ok "insertion points drawn on both lines"
else
  fail "insertion points not drawn"
fi
cursor_flag_is() { local flag; read -r _ _ flag <<< "$(cursor)"; [ "$flag" = "$1" ]; }
if poll cursor_flag_is 0; then ok "terminal cursor hidden"; else fail "terminal cursor shown: $(cursor)"; fi
save_screen "block-insert"
# The jk escape leaves, with the cursor at the block's top-left; one undo step
# removes the text from every line, and redo restores it.
keys j k
expect_status "NORMAL"
expect_status "1:4"
if poll cursor_flag_is 1; then ok "terminal cursor back"; else fail "terminal cursor still hidden"; fi
expect_screen "  2 abcXYdefgh"
keys u
expect_screen "  2 abcdefgh"
keys C-r
expect_screen "  2 abcXYdefgh"
# After $, A appends at each line's own end.
keys g g 0 C-v 2 j '$' A . Escape
expect_screen "1   abcXYdefgh."
expect_screen "  1 ab."
# c replaces the block's cells on every line that reaches it.
keys g g 0 C-v 2 j l c Z Escape
expect_screen "1   ZcXYdefgh."
expect_screen "  1 Z."
# Enter would make the lines diverge, so it is refused.
keys g g 0 C-v j I Enter
expect_status "Block insert cannot add a line break"
keys Escape
expect_status "NORMAL"
keys Space w
expect_file "$work/blockins.txt" "$work/blockins.expected"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "layout commands (Space v)"
# Where the tile's top corners are, in cells from the left.
tile_left() { local line prefix; line=$(row 0); prefix=${line%%╭*}; echo "${#prefix}"; }
tile_right() { local line prefix; line=$(row 0); prefix=${line%%╮*}; echo "${#prefix}"; }
tile_is() { [ "$(tile_left) $(tile_right)" = "$1 $2" ]; }
# Waits for FEEDBACK in the status line, then checks the tile's corners and that the
# cursor is visible on the first text cell of line 1, TEXT cells (default 7, after
# the border, padding, and gutter) from the left corner.
expect_layout() {
  local feedback=$1 left=$2 right=$3 text=${4:-7}
  expect_status "$feedback"
  if poll tile_is "$left" "$right"; then
    ok "tile spans $left..$right"
  else
    fail "tile spans $(tile_left)..$(tile_right), expected $left..$right"
  fi
  expect_cursor "$((left + text)) 1 1"
}
resize 160 48
launch edit.txt
expect_layout "1:1" 26 133
keys Space v
expect_status "Space v"
keys L
expect_layout "Offset +10" 36 143
keys Space v h
expect_layout "Offset +8" 34 141
keys Space v H
expect_layout "Offset -2" 24 131
keys Space v l
expect_layout "Offset 0" 26 133
keys Space v -
expect_layout "Width 90" 31 128
keys Space v =
expect_layout "Width 100" 26 133
keys Space v +
expect_layout "Width 110" 21 138
keys Space v c
expect_layout "Full width" 0 159
keys Space v c
expect_layout "Centered" 21 138
for _ in 1 2 3 4 5 6; do keys Space v L; done
expect_layout "Offset +60 (+21 fit)" 42 159
# A screen too small for the request clamps the tile; a larger one restores it.
resize 100 30
if poll tile_is 0 99; then ok "tile clamped to 100 columns"; else fail "tile not clamped at 100x30"; fi
expect_cursor "7 1 1"
resize 10 3
cursor_is() { [ "$(cursor)" = "$1" ]; }
poll cursor_is "0 0 1" && ok "cursor visible on the text at 10x3" \
  || fail "cursor not on the text at 10x3: $(cursor)"
resize 160 48
if poll tile_is 42 159; then ok "requested placement restored at 160x48"; else fail "placement not restored"; fi
expect_cursor "49 1 1"
# Full width ignores the offset; Space v l from full width centers again.
keys Space v c
expect_layout "Full width" 0 159
keys Space v l
expect_layout "Offset +62 (+21 fit)" 42 159
# Space v r also turns the line numbers off.
keys Space v r
expect_layout "Layout reset" 28 131 3
hybrid_numbers
for _ in 1 2 3 4 5 6 7 8 9 10; do keys Space v -; done
expect_layout "Width 20" 66 93
for _ in $(seq 1 50); do keys Space v +; done
expect_layout "Width 500 (152 fit)" 0 159
keys Space v r
expect_layout "Layout reset" 28 131 3
hybrid_numbers
keys Space v x
expect_status "Space v x is not bound"
# After Escape, l moves the cursor instead of nudging the tile.
keys Space v Escape l
expect_status "1:2"
poll tile_is 26 133 && ok "Escape cancels Space v" || fail "Escape did not cancel Space v"
keys h
expect_status "1:1"
# None of this touched the document: no dirty marker, nothing to undo, a plain quit.
status_has "[+]" && fail "layout commands made the document dirty" || ok "document still clean"
keys u
expect_status "Already at oldest change"
# In Insert mode the same keys are text.
keys i Space v c Escape
expect_screen "1    vcHi hello"
expect_status "1:3"
poll tile_is 26 133 && ok "tile unmoved by Insert-mode text" || fail "tile moved"
expect_cursor "35 1 1"
keys u
expect_screen "1   Hi hello"
keys Space q
expect_exit 0
expect_file "$work/edit.txt" "$work/edit.expected"
resize 80 24

# ---------------------------------------------------------------------------
section "line numbers (Space v n / N)"
resize 160 48
launch tall.txt
keys 2 j
expect_status "3:1"
# Hybrid (as launched): the cursor line's own number, left-aligned; distances
# elsewhere.
expect_cursor_row "│  3   line 3"
expect_screen "│    2 line 1"
expect_screen "│    2 line 5"
keys Space v n
expect_status "Line numbers: relative"
expect_cursor_row "│    0 line 3"
expect_screen "│    2 line 1"
# Neither switch: no gutter, and the centered tile narrows around the same text width.
keys Space v N
expect_status "Line numbers: off"
poll tile_is 28 131 && ok "tile narrows without a gutter" || fail "tile spans $(tile_left)..$(tile_right) without a gutter"
expect_cursor_row "│  line 3"
expect_cursor "31 3 1"
keys Space v n
expect_status "Line numbers: absolute"
poll tile_is 26 133 && ok "gutter back" || fail "tile spans $(tile_left)..$(tile_right) with a gutter"
expect_cursor_row "│    3 line 3"
expect_cursor "33 3 1"
# A count is rejected, and the style kept.
keys 3 Space v N
expect_status "Space v N does not take a count"
expect_cursor_row "│    3 line 3"
keys Space v N
expect_status "Line numbers: hybrid"
expect_cursor_row "│  3   line 3"
# Space v r turns them off with the rest of the layout.
keys Space v N
expect_status "Line numbers: absolute"
keys Space v r
expect_status "Layout reset"
expect_cursor_row "│  line 3"
hybrid_numbers
expect_cursor_row "│  3   line 3"
# Moving the cursor renumbers; the text never shifts.
keys j
expect_status "4:1"
expect_cursor_row "│  4   line 4"
expect_screen "│    1 line 3"
expect_cursor "33 4 1"
# Too small for a gutter: the style is still switched, and shows when there is room.
resize 18 6
expect_screen "line 4"
keys Space v N
resize 160 48
expect_status "Line numbers: absolute (no room)"
expect_cursor_row "│    4 line 4"
status_has "[+]" && fail "line-number toggles made the document dirty" || ok "document still clean"
keys Space q
expect_exit 0
resize 80 24

# ---------------------------------------------------------------------------
section "view scrolling (Ctrl-e/y/d/u, zz/zt/zb)"
# At 80x24 the text viewport has 21 rows, from screen row 1; text starts at column 7.
resize 80 24
launch tall.txt
keys 1 0 j
expect_status "11:1"
# Ctrl-e scrolls the view; the cursor stays on its line while it is visible.
keys C-e
expect_screen "│    9 line 2 "
expect_status "11:1"
expect_cursor "7 10 1"
keys 5 C-e
expect_screen "│    4 line 7 "
expect_cursor "7 5 1"
# ... and is pushed down when its line would leave the top.
keys 1 0 C-e
expect_status "17:1"
expect_cursor_row "│  17  line 17"
expect_cursor "7 1 1"
keys 2 0 C-y
expect_screen "│   16 line 1 "
expect_status "17:1"
expect_cursor "7 17 1"
# Ctrl-d / Ctrl-u move the view and cursor by half the viewport (10 lines).
keys C-d
expect_status "27:1"
expect_cursor "7 17 1"
keys C-u
expect_status "17:1"
expect_cursor "7 17 1"
# zt / zb / zz place the cursor line; the cursor itself stays.
keys 5 0 G
expect_status "50:1"
keys z t
expect_cursor "7 1 1"
keys z b
expect_cursor "7 21 1"
keys z z
expect_cursor "7 11 1"
expect_status "50:1"
keys 3 z z
expect_status "z z does not take a count"
expect_cursor "7 11 1"
# Past the end: the last line can reach the top, and moving within the view keeps it.
keys G 9 9 9 C-e
expect_status "201:1"
expect_cursor "7 1 1"
keys k
expect_status "200:1"
expect_cursor "7 1 1"
keys j
expect_cursor "7 2 1"
# Resizing after scrolling keeps the cursor visible: 7 rows, filled to the end.
resize 40 10
expect_cursor "7 7 1"
expect_screen "│    6 line 195"
# Back at the size of the last key, before any key, the view is as it was.
resize 80 24
expect_cursor "7 2 1"
# Tiny terminals: two rows still scroll; with no text rows nothing changes.
keys g g
resize 10 3
sleep 0.3
keys C-e
resize 20 1
sleep 0.3
keys C-e C-d z t
resize 80 24
expect_status "2:1"
expect_cursor_row "2   line 2"
# Insert mode leaves these keys unbound; nothing is typed.
keys i C-e C-y Escape
expect_status "NORMAL"
status_has "[+]" && fail "scrolling made the document dirty" || ok "document still clean"
keys u
expect_status "Already at oldest change"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "workspace status cells and zen restoration"
resize 80 24
for i in $(seq 1 60); do printf 'workspace line %d\n' "$i"; done > "$work/workspace.txt"
cp "$work/workspace.txt" "$work/workspace.expected"
launch workspace.txt
keys Space v t
expect_screen "Status right 28 (shown)"
expect_cursor "7 1 1"
save_screen "workspace-right-80x24"
keys Space v p h
expect_screen "Status left 28 (shown)"
expect_cursor "36 1 1"
keys 4 0 j
expect_cursor_row "41  workspace line 41"
keys g g
expect_cursor "36 1 1"
save_screen "workspace-left-80x24"
keys Space v p k
expect_screen "Status above 6 (shown)"
expect_cursor "7 7 1"
save_screen "workspace-above-80x24"
keys Space v p j
expect_screen "Status below 6 (shown)"
expect_cursor "7 1 1"
keys Space v p +
expect_screen "Status below 8 (shown)"
keys Space v p -
expect_screen "Status below 6 (shown)"
keys Space v z
expect_status "Zen (status hidden)"
expect_cursor "7 1 1"
keys Space v p
expect_status "Space v p"
keys Escape Space v p h
expect_status "Status left 28 (saved for workspace; zen)"
keys Space v z
expect_screen "Workspace restored"
expect_cursor "36 1 1"
resize 23 12
expect_status "NORMAL"
expect_cursor "6 0 1"
resize 1 1
if poll cursor_flag_is 0; then ok "no cursor in empty document viewport"; else fail "cursor shown at 1x1"; fi
resize 160 48
expect_cursor "47 1 1"
expect_screen "workspace.txt"
save_screen "workspace-left-160x48"
# Hide/show preserves placement and the document's preferred width.
keys Space v t
expect_status "Status left 28 (hidden)"
expect_cursor "33 1 1"
keys Space v t
expect_screen "Status left 28 (shown)"
expect_cursor "47 1 1"
keys i X Escape
expect_screen "workspace.txt [+]"
expect_cursor_row "Xworkspace line 1"
keys u
expect_cursor_row "workspace line 1"
keys C-r
expect_cursor_row "Xworkspace line 1"
keys Space w
expect_screen "Wrote workspace.txt"
sed '1s/^/X/' "$work/workspace.expected" > "$work/workspace.saved"
expect_file "$work/workspace.txt" "$work/workspace.saved"
keys u Space w
expect_screen "Wrote workspace.txt"
keys Space q
expect_exit 0
expect_file "$work/workspace.txt" "$work/workspace.expected"
# A controlled save failure remains visible when moving/hiding status or using zen.
resize 80 24
launch ro/workspace.txt
keys i X Escape Space w
expect_status "Permission denied"
keys Space v t
expect_screen "Failed to write ro/work>"
keys Space v p h
expect_screen "Failed to write ro/work>"
keys Space v z
expect_status "Permission denied"
save_screen "workspace-error-zen-80x24"
keys Space v z
expect_screen "Failed to write ro/work>"
# Editing and keymap notices cannot replace unacknowledged persistence attention.
keys l i Y Escape 3 '^'
expect_screen "Failed to write ro/work>"
keys Escape
expect_screen "1 problem: Space v e"
expect_no_screen "Failed to write"
save_screen "workspace-problem-acknowledged-80x24"
keys Space v e
expect_screen "Failed to write ro/work>"
keys Space w
expect_screen "Failed to write ro/work>"
keys Escape
expect_screen "1 problem: Space v e"
# Matching save recovery removes the retained save problem.
keys Space v b
expect_screen "Problems (workspace): 1/1"
expect_screen "error [file] ro/workspace.txt: Failed to write"
keys Space v f
expect_screen "Problems (document): 1/1"
keys Space v z
expect_no_screen "Problems ("
keys Space v z
expect_screen "Problems (document): 1/1"
resize 15 4
expect_no_screen "Problems ("
resize 80 24
expect_screen "Problems (document): 1/1"
save_screen "workspace-problems-acknowledged-80x24"
keys Space v b
expect_no_screen "Problems ("
keys Space v b
expect_screen "Problems (document): 1/1"
chmod 755 "$work/ro"
keys Space w
expect_screen "Wrote ro/workspace.txt"
expect_no_screen "problems:"
expect_screen "Problems (document): 0/0"
expect_screen "No active problems"
keys Space v b
# A reload failure has its own identity and matching recovery.
mv "$work/ro/workspace.txt" "$work/workspace-reload.saved"
mkdir "$work/ro/workspace.txt"
keys : e ! Enter
expect_screen "Failed to reload"
keys Space v b
expect_screen "Problems (document): 1/1"
expect_screen "error [file] ro/workspace.txt: Failed to reload"
keys l Escape
expect_screen "1 problem: Space v e"
keys Space v e
expect_screen "Failed to reload"
rmdir "$work/ro/workspace.txt"
mv "$work/workspace-reload.saved" "$work/ro/workspace.txt"
keys : e ! Enter
expect_screen "Reloaded ro/workspace.t"
expect_no_screen "problems:"
expect_screen "Problems (document): 0/0"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "interactive problems pane"
resize 80 24
printf 'first\nsecond\n' > "$work/problems.txt"
launch problems.txt
mv "$work/problems.txt" "$work/problems.saved"
mkdir "$work/problems.txt"
keys i X Escape Space w : e ! Enter
expect_screen "2 problems"
keys Space v o
expect_screen "Problems* (workspace): 2/2 [1/2]"
pane_cursor_hidden() { [ "$(t display -p -t "$session" '#{cursor_flag}')" = 0 ]; }
if poll pane_cursor_hidden; then ok "problems capture hides terminal cursor"; else fail "pane cursor visible"; fi
keys j
expect_screen "Problems* (workspace): 2/2 [2/2]"
keys a
expect_screen "Acknowledged; problem remains active"
keys e
expect_screen "Problems* details"
expect_screen "Failed to reload"
keys Escape g Escape
expect_screen "Problems* (workspace): 2/2 [2/2]"
keys Enter
expect_screen "This problem has no document location"
keys i u Space q
expect_screen "Editor command unavailable"
t set-buffer -b smoke ' voij'
t paste-buffer -p -b smoke -t "$session"
expect_screen "Problems: read-only; paste ignored"
save_screen "workspace-problems-focused-80x24"
resize 15 4
expect_no_screen "Problems*"
resize 80 24
expect_screen "Problems (workspace): 2/2"
expect_cursor_row "Xfirst"
keys u
expect_cursor_row "first"
rmdir "$work/problems.txt"
mv "$work/problems.saved" "$work/problems.txt"
keys Space w : e ! Enter
expect_screen "Problems (workspace): 0/0"
keys Space v o
expect_screen "No active problems"
keys Escape Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "opt-in demo problems and real location jumps"
for i in $(seq 1 12); do printf 'demo line %s\n' "$i"; done > "$work/problems-demo.txt"
cp "$work/problems-demo.txt" "$work/problems-demo.expected"
launch --demo-problems problems-demo.txt
keys Space v o
expect_screen "Problems* (workspace): 8/8 [1/8]"
keys G
expect_screen "Problems* (workspace): 8/8 [8/8]"
keys e
expect_screen "Problems* details"
expect_screen "DEMO 8/8: jump to line 13, column 1"
keys C-d Enter
expect_cursor "7 13 1"
keys Space v o g g Enter
expect_cursor "7 1 1"
expect_cursor_row "demo line 1"
keys Space w
expect_file "$work/problems-demo.txt" "$work/problems-demo.expected"
expect_screen "Problems (workspace): 8/8"
save_screen "workspace-demo-problems-jumps-80x24"
keys Space q
expect_exit 0
launch problems-demo.txt
keys Space v b
expect_screen "No active problems"
expect_screen "Problems (workspace): 0/0"
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "static demo report through the shared tile host"
printf 'report one\nreport two\n' > "$work/report.txt"
cp "$work/report.txt" "$work/report.expected"
launch --demo-report report.txt
keys Space v d
expect_screen "Demo report (static): 10 items"
# Phase 7B: the shared shell frames the view, with its labels set into the borders.
expect_screen "╭─ Demo report (static): 10 items ─"
expect_screen "╰─ Space v D: focus ─"
keys Space v D
expect_screen "Demo report* (static): [1/10]"
if poll pane_cursor_hidden; then ok "report capture hides terminal cursor"; else fail "report cursor visible"; fi
keys G e
expect_screen "Demo report* details (static): [10/10]"
expect_screen "DEMO REPORT 10/10"
keys G
expect_screen "Details "
expect_no_screen "DEMO REPORT 10/10"
keys Escape
expect_screen "Demo report* (static): [10/10]"
keys Space v o
expect_screen "Problems* (workspace): 0/0 [0/0]"
expect_screen "Demo report (static): 10 items"
keys Space v D
expect_screen "Demo report* (static): [10/10]"
t set-buffer -b smoke ' vDij'
t paste-buffer -p -b smoke -t "$session"
expect_screen "Demo report: read-only; paste ignored"
expect_screen "╰─ Demo report: read-only; paste igno> ╯"
save_screen "workspace-demo-report-80x24"
keys Tab
expect_screen "Demo report (static): 10 items"
expect_no_screen "Demo report*"
keys Space w
expect_file "$work/report.txt" "$work/report.expected"
# Framed status beside the document and both minor views in the band, for review at
# laptop and monitor sizes. Problems is still shown from above.
keys Space v t
expect_screen "╭─ Status ─"
expect_screen "╭─ Problems (workspace): 0/0 ─"
resize 120 40
expect_screen "╭─ Demo report (static): 10 items ─"
save_screen "tiles-shell-120x40"
resize 200 60
expect_screen "╭─ Demo report (static): 10 items ─"
save_screen "tiles-shell-200x60"
# The same screens in open chrome (Space v g), for comparison.
keys Space v g
expect_screen "Chrome: open"
expect_screen "▐╭─ Status ─"
save_screen "tiles-shell-open-200x60"
resize 120 40
expect_screen "╮▐╭─ Demo report (static): 10 items ─"
save_screen "tiles-shell-open-120x40"
keys Space v g
expect_screen "Chrome: classic"
expect_no_screen "▐"
resize 80 24
keys Space q
expect_exit 0
launch report.txt
keys Space v d
expect_screen "Demo report unavailable; launch with --demo-report"
expect_no_screen "Demo report ("
keys Space q
expect_exit 0

# ---------------------------------------------------------------------------
section "scrolling a wide line"
{ for _ in $(seq 1 40); do printf '0123456789'; done; printf '\nshort\n'; } > "$work/wide.txt"
launch wide.txt
keys -N 250 l
expect_status "1:251"
cursor_inside_wide_text() {
  local x visible
  read -r x _ visible <<< "$(cursor)"
  [ "$visible" = 1 ] && [ "$x" -ge 7 ] && [ "$x" -le 78 ]
}
if poll cursor_inside_wide_text; then ok "cursor inside the text"; else fail "cursor outside the text: $(cursor)"; fi
if poll char_under_cursor_is 0; then ok "cursor on the 251st character"; else fail "wrong character under the cursor"; fi
keys j
expect_status "2:5"
expect_cursor "11 2 1"
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
  keys Space v n
  expect_status "Line numbers: relative"
  save_screen "numbers-relative-$size"
  keys Space v N
  expect_status "Line numbers: off"
  save_screen "numbers-off-$size"
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
