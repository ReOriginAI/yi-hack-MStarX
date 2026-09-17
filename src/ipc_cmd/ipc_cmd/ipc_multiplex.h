#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <mqueue.h>
#include <dlfcn.h>

#define IPC_QUEUE_NAME          "/ipc_dispatch"
#define ENV_IPC_MULTIPLEX_DEBUG "IPC_MULTIPLEX_DEBUG"
#define ENV_IPC_MULTIPLEX_QUEUES "IPC_MULTIPLEX_QUEUES"
#define ENV_IPC_DROP_CLOUD_EVENTS "IPC_MULTIPLEX_DROP_CLOUD_EVENTS"
#define IPC_MESSAGE_MAX_SIZE    512
#define MESSAGE_PRIORITY        1
#define INVALID_QUEUE           -1
#define MESSAGE_TARGET_OFFSET   0
#define MESSAGE_SOURCE_OFFSET   4
#define MESSAGE_MAIN_OP_OFFSET  8
#define MESSAGE_SUB_OP_OFFSET   10
#define MESSAGE_ID_IPC_DISPATCH 1
#define MESSAGE_ID_RMM          2
#define MESSAGE_ID_CLOUD        4
