#ifndef NOEMA_CRIME_H
#define NOEMA_CRIME_H

// Relative include: lets downstream Swift targets `import CRime` without extra -I flags.
// vendor-out/librime is produced by scripts/build/librime.sh.
#include <stdbool.h>
#include "../../../vendor-out/librime/include/rime_api.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

// Function-like macros in rime_api.h (RIME_STRUCT_INIT, RIME_STRUCT_CLEAR) are not
// importable into Swift; these helpers zero a struct and set its data_size.
// A NULL argument is ignored.
void noema_rime_traits_init(RimeTraits *_Nullable traits);
void noema_rime_context_init(RimeContext *_Nullable context);
void noema_rime_status_init(RimeStatus *_Nullable status);
void noema_rime_commit_init(RimeCommit *_Nullable commit);

// Thread-safe rime_get_api(). Upstream fills a function-local static table on first
// call without synchronization, so concurrent first calls race; this wrapper runs
// that first call exactly once (pthread_once) and returns the same table afterwards.
// Every Noema caller goes through this, never rime_get_api() directly.
RimeApi *_Nullable noema_rime_get_api(void);

// Returns 1 when noema_rime_get_api() yields a table that provides the members Noema calls.
int noema_rime_api_available(void);

// True when the API table provides every member RimeEngine and noema-rime-deployer call: setup, deployment,
// session lifecycle, key processing, candidate selection/paging, commit/context/status
// readers with their free functions, and option get/set.
bool noema_rime_engine_api_available(void);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
