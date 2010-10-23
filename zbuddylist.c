#include "owl.h"

void owl_zbuddylist_create(owl_zbuddylist *zb)
{
  zb->zusers = g_ptr_array_new();
}

void owl_zbuddylist_cleanup(owl_zbuddylist *zb)
{
  owl_ptr_array_free(zb->zusers, g_free);
}

int owl_zbuddylist_adduser(owl_zbuddylist *zb, const char *name)
{
  int i;
  char *user;

  user=long_zuser(name);

  for (i = 0; i < zb->zusers->len; i++) {
    if (!strcasecmp(user, zb->zusers->pdata[i])) {
      g_free(user);
      return(-1);
    }
  }
  g_ptr_array_add(zb->zusers, user);
  return(0);
}

int owl_zbuddylist_deluser(owl_zbuddylist *zb, const char *name)
{
  int i;
  char *user;

  user=long_zuser(name);

  for (i = 0; i < zb->zusers->len; i++) {
    if (!strcasecmp(user, zb->zusers->pdata[i])) {
      g_free(g_ptr_array_remove_index(zb->zusers, i));
      g_free(user);
      return(0);
    }
  }
  g_free(user);
  return(-1);
}

int owl_zbuddylist_contains_user(const owl_zbuddylist *zb, const char *name)
{
  int i;
  char *user;

  user=long_zuser(name);

  for (i = 0; i < zb->zusers->len; i++) {
    if (!strcasecmp(user, zb->zusers->pdata[i])) {
      g_free(user);
      return(1);
    }
  }
  g_free(user);
  return(0);
}
