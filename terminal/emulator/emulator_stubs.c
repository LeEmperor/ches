#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <string.h>
#include <vterm.h>

/* All callbacks are C-only. The output buffer is bounded, including replies to
 * maliciously repetitive device-status queries. No callbacks enter OCaml. */
#define OUTPUT_LIMIT (1024 * 1024)
typedef struct {
  VTerm *vt;
  VTermScreen *screen;
  int visible;
  char *out;
  size_t len;
  int overflow;
} Emulator;

#define EMU(v) (*((Emulator **)Data_custom_val(v)))
static Emulator *get(value v) {
  Emulator *e = EMU(v);
  if (!e || !e->vt) caml_invalid_argument("closed terminal emulator");
  return e;
}
static void destroy(Emulator *e) {
  if (!e) return;
  if (e->vt) vterm_free(e->vt);
  free(e->out);
  free(e);
}
static void finalize(value v) { destroy(EMU(v)); EMU(v) = NULL; }
static struct custom_operations ops = {
  "ches.libvterm.0.3.3", finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};
static void output(const char *s, size_t len, void *user) {
  Emulator *e = user;
  if (len > OUTPUT_LIMIT - e->len) { e->overflow = 1; return; }
  memcpy(e->out + e->len, s, len);
  e->len += len;
}
static int property(VTermProp prop, VTermValue *val, void *user) {
  Emulator *e = user;
  if (prop == VTERM_PROP_CURSORVISIBLE) e->visible = val->boolean;
  return 1;
}
static int cursor(VTermPos pos, VTermPos old, int visible, void *user) {
  (void)pos; (void)old;
  ((Emulator *)user)->visible = visible;
  return 1;
}
static const VTermScreenCallbacks callbacks = {
  .movecursor = cursor, .settermprop = property
};
static value take_output(Emulator *e) {
  CAMLparam0(); CAMLlocal1(s);
  if (e->overflow) {
    e->len = 0; e->overflow = 0;
    caml_failwith("terminal protocol reply exceeds 1 MiB");
  }
  s = caml_alloc_initialized_string(e->len, e->out);
  e->len = 0;
  CAMLreturn(s);
}
CAMLprim value ches_vterm_create(value rows, value cols) {
  CAMLparam2(rows, cols); CAMLlocal1(v);
  v = caml_alloc_custom(&ops, sizeof(Emulator *), OUTPUT_LIMIT, 100 * OUTPUT_LIMIT);
  EMU(v) = NULL;
  Emulator *e = calloc(1, sizeof(*e));
  if (!e) caml_raise_out_of_memory();
  EMU(v) = e;
  e->out = malloc(OUTPUT_LIMIT);
  if (!e->out) caml_raise_out_of_memory();
  e->vt = vterm_new(Int_val(rows), Int_val(cols));
  if (!e->vt) caml_raise_out_of_memory();
  e->visible = 1;
  vterm_set_utf8(e->vt, 1);
  vterm_output_set_callback(e->vt, output, e);
  e->screen = vterm_obtain_screen(e->vt);
  vterm_screen_enable_altscreen(e->screen, 1);
  vterm_screen_set_callbacks(e->screen, &callbacks, e);
  vterm_screen_set_damage_merge(e->screen, VTERM_DAMAGE_SCREEN);
  vterm_state_set_bold_highbright(vterm_obtain_state(e->vt), 0);
  vterm_screen_reset(e->screen, 1);
  CAMLreturn(v);
}
CAMLprim value ches_vterm_close(value v) {
  CAMLparam1(v); finalize(v); CAMLreturn(Val_unit);
}
CAMLprim value ches_vterm_resize(value v, value rows, value cols) {
  CAMLparam3(v, rows, cols);
  Emulator *e = get(v);
  vterm_set_size(e->vt, Int_val(rows), Int_val(cols));
  CAMLreturn(Val_unit);
}
CAMLprim value ches_vterm_feed(value v, value data) {
  CAMLparam2(v, data);
  Emulator *e = get(v);
  vterm_input_write(e->vt, String_val(data), caml_string_length(data));
  vterm_screen_flush_damage(e->screen);
  CAMLreturn(take_output(e));
}
CAMLprim value ches_vterm_key(value v, value character, value code, value mods) {
  CAMLparam4(v, character, code, mods);
  Emulator *e = get(v);
  if (Bool_val(character)) {
    int modifiers = Int_val(mods);
    uint32_t c = Int_val(code);
    /* Notty decodes C0 input as uppercase ASCII + Ctrl. libvterm otherwise
     * sends uppercase Ctrl letters (and Ctrl-@/Space) as CSI-u, even though
     * the application has not requested an extended keyboard protocol. */
    if ((modifiers & VTERM_MOD_CTRL) &&
        ((c >= '@' && c <= '_') || (c >= 'a' && c <= 'z') || c == ' ' || c == '?')) {
      c = c == '?' ? 127 : c & 0x1f;
      modifiers &= ~(VTERM_MOD_CTRL | VTERM_MOD_SHIFT);
    }
    /* libvterm 0.3.3's Alt-only branch emits a single byte with %c, which
     * truncates non-ASCII scalars. Prefix ESC and let its ordinary UTF-8 path
     * encode the character instead. Ctrl combinations still use its CSI-u. */
    if (c > 127 && (modifiers & VTERM_MOD_ALT) &&
        !(modifiers & VTERM_MOD_CTRL)) {
      vterm_keyboard_key(e->vt, VTERM_KEY_ESCAPE, VTERM_MOD_NONE);
      modifiers &= ~VTERM_MOD_ALT;
    }
    vterm_keyboard_unichar(e->vt, c, modifiers);
  } else if (Int_val(code) == VTERM_KEY_BACKSPACE &&
             (Int_val(mods) & VTERM_MOD_CTRL)) {
    /* Notty represents the original ^H byte as Ctrl-Backspace. */
    vterm_keyboard_unichar(e->vt, 8, Int_val(mods) & ~(VTERM_MOD_CTRL | VTERM_MOD_SHIFT));
  } else vterm_keyboard_key(e->vt, Int_val(code), Int_val(mods));
  CAMLreturn(take_output(e));
}
CAMLprim value ches_vterm_paste(value v, value data) {
  CAMLparam2(v, data); CAMLlocal3(start, end, result);
  Emulator *e = get(v);
  vterm_keyboard_start_paste(e->vt);
  start = take_output(e);
  vterm_keyboard_end_paste(e->vt);
  end = take_output(e);
  size_t a = caml_string_length(start), b = caml_string_length(data), c = caml_string_length(end);
  if (b > OUTPUT_LIMIT - a - c) caml_invalid_argument("terminal paste exceeds 1 MiB");
  size_t normalized = b;
  for (size_t i = 0; i + 1 < b; i++)
    if (Byte_u(data, i) == '\r' && Byte_u(data, i + 1) == '\n') { normalized--; i++; }
  result = caml_alloc_string(a + normalized + c);
  memcpy(Bytes_val(result), String_val(start), a);
  /* CRLF is one pasted newline, not two Enter presses. In ordinary input
   * mode use the terminal's Enter byte; bracketed paste carries text newlines.
   * Encoding here also covers callers which bypass the screen collector. */
  size_t used = a;
  for (size_t i = 0; i < b; i++) {
    unsigned char ch = Byte_u(data, i);
    if (ch == '\r') {
      if (i + 1 < b && Byte_u(data, i + 1) == '\n') i++;
      ch = a ? '\n' : '\r';
    } else if (ch == '\n') ch = a ? '\n' : '\r';
    Byte(result, used++) = ch;
  }
  memcpy(Bytes_val(result) + used, String_val(end), c);
  CAMLreturn(result);
}
static value color(VTermColor c) {
  CAMLparam0(); CAMLlocal1(v);
  if (c.type & VTERM_COLOR_DEFAULT_MASK) CAMLreturn(Val_int(0));
  if (VTERM_COLOR_IS_INDEXED(&c)) {
    v = caml_alloc(1, 0); Store_field(v, 0, Val_int(c.indexed.idx));
  } else {
    v = caml_alloc(3, 1);
    Store_field(v, 0, Val_int(c.rgb.red));
    Store_field(v, 1, Val_int(c.rgb.green));
    Store_field(v, 2, Val_int(c.rgb.blue));
  }
  CAMLreturn(v);
}
static size_t utf8(char *out, uint32_t c) {
  if (c < 0x80) { out[0] = c; return 1; }
  if (c < 0x800) { out[0] = 0xc0 | (c >> 6); out[1] = 0x80 | (c & 63); return 2; }
  if (c < 0x10000) {
    out[0] = 0xe0 | (c >> 12); out[1] = 0x80 | ((c >> 6) & 63);
    out[2] = 0x80 | (c & 63); return 3;
  }
  out[0] = 0xf0 | (c >> 18); out[1] = 0x80 | ((c >> 12) & 63);
  out[2] = 0x80 | ((c >> 6) & 63); out[3] = 0x80 | (c & 63); return 4;
}
static value cell_value(VTermScreenCell *c) {
  CAMLparam0(); CAMLlocal5(cell, style, fg, bg, text);
  char buf[VTERM_MAX_CHARS_PER_CELL * 4]; size_t len = 0;
  int continuation = c->chars[0] == (uint32_t)-1;
  if (!continuation) {
    for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && c->chars[i]; i++)
      len += utf8(buf + len, c->chars[i]);
    if (!len) buf[len++] = ' ';
  }
  text = caml_alloc_initialized_string(len, buf);
  fg = color(c->fg); bg = color(c->bg);
  style = caml_alloc(6, 0);
  Store_field(style, 0, fg); Store_field(style, 1, bg);
  Store_field(style, 2, Val_bool(c->attrs.bold));
  Store_field(style, 3, Val_bool(c->attrs.italic));
  Store_field(style, 4, Val_bool(c->attrs.underline != 0));
  Store_field(style, 5, Val_bool(c->attrs.reverse));
  cell = caml_alloc(3, 0);
  Store_field(cell, 0, text);
  Store_field(cell, 1, Val_int(continuation ? 0 : c->width));
  Store_field(cell, 2, style);
  CAMLreturn(cell);
}
CAMLprim value ches_vterm_snapshot(value v) {
  CAMLparam1(v); CAMLlocal4(result, rows, row, cell);
  Emulator *e = get(v); int h, w; VTermPos pos;
  vterm_screen_flush_damage(e->screen);
  vterm_get_size(e->vt, &h, &w);
  rows = caml_alloc(h, 0);
  for (int y = 0; y < h; y++) Store_field(rows, y, Val_unit);
  for (int y = 0; y < h; y++) {
    row = caml_alloc(w, 0);
    for (int x = 0; x < w; x++) Store_field(row, x, Val_unit);
    for (int x = 0; x < w; x++) {
      VTermScreenCell c;
      memset(&c, 0, sizeof(c));
      vterm_screen_get_cell(e->screen, (VTermPos){y,x}, &c);
      cell = cell_value(&c); Store_field(row, x, cell);
    }
    Store_field(rows, y, row);
  }
  vterm_state_get_cursorpos(vterm_obtain_state(e->vt), &pos);
  result = caml_alloc(5, 0);
  Store_field(result, 0, rows);
  Store_field(result, 1, Val_int(pos.row)); Store_field(result, 2, Val_int(pos.col));
  Store_field(result, 3, Val_bool(e->visible)); Store_field(result, 4, Val_int(0));
  CAMLreturn(result);
}
