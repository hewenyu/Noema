#include "CRime.h"

#include <pthread.h>
#include <string.h>

void noema_rime_traits_init(RimeTraits *traits) {
  if (!traits) return;
  memset(traits, 0, sizeof(*traits));
  RIME_STRUCT_INIT(RimeTraits, *traits);
}

void noema_rime_context_init(RimeContext *context) {
  if (!context) return;
  memset(context, 0, sizeof(*context));
  RIME_STRUCT_INIT(RimeContext, *context);
}

void noema_rime_status_init(RimeStatus *status) {
  if (!status) return;
  memset(status, 0, sizeof(*status));
  RIME_STRUCT_INIT(RimeStatus, *status);
}

void noema_rime_commit_init(RimeCommit *commit) {
  if (!commit) return;
  memset(commit, 0, sizeof(*commit));
  RIME_STRUCT_INIT(RimeCommit, *commit);
}

static pthread_once_t noema_rime_api_once = PTHREAD_ONCE_INIT;
static RimeApi *noema_rime_api_table = NULL;

static void noema_rime_api_load(void) {
  noema_rime_api_table = rime_get_api();
}

RimeApi *noema_rime_get_api(void) {
  // pthread_once publishes the table to every caller that returns from it.
  if (pthread_once(&noema_rime_api_once, noema_rime_api_load) != 0) return NULL;
  return noema_rime_api_table;
}

int noema_rime_api_available(void) {
  RimeApi *api = noema_rime_get_api();
  return api && RIME_PROVIDED(api, get_version) && RIME_PROVIDED(api, find_module) &&
         RIME_PROVIDED(api, setup) && RIME_PROVIDED(api, process_key);
}

bool noema_rime_engine_api_available(void) {
  RimeApi *api = noema_rime_get_api();
  return api && RIME_PROVIDED(api, setup) && RIME_PROVIDED(api, deployer_initialize) &&
         RIME_PROVIDED(api, deploy) && RIME_PROVIDED(api, initialize) &&
         RIME_PROVIDED(api, finalize) && RIME_PROVIDED(api, create_session) &&
         RIME_PROVIDED(api, find_session) && RIME_PROVIDED(api, destroy_session) &&
         RIME_PROVIDED(api, select_schema) && RIME_PROVIDED(api, process_key) &&
         RIME_PROVIDED(api, commit_composition) && RIME_PROVIDED(api, clear_composition) &&
         RIME_PROVIDED(api, select_candidate_on_current_page) &&
         RIME_PROVIDED(api, highlight_candidate_on_current_page) &&
         RIME_PROVIDED(api, change_page) && RIME_PROVIDED(api, get_commit) &&
         RIME_PROVIDED(api, free_commit) && RIME_PROVIDED(api, get_context) &&
         RIME_PROVIDED(api, free_context) && RIME_PROVIDED(api, get_status) &&
         RIME_PROVIDED(api, free_status) && RIME_PROVIDED(api, set_option) &&
         RIME_PROVIDED(api, get_option);
}
