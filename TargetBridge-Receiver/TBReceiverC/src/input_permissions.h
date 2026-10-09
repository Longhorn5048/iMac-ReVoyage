#ifndef TB_INPUT_PERMISSIONS_H
#define TB_INPUT_PERMISSIONS_H

#include <stdbool.h>
#include <dlfcn.h>

typedef bool (*tb_listen_access_preflight)(void);

/* Some Catalina 10.15.7 builds do not export this symbol despite the SDK's
 * availability declaration. Never bind it directly, or dyld aborts at launch.
 * Missing APIs must fail closed; the existing SDL window input fallback still
 * works without granting global event monitoring. */
static inline int tb_listen_access_check(tb_listen_access_preflight preflight) {
    return preflight && preflight() ? 1 : 0;
}

static inline int tb_input_monitoring_trusted(void) {
    static tb_listen_access_preflight preflight;
    static int resolved;
    if (!resolved) {
        preflight = (tb_listen_access_preflight)dlsym(RTLD_DEFAULT, "CGPreflightListenEventAccess");
        resolved = 1;
    }
    return tb_listen_access_check(preflight);
}

#endif
