#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include "tree_sitter/parser.h"

extern const TSLanguage *tree_sitter_systemverilog(void);

CAMLprim value ches_tree_sitter_systemverilog_language(value unit) {
  CAMLparam1(unit);
  CAMLreturn(caml_copy_nativeint((intnat)tree_sitter_systemverilog()));
}
