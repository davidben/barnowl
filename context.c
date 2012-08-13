#include "owl.h"

/* TODO: dependency from owl_context -> owl_window is annoying. */
CALLER_OWN owl_context *owl_context_new(int mode, void *data, const char *keymap, owl_window *cursor)
{
  owl_context *c;
  c = g_new0(owl_context, 1);
  c->mode = mode;
  c->data = data;
  c->cursor = cursor ? g_object_ref(cursor) : NULL;
  c->keymap = g_strdup(keymap);
  return c;
}

/* returns whether test matches the current context */
int owl_context_matches(const owl_context *ctx, int test)
{
  /*owl_function_debugmsg(", current: 0x%04x test: 0x%04x\n", ctx->mode, test);*/
  return (ctx->mode & test);
}

void *owl_context_get_data(const owl_context *ctx)
{
  return ctx->data;
}

int owl_context_get_mode(const owl_context *ctx)
{
  return ctx->mode;
}

void owl_context_deactivated(owl_context *ctx)
{
  if (ctx->deactivate_cb)
    ctx->deactivate_cb(ctx);
}

void owl_context_delete(owl_context *ctx)
{
  if (ctx->cursor)
    g_object_unref(ctx->cursor);
  g_free(ctx->keymap);
  if (ctx->delete_cb)
    ctx->delete_cb(ctx);
  g_free(ctx);
}
