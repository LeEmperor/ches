#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <errno.h>
#include <string.h>

/* No check-then-rename fallback: rename(2) overwrites unrelated occupants. */
CAMLprim value ches_rename_noreplace(value source, value destination)
{
  CAMLparam2(source, destination);
  if (renameat2(AT_FDCWD, String_val(source), AT_FDCWD,
                String_val(destination), RENAME_NOREPLACE) != 0)
    caml_failwith(strerror(errno));
  CAMLreturn(Val_unit);
}
