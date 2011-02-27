#include "owl.h"

#include <glib.h>
#include <unistd.h>

#if OWL_STDERR_REDIR

static GThread *stderr_thread;

/* TODO: Pass all these as argument to the thread instead of making
 * them globals? */
int stderr_fd;
static void (*stderr_cb)(const char*, void*);
static void *stderr_cbdata;

static gpointer stderr_thread_func(gpointer data);
static void stderr_thunk(void *data);

/* Replaces stderr with a pipe so that we can read from it. Reading is
 * done on a separate thread to avoid deadlock. callback is called on
 * the main thread per line of stderr output.
 *
 * TODO: Error reporting? */
void owl_stderr_replace(void (*callback)(const char *, void *), void *cbdata)
{
  int pipefds[2];
  GError *error;
  if (0 != pipe(pipefds)) {
    perror("pipe");
    owl_function_debugmsg("stderr_replace: pipe FAILED");
    return;
  }
  owl_function_debugmsg("stderr_replace: pipe: %d,%d", pipefds[0], pipefds[1]);
  if (-1 == dup2(pipefds[1], 2 /*stderr*/)) {
    owl_function_debugmsg("stderr_replace: dup2 FAILED (%s)", strerror(errno));
    perror("dup2");
    return;
  }
  close(pipefds[1]);
  stderr_fd = pipefds[0];
  stderr_cb = callback;
  stderr_cbdata = cbdata;
  stderr_thread = g_thread_create(stderr_thread_func, NULL, FALSE, &error);
  if (stderr_thread == NULL) {
    owl_function_debugmsg("stderr_replace: g_thread_create failed: %s",
			  error->message);
    g_error_free(error);
  }
}

static gpointer stderr_thread_func(gpointer data)
{
  char buf[4096];
  FILE *file = fdopen(stderr_fd, "r");

  if (!file)
    return NULL;

  while (fgets(buf, sizeof(buf), file)) {
    int len = strlen(buf);
    /* Strip off the newline, if it's there. */
    if (len > 0 && buf[len-1] == '\n')
      buf[len-1] = '\0';
    /* Send a message to the main thread. */
    owl_select_post_task(stderr_thunk, g_strdup(buf), g_free);
  }
  return NULL;
}

static void stderr_thunk(void *data)
{
  stderr_cb(data, stderr_cbdata);
}

#endif /* OWL_STDERR_REDIR */
