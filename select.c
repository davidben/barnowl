#include "owl.h"

static bool loop_active;

void owl_select_init(void)
{
}

void owl_select_run_loop(void)
{
  GMainContext *context = g_main_context_default();
  if (loop_active) {
    owl_function_error("owl_select_run_loop called recursively!");
    return;
  }
  /* Drive the loop ourselves so that we can properly savetmps/freetmps around
   * each iteration. */
  loop_active = true;
  while (loop_active) {
    owl_perl_savetmps();
    g_main_context_iteration(context, TRUE);
    owl_perl_freetmps();
  }
}

void owl_select_quit_loop(void)
{
  loop_active = false;
}

typedef struct _owl_task { /*noproto*/
  void (*cb)(void *);
  void *cbdata;
  void (*destroy_cbdata)(void *);
} owl_task;

static gboolean _run_task(gpointer data)
{
  owl_task *t = data;
  if (t->cb)
    t->cb(t->cbdata);
  return FALSE;
}

static void _destroy_task(void *data)
{
  owl_task *t = data;
  if (t->destroy_cbdata)
    t->destroy_cbdata(t->cbdata);
  g_free(t);
}

void owl_select_post_task(void (*cb)(void*), void *cbdata, void (*destroy_cbdata)(void*), GMainContext *context)
{
  GSource *source = g_idle_source_new();
  owl_task *t = g_new0(owl_task, 1);
  t->cb = cb;
  t->cbdata = cbdata;
  t->destroy_cbdata = destroy_cbdata;
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, _run_task, t, _destroy_task);
  g_source_attach(source, context);
  g_source_unref(source);
}
