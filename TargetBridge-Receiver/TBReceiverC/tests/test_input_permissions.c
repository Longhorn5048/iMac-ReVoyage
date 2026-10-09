#include <stdbool.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int resolution_calls, missing_api;
static bool fake_permission;
static bool fake_preflight(void) { return fake_permission; }
static void *fake_dlsym(void *handle, const char *name) {
    assert(handle == RTLD_DEFAULT);
    assert(strcmp(name, "CGPreflightListenEventAccess") == 0);
    resolution_calls++;
    return missing_api ? NULL : (void *)fake_preflight;
}
#define dlsym fake_dlsym
#include "input_permissions.h"
#undef dlsym

static int calls;
static bool allowed(void) { calls++; return true; }
static bool denied(void) { calls++; return false; }

int main(void) {
    /* Reproduce the affected Catalina's missing API without using live input
     * permissions, creating an event tap, or changing system settings. */
    assert(tb_listen_access_check(NULL) == 0 && calls == 0);
    assert(tb_listen_access_check(denied) == 0 && calls == 1);
    assert(tb_listen_access_check(allowed) == 1 && calls == 2);
    for (int absent = 0; absent <= 1; absent++) {
        /* Separate processes give each simulated OS a fresh resolution cache. */
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            missing_api = absent;
            fake_permission = false;
            assert(tb_input_monitoring_trusted() == 0);
            fake_permission = true;
            assert(tb_input_monitoring_trusted() == !absent);
            fake_permission = false;
            assert(tb_input_monitoring_trusted() == 0);
            assert(resolution_calls == 1);
            _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("input permissions: missing API and denied permission fail closed; granted permission allowed");
    return 0;
}
