#include "rmm_optimizations.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int (*original_pthread_create)(pthread_t *, const pthread_attr_t *,
                                      void *(*)(void *), void *);

static bool environment_enabled(const char *name) {
    const char *value = getenv(name);

    return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0 &&
           strcmp(value, "no") != 0;
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg) {
    if (environment_enabled(ENV_RMM_OPTIMIZATIONS_DEBUG)) {
        FILE *debug_file = fopen("/tmp/rmm_optimizations.log", "a");

        if (debug_file != NULL) {
            fprintf(debug_file, "pthread_create start=%p\n", start_routine);
            fclose(debug_file);
        }
    }

    if (environment_enabled(ENV_RMM_DISABLE_MOTION_ANALYSIS) &&
        (uintptr_t) start_routine == Y23_RMM_MOTION_THREAD_ADDRESS) {
        if (thread != NULL) {
            *thread = (pthread_t) 0;
        }
        if (environment_enabled(ENV_RMM_OPTIMIZATIONS_DEBUG)) {
            fprintf(stderr,
                    "*** [RMM_OPTIMIZATIONS] suppressed motion_proc at %p\n",
                    start_routine);
        }
        return 0;
    }

    if (original_pthread_create == NULL) {
        original_pthread_create = dlsym(RTLD_NEXT, "pthread_create");
        if (original_pthread_create == NULL) {
            if (environment_enabled(ENV_RMM_OPTIMIZATIONS_DEBUG)) {
                fprintf(stderr,
                        "*** [RMM_OPTIMIZATIONS] cannot resolve pthread_create: %s\n",
                        dlerror());
            }
            return EAGAIN;
        }
    }

    return original_pthread_create(thread, attr, start_routine, arg);
}
