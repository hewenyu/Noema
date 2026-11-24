#include "CRime.h"

#include <string.h>

void noema_rime_traits_init(RimeTraits *traits) {
  memset(traits, 0, sizeof(*traits));
  RIME_STRUCT_INIT(RimeTraits, *traits);
}

void noema_rime_context_init(RimeContext *context) {
  memset(context, 0, sizeof(*context));
  RIME_STRUCT_INIT(RimeContext, *context);
}

void noema_rime_status_init(RimeStatus *status) {
  memset(status, 0, sizeof(*status));
  RIME_STRUCT_INIT(RimeStatus, *status);
}

void noema_rime_commit_init(RimeCommit *commit) {
  memset(commit, 0, sizeof(*commit));
  RIME_STRUCT_INIT(RimeCommit, *commit);
}

int noema_rime_api_available(void) {
  RimeApi *api = rime_get_api();
  return RIME_PROVIDED(api, get_version) && RIME_PROVIDED(api, find_module) &&
         RIME_PROVIDED(api, setup) && RIME_PROVIDED(api, process_key);
}
