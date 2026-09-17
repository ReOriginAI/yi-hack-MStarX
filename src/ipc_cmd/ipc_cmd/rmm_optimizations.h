#include <pthread.h>
#include <stdint.h>

#define ENV_RMM_DISABLE_MOTION_ANALYSIS "RMM_DISABLE_MOTION_ANALYSIS"
#define ENV_RMM_OPTIMIZATIONS_DEBUG "RMM_OPTIMIZATIONS_DEBUG"

/*
 * Y23 rmm SHA-256:
 * 90276937d77850e31d3ad585121d91ca1ce11e754e1c895691df54c7a4a90969
 *
 * The executable is non-PIE.  Its motion_proc entry point is a Thumb
 * function, hence the low bit in the function pointer.
 */
#define Y23_RMM_MOTION_THREAD_ADDRESS ((uintptr_t) 0x000113c5U)
