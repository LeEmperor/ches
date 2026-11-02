#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <pty.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>

extern char **environ;
typedef struct { int fd; pid_t pid; int reaped; int status; int status_known; } Pty;
#define PTY(v) ((Pty *)Data_custom_val(v))
static void fail(const char *operation) {
  char buf[256]; int err = errno;
  snprintf(buf, sizeof(buf), "%s: %s", operation, strerror(err));
  caml_failwith(buf);
}
static int owns_child(Pty *p) {
  if (p->reaped || p->pid <= 0) return 0;
  siginfo_t info; memset(&info, 0, sizeof(info));
  int r;
  do { r = waitid(P_PID, p->pid, &info, WEXITED | WNOHANG | WNOWAIT); }
  while (r < 0 && errno == EINTR);
  if (r < 0 && errno == ECHILD) p->reaped = 1;
  return r == 0;
}
static void signal_group(Pty *p, int sig) {
  if (!owns_child(p)) return;
  /* Job-control shells can put a foreground job in a different group. */
  if (p->fd >= 0) {
    pid_t foreground = tcgetpgrp(p->fd);
    if (foreground > 0 && foreground != getpgrp() &&
        getsid(foreground) == p->pid) kill(-foreground, sig);
  }
  kill(-p->pid, sig);
  kill(p->pid, sig);
}
static void kill_session(Pty *p) {
  /* A job-control shell's background jobs need not share its process group.
   * Linux keeps their session id even after the session leader exits. Clean up
   * all remaining members, including jobs which deliberately ignore SIGHUP. */
  if (!owns_child(p)) return;
  DIR *dir = opendir("/proc");
  if (!dir) return;
  struct dirent *entry;
  while ((entry = readdir(dir))) {
    char *end; long id = strtol(entry->d_name, &end, 10);
    if (*end || id <= 0 || id == getpid()) continue;
    if (getsid((pid_t)id) == p->pid) kill((pid_t)id, SIGKILL);
  }
  closedir(dir);
}
static void close_fd(Pty *p) {
  if (p->fd >= 0) { close(p->fd); p->fd = -1; }
}
static void finalize(value v) {
  Pty *p = PTY(v);
  if (!p->reaped && p->pid > 0) kill_session(p);
  signal_group(p, SIGKILL);
  close_fd(p);
  /* Finalizers cannot block the Async scheduler. Runtime normally reaps first. */
  if (!p->reaped && p->pid > 0) {
    int status;
    pid_t r = waitpid(p->pid, &status, WNOHANG);
    if (r == p->pid || (r < 0 && errno == ECHILD)) p->reaped = 1;
  }
}
static struct custom_operations ops = {
  "ches.pty.linux", finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};
