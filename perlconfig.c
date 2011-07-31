#define OWL_PERL
#include "owl.h"
#include <stdio.h>

extern XS(boot_BarnOwl);
extern XS(boot_DynaLoader);
/* extern XS(boot_DBI); */

void owl_perl_xs_init(pTHX) /* noproto */
{
  const char *file = __FILE__;
  dXSUB_SYS;
  {
    newXS("BarnOwl::bootstrap", boot_BarnOwl, file);
    newXS("DynaLoader::boot_DynaLoader", boot_DynaLoader, file);
  }
}


CALLER_OWN SV *owl_new_sv(const char * str)
{
  SV *ret = newSVpv(str, 0);
  if (is_utf8_string((const U8 *)str, strlen(str))) {
    SvUTF8_on(ret);
  } else {
    char *escape = owl_escape_highbit(str);
    owl_function_error("Internal error! Non-UTF-8 string encountered:\n%s", escape);
    g_free(escape);
  }
  return ret;
}

CALLER_OWN AV *owl_new_av(const GPtrArray *l, SV *(*to_sv)(const void *))
{
  AV *ret;
  int i;
  void *element;

  ret = newAV();

  for (i = 0; i < l->len; i++) {
    element = l->pdata[i];
    av_push(ret, to_sv(element));
  }

  return ret;
}

CALLER_OWN HV *owl_new_hv(const owl_dict *d, SV *(*to_sv)(const void *))
{
  HV *ret;
  GPtrArray *keys;
  const char *key;
  void *element;
  int i;

  ret = newHV();

  /* TODO: add an iterator-like interface to owl_dict */
  keys = owl_dict_get_keys(d);
  for (i = 0; i < keys->len; i++) {
    key = keys->pdata[i];
    element = owl_dict_find_element(d, key);
    (void)hv_store(ret, key, strlen(key), to_sv(element), 0);
  }
  owl_ptr_array_free(keys, g_free);

  return ret;
}

CALLER_OWN SV *owl_perlconfig_message2hashref(const owl_message *m)
{
  return SvREFCNT_inc(m);
}

CALLER_OWN SV *owl_perlconfig_curmessage2hashref(void)
{
  owl_message *m = owl_global_get_current_message(&g);
  if(m == NULL) {
    return &PL_sv_undef;
  }
  return owl_perlconfig_message2hashref(m);
}

CALLER_OWN owl_message * owl_perlconfig_hashref2message(SV *msg)
{
  return (owl_message*)SvREFCNT_inc(msg);
}

/* Calls in a scalar context, passing it a hash reference.
   If return value is non-null, caller must free. */
CALLER_OWN char *owl_perlconfig_call_with_message(const char *subname, const owl_message *m)
{
  dSP ;
  int count;
  SV *msgref, *srv;
  char *out;
  
  ENTER ;
  SAVETMPS;
  
  PUSHMARK(SP) ;
  msgref = owl_perlconfig_message2hashref(m);
  XPUSHs(sv_2mortal(msgref));
  PUTBACK ;
  
  count = call_pv(subname, G_SCALAR|G_EVAL);
  
  SPAGAIN ;

  if (SvTRUE(ERRSV)) {
    owl_function_error("Perl Error: '%s'", SvPV_nolen(ERRSV));
    /* and clear the error */
    sv_setsv (ERRSV, &PL_sv_undef);
  }

  if (count != 1) {
    fprintf(stderr, "bad perl!  no biscuit!  returned wrong count!\n");
    abort();
  }

  srv = POPs;

  if (srv) {
    out = g_strdup(SvPV_nolen(srv));
  } else {
    out = NULL;
  }
  
  PUTBACK ;
  FREETMPS ;
  LEAVE ;

  return out;
}


/* Calls a method on a perl object representing a message.
   If the return value is non-null, the caller must free it.
 */
CALLER_OWN char *owl_perlconfig_message_call_method(const owl_message *m, const char *method, int argc, const char **argv)
{
  dSP;
  unsigned int count, i;
  SV *msgref, *srv;
  char *out;

  msgref = owl_perlconfig_message2hashref(m);

  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  XPUSHs(sv_2mortal(msgref));
  for(i=0;i<argc;i++) {
    XPUSHs(sv_2mortal(owl_new_sv(argv[i])));
  }
  PUTBACK;

  count = call_method(method, G_SCALAR|G_EVAL);

  SPAGAIN;

  if(count != 1) {
    fprintf(stderr, "perl returned wrong count %u\n", count);
    abort();
  }

  if (SvTRUE(ERRSV)) {
    owl_function_error("Error: '%s'", SvPV_nolen(ERRSV));
    /* and clear the error */
    sv_setsv (ERRSV, &PL_sv_undef);
  }

  srv = POPs;

  if (srv) {
    out = g_strdup(SvPV_nolen(srv));
  } else {
    out = NULL;
  }

  PUTBACK;
  FREETMPS;
  LEAVE;

  return out;
}

