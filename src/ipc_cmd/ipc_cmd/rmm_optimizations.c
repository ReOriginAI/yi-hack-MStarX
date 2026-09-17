#include "rmm_optimizations.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int (*original_pthread_create)(pthread_t *, const pthread_attr_t *,
                                      void *(*)(void *), void *);

struct mapped_thread_start {
    void *(*start_routine)(void *);
    void *arg;
};

static bool environment_enabled(const char *name) {
    const char *value = getenv(name);

    return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0 &&
           strcmp(value, "no") != 0;
}

static void append_thread_map(long tid, void *(*start_routine)(void *)) {
    FILE *debug_file = fopen("/tmp/rmm_optimizations.log", "a");

    if (debug_file != NULL) {
        fprintf(debug_file, "thread_start tid=%ld start=%p\n", tid,
                start_routine);
        fclose(debug_file);
    }
}

static void *mapped_thread_trampoline(void *opaque) {
    struct mapped_thread_start *mapped = opaque;
    void *(*start_routine)(void *) = mapped->start_routine;
    void *arg = mapped->arg;
    long tid = syscall(SYS_gettid);

    free(mapped);
    append_thread_map(tid, start_routine);

    return start_routine(arg);
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

    if (environment_enabled(ENV_RMM_OPTIMIZATIONS_THREAD_MAP)) {
        struct mapped_thread_start *mapped = malloc(sizeof(*mapped));

        if (mapped != NULL) {
            mapped->start_routine = start_routine;
            mapped->arg = arg;
            return original_pthread_create(thread, attr,
                                           mapped_thread_trampoline, mapped);
        }
    }

    return original_pthread_create(thread, attr, start_routine, arg);
}
