#ifndef NOEMA_CRIME_H
#define NOEMA_CRIME_H

// Relative include: lets downstream Swift targets `import CRime` without extra -I flags.
// vendor-out/librime is produced by scripts/build/librime.sh.
#include "../../../vendor-out/librime/include/rime_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// Function-like macros in rime_api.h (RIME_STRUCT_INIT, RIME_STRUCT_CLEAR) are not
// importable into Swift; these helpers zero a struct and set its data_size.
void noema_rime_traits_init(RimeTraits *traits);
void noema_rime_context_init(RimeContext *context);
void noema_rime_status_init(RimeStatus *status);
void noema_rime_commit_init(RimeCommit *commit);

// Returns 1 when rime_get_api() yields a table that provides the members Noema calls.
int noema_rime_api_available(void);

#ifdef __cplusplus
}
#endif

#endif