/* caller must free result, if not NULL */
CALLER_OWN char *owl_perlconfig_initperl(const char *file, int *Pargc, char ***Pargv, char ***Penv)
{
  int ret;
  PerlInterpreter *p;
  char *err;
  const char *args[4] = {"", "-e", "0;", NULL};
  AV *inc;
  char *path;

  /* create and initialize interpreter */
  PERL_SYS_INIT3(Pargc, Pargv, Penv);
  p=perl_alloc();
  owl_global_set_perlinterp(&g, p);
  perl_construct(p);

  PL_exit_flags |= PERL_EXIT_DESTRUCT_END;

  owl_global_set_no_have_config(&g);

  ret=perl_parse(p, owl_perl_xs_init, 2, (char **)args, NULL);
  if (ret || SvTRUE(ERRSV)) {
    err=g_strdup(SvPV_nolen(ERRSV));
    sv_setsv(ERRSV, &PL_sv_undef);     /* and clear the error */
    return(err);
  }

  ret=perl_run(p);
  if (ret || SvTRUE(ERRSV)) {
    err=g_strdup(SvPV_nolen(ERRSV));
    sv_setsv(ERRSV, &PL_sv_undef);     /* and clear the error */
    return(err);
  }

  owl_global_set_have_config(&g);

  /* create legacy variables */
  get_sv("BarnOwl::id", TRUE);
  get_sv("BarnOwl::class", TRUE);
  get_sv("BarnOwl::instance", TRUE);
  get_sv("BarnOwl::recipient", TRUE);
  get_sv("BarnOwl::sender", TRUE);
  get_sv("BarnOwl::realm", TRUE);
  get_sv("BarnOwl::opcode", TRUE);
  get_sv("BarnOwl::zsig", TRUE);
  get_sv("BarnOwl::msg", TRUE);
  get_sv("BarnOwl::time", TRUE);
  get_sv("BarnOwl::host", TRUE);
  get_av("BarnOwl::fields", TRUE);

  if(file) {
    SV * cfg = get_sv("BarnOwl::configfile", TRUE);
    sv_setpv(cfg, file);
  }

  sv_setpv(get_sv("BarnOwl::VERSION", TRUE), OWL_VERSION_STRING);

  /* Add the system lib path to @INC */
  inc = get_av("INC", 0);
  path = g_build_filename(owl_get_datadir(), "lib", NULL);
  av_unshift(inc, 1);
  av_store(inc, 0, owl_new_sv(path));
  g_free(path);

  eval_pv("use BarnOwl;", FALSE);

  if (SvTRUE(ERRSV)) {
    err=g_strdup(SvPV_nolen(ERRSV));
    sv_setsv (ERRSV, &PL_sv_undef);     /* and clear the error */
    return(err);
  }

  /* check if we have the formatting function */
  if (owl_perlconfig_is_function("BarnOwl::format_msg")) {
    owl_global_set_config_format(&g, 1);
  }

  return(NULL);
}

/* returns whether or not a function exists */
int owl_perlconfig_is_function(const char *fn) {
  if (get_cv(fn, FALSE)) return(1);
  else return(0);
}

/* caller is responsible for freeing returned string */
CALLER_OWN char *owl_perlconfig_execute(const char *line)
{
  STRLEN len;
  SV *response;
  char *out;

  if (!owl_global_have_config(&g)) return NULL;

  ENTER;
  SAVETMPS;
  /* execute the subroutine */
  response = eval_pv(line, FALSE);

  if (SvTRUE(ERRSV)) {
    owl_function_error("Perl Error: '%s'", SvPV_nolen(ERRSV));
    sv_setsv (ERRSV, &PL_sv_undef);     /* and clear the error */
  }

  out = g_strdup(SvPV(response, len));
  FREETMPS;
  LEAVE;

  return(out);
}

void owl_perlconfig_getmsg(const owl_message *m, const char *subname)
{
  char *ptr = NULL;
  if (owl_perlconfig_is_function("BarnOwl::Hooks::_receive_msg")) {
    ptr = owl_perlconfig_call_with_message(subname?subname
                                           :"BarnOwl::_receive_msg_legacy_wrap", m);
  }
  g_free(ptr);
}