CAMLprim value ches_pty_spawn(value cwd, value rows, value cols) {
  CAMLparam3(cwd, rows, cols); CAMLlocal1(v);
  if (memchr(String_val(cwd), 0, caml_string_length(cwd)))
    caml_invalid_argument("terminal cwd contains NUL");
  v = caml_alloc_custom(&ops, sizeof(Pty), 0, 1);
  Pty *p = PTY(v); p->fd = -1; p->pid = -1; p->reaped = 0;
  p->status = 0; p->status_known = 0;
  /* Prepare all allocation, environment and signal state before fork. The
   * child never returns to OCaml and calls only async-signal-safe operations. */
  const char *configured = getenv("SHELL");
  char *shell = strdup(configured && configured[0] == '/' ? configured : "/bin/sh");
  char *directory = strdup(String_val(cwd));
  size_t count = 0; while (environ[count]) count++;
  char **env = calloc(count + 2, sizeof(char *));
  if (!shell || !directory || !env) {
    free(shell); free(directory); free(env); caml_raise_out_of_memory();
  }
  size_t j = 0;
  for (size_t i = 0; i < count; i++)
    if (strncmp(environ[i], "TERM=", 5) != 0) env[j++] = environ[i];
  env[j++] = "TERM=xterm-256color"; env[j] = NULL;
  char *argv[] = { shell, "-i", NULL };
  char *fallback[] = { "/bin/sh", "-i", NULL };
  struct winsize ws = { .ws_row = Int_val(rows), .ws_col = Int_val(cols) };
  sigset_t empty; sigemptyset(&empty);
  struct sigaction action; memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
  int fd = -1;
  pid_t pid = forkpty(&fd, NULL, NULL, &ws);
  int saved = errno;
  if (pid == 0) {
    sigprocmask(SIG_SETMASK, &empty, NULL);
    for (int s = 1; s < NSIG; s++) sigaction(s, &action, NULL);
    /* The PTY is already fd 0/1/2 and is this session's controlling terminal. */
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 3u, ~0u, 0u) < 0)
#endif
      for (int i = 3; i < 65536; i++) close(i);
    if (chdir(directory) < 0) {
      const char msg[] = "ches terminal: cannot change directory\r\n";
      (void)!write(2, msg, sizeof(msg)-1); _exit(126);
    }
    execve(shell, argv, env);
    execve("/bin/sh", fallback, env);
    const char msg[] = "ches terminal: cannot exec shell\r\n";
    (void)!write(2, msg, sizeof(msg)-1); _exit(127);
  }
  free(shell); free(directory); free(env);
  if (pid < 0) { errno = saved; fail("forkpty"); }
  p->fd = fd; p->pid = pid;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
    saved = errno; signal_group(p, SIGKILL); close_fd(p); errno = saved;
    fail("configure PTY");
  }
  CAMLreturn(v);
}
CAMLprim value ches_pty_read(value v) {
  CAMLparam1(v); CAMLlocal2(s, some);
  Pty *p = PTY(v); char buf[16384]; ssize_t n = 0;
  if (p->fd >= 0) {
    do { n = read(p->fd, buf, sizeof(buf)); } while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) CAMLreturn(Val_int(0));
    if (n < 0 && errno == EIO) n = 0; /* Linux PTY EOF */
    if (n < 0) fail("read PTY");
  }
  s = caml_alloc_initialized_string(n, buf);
  some = caml_alloc(1, 0); Store_field(some, 0, s); CAMLreturn(some);
}
CAMLprim value ches_pty_write(value v, value data, value offset) {
  CAMLparam3(v, data, offset);
  Pty *p = PTY(v); intnat pos = Long_val(offset);
  size_t len = caml_string_length(data);
  if (pos < 0 || (uintnat)pos > len) caml_invalid_argument("PTY write offset");
  if (p->fd < 0) caml_failwith("write closed PTY");
  size_t count = len - pos; if (count > 16384) count = 16384;
  ssize_t n;
  do { n = write(p->fd, String_val(data) + pos, count); } while (n < 0 && errno == EINTR);
  if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) n = 0;
  if (n < 0) fail("write PTY");
  CAMLreturn(Val_int(n));
}
CAMLprim value ches_pty_resize(value v, value rows, value cols) {
  CAMLparam3(v, rows, cols);
  struct winsize ws = { .ws_row = Int_val(rows), .ws_col = Int_val(cols) };
  if (PTY(v)->fd < 0) caml_failwith("resize closed PTY");
  if (ioctl(PTY(v)->fd, TIOCSWINSZ, &ws) < 0) fail("resize PTY");
  CAMLreturn(Val_unit);
}
CAMLprim value ches_pty_poll_exit(value v) {
  CAMLparam1(v); CAMLlocal2(s, some);
  Pty *p = PTY(v);
  if (!p->reaped) {
    /* Keep the exited leader waitable until session cleanup completes. Reaping
     * it first makes its numeric PID/session id eligible for reuse, and a /proc
     * scan could then signal an unrelated, newly created session. */
    siginfo_t info; memset(&info, 0, sizeof(info));
    int observed;
    do { observed = waitid(P_PID, p->pid, &info, WEXITED | WNOHANG | WNOWAIT); }
    while (observed < 0 && errno == EINTR);
    if (observed < 0) {
      if (errno != ECHILD) fail("waitid terminal");
      /* An external reaper has taken ownership. Never signal a recycled pid. */
      p->reaped = 1;
    } else {
      if (!info.si_pid) CAMLreturn(Val_int(0));
      kill_session(p);
      pid_t r;
      do { r = waitpid(p->pid, &p->status, WNOHANG); } while (r < 0 && errno == EINTR);
      if (r == 0) CAMLreturn(Val_int(0));
      if (r < 0 && errno != ECHILD) fail("waitpid terminal");
      p->status_known = r == p->pid;
      p->reaped = 1;
    }
  }
  char buf[80];
  if (!p->status_known) snprintf(buf, sizeof(buf), "exit status unavailable (reaped externally)");
  else if (WIFEXITED(p->status)) snprintf(buf, sizeof(buf), "exited %d", WEXITSTATUS(p->status));
  else if (WIFSIGNALED(p->status)) snprintf(buf, sizeof(buf), "signal %d", WTERMSIG(p->status));
  else snprintf(buf, sizeof(buf), "exited");
  s = caml_copy_string(buf); some = caml_alloc(1, 0);
  Store_field(some, 0, s); CAMLreturn(some);
}
CAMLprim value ches_pty_signal(value v, value force) {
  CAMLparam2(v, force);
  if (Bool_val(force) && !PTY(v)->reaped) kill_session(PTY(v));
  signal_group(PTY(v), Bool_val(force) ? SIGKILL : SIGHUP);
  CAMLreturn(Val_unit);
}
CAMLprim value ches_pty_close(value v) {
  CAMLparam1(v); close_fd(PTY(v)); CAMLreturn(Val_unit);
}