/* Called on all new messages; receivemsg is only called on incoming ones */
void owl_perlconfig_newmsg(const owl_message *m, const char *subname)
{
  char *ptr = NULL;
  if (owl_perlconfig_is_function("BarnOwl::Hooks::_new_msg")) {
    ptr = owl_perlconfig_call_with_message(subname?subname
                                           :"BarnOwl::Hooks::_new_msg", m);
  }
  g_free(ptr);
}

void owl_perlconfig_new_command(const char *name)
{
  dSP;

  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  XPUSHs(sv_2mortal(owl_new_sv(name)));
  PUTBACK;

  call_pv("BarnOwl::Hooks::_new_command", G_VOID|G_EVAL);

  SPAGAIN;

  if(SvTRUE(ERRSV)) {
    owl_function_error("%s", SvPV_nolen(ERRSV));
  }

  FREETMPS;
  LEAVE;
}

/* caller must free the result */
CALLER_OWN char *owl_perlconfig_perlcmd(const owl_cmd *cmd, int argc, const char *const *argv)
{
  int i, count;
  char * ret = NULL;
  SV *rv;
  dSP;

  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  for(i=0;i<argc;i++) {
    XPUSHs(sv_2mortal(owl_new_sv(argv[i])));
  }
  PUTBACK;

  count = call_sv(cmd->cmd_perl, G_SCALAR|G_EVAL);

  SPAGAIN;

  if(SvTRUE(ERRSV)) {
    owl_function_error("%s", SvPV_nolen(ERRSV));
    (void)POPs;
  } else {
    if(count != 1)
      croak("Perl command %s returned more than one value!", cmd->name);
    rv = POPs;
    if(SvTRUE(rv)) {
      ret = g_strdup(SvPV_nolen(rv));
    }
  }

  FREETMPS;
  LEAVE;

  return ret;
}

void owl_perlconfig_cmd_cleanup(owl_cmd *cmd)
{
  SvREFCNT_dec(cmd->cmd_perl);
}

void owl_perlconfig_edit_callback(owl_editwin *e)
{
  SV *cb = owl_editwin_get_cbdata(e);
  SV *text;
  dSP;

  if(cb == NULL) {
    owl_function_error("Perl callback is NULL!");
    return;
  }
  text = owl_new_sv(owl_editwin_get_text(e));

  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  XPUSHs(sv_2mortal(text));
  PUTBACK;
  
  call_sv(cb, G_DISCARD|G_EVAL);

  if(SvTRUE(ERRSV)) {
    owl_function_error("%s", SvPV_nolen(ERRSV));
  }

  FREETMPS;
  LEAVE;
}

void owl_perlconfig_dec_refcnt(void *data)
{
  SV *v = data;
  SvREFCNT_dec(v);
}

SV * owl_perl_new(const char *class)
{
  return owl_perl_new_argv(class, NULL, 0);
}

SV * owl_perl_new_argv(const char *class, const char **argv, int argc)
{
  SV *obj;
  int i;
  OWL_PERL_CALL_METHOD(sv_2mortal(newSVpv(class, 0)), "new",
                       for(i=0;i<argc;i++) {
                         XPUSHs(sv_2mortal(newSVpv(argv[i], 0)));
                       }
                       ,
                       "Error in perl: %s\n",
                       1,
                       obj = POPs;
                       SvREFCNT_inc(obj);
                       );
  return obj;
}

void owl_perl_savetmps(void) {
  ENTER;
  SAVETMPS;
}

void owl_perl_freetmps(void) {
  FREETMPS;
  LEAVE;
}

void owl_perlconfig_invalidate_filter(owl_filter *f)
{
  dSP;
  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVpv(owl_filter_get_name(f), 0)));
  PUTBACK;

  call_pv("BarnOwl::Hooks::_invalidate_filter", G_DISCARD|G_EVAL);

  FREETMPS;
  LEAVE;
}

char *owl_perlconfig_do_sepbar(void)
{
  char *out;
  SV *rv;

  dSP;
  ENTER;
  SAVETMPS;

  PUSHMARK(SP);

  call_pv("BarnOwl::Hooks::_do_sepbar", G_EVAL|G_SCALAR);

  SPAGAIN;

  rv = POPs;

  if (rv) {
    out = g_strdup(SvPV_nolen(rv));
  } else {
    out = NULL;
  }

  FREETMPS;
  LEAVE;

  return out;
}
