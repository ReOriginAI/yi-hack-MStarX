#include "ipc_multiplex.h"

// May be set to true using the "IPC_MULTIPLEX_DEBUG" environment
// variable for debugging purposes.
bool debug = false;

// Drop the known RMM-to-Yi-cloud detection/event messages. This remains
// disabled unless explicitly requested by the disabled-cloud startup path.
bool drop_cloud_events = false;

// True if message queue and function pointer were initialized.
bool is_initialized = false;

// The message queue onto which all messages will be forwarded.
mqd_t ipc_mq[10];
bool ipc_mq_enabled[10];

// The original mq_receive function.
ssize_t (*original_mq_receive)(mqd_t, char*, size_t, unsigned int*);

static void configure_mirror_queues() {
    const char *queue_config = getenv(ENV_IPC_MULTIPLEX_QUEUES);
    bool any_enabled = false;
    int i;

    memset(ipc_mq_enabled, 0, sizeof(ipc_mq_enabled));

    // Preserve the historical full fan-out when no explicit configuration is
    // supplied. A value such as "2" or "1,2" enables only those queues.
    if (queue_config == NULL || queue_config[0] == '\0' || strcmp(queue_config, "all") == 0) {
        for (i = 1; i < 10; i++) {
            ipc_mq_enabled[i] = true;
        }
        return;
    }

    for (; *queue_config != '\0'; queue_config++) {
        if (*queue_config >= '1' && *queue_config <= '9') {
            ipc_mq_enabled[*queue_config - '0'] = true;
            any_enabled = true;
        }
    }

    // Invalid configuration fails open to the established diagnostic mode.
    if (!any_enabled) {
        for (i = 1; i < 10; i++) {
            ipc_mq_enabled[i] = true;
        }
    }
}

static bool is_cloud_event(const char *msg_ptr, ssize_t msg_len) {
    uint32_t target;
    uint32_t source;
    uint16_t main_op;
    uint16_t sub_op;

    if (!drop_cloud_events || msg_len < 16) {
        return false;
    }

    memcpy(&target, &(msg_ptr[MESSAGE_TARGET_OFFSET]), sizeof(target));
    memcpy(&source, &(msg_ptr[MESSAGE_SOURCE_OFFSET]), sizeof(source));
    memcpy(&main_op, &(msg_ptr[MESSAGE_MAIN_OP_OFFSET]), sizeof(main_op));
    memcpy(&sub_op, &(msg_ptr[MESSAGE_SUB_OP_OFFSET]), sizeof(sub_op));

    if (target != MESSAGE_ID_CLOUD || source != MESSAGE_ID_RMM || main_op != sub_op) {
        return false;
    }

    switch (main_op) {
        case 0x7006: // body/person detection
        case 0x7007: // vehicle detection
        case 0x7008: // animal detection
        case 0x7009: // motion detection
        case 0x6002: // baby crying
        case 0x6004: // abnormal sound
            return true;
        default:
            return false;
    }
}

static void debug_message(const char *prefix, const char *msg_ptr, ssize_t msg_len) {
    int i;

    if (!debug) {
        return;
    }

    fprintf(stderr, "*** [IPC_MULTIPLEX] %s", prefix);
    for (i = 0; i < msg_len; i++) {
        fprintf(stderr, "%02x ", (unsigned char) msg_ptr[i]);
    }
    fprintf(stderr, "\n");
}

/**
* Initializes the ipc_dispatch_x message queues and looks up the
* original mq_receive function.
**/
void ipc_multiplex_initialize() {

    int i;

    // Enable debug mode if requested
    if (getenv(ENV_IPC_MULTIPLEX_DEBUG)) {
        debug = true;
    }
    if (getenv(ENV_IPC_DROP_CLOUD_EVENTS) && strcmp(getenv(ENV_IPC_DROP_CLOUD_EVENTS), "0") != 0) {
        drop_cloud_events = true;
    }

    configure_mirror_queues();

    // Prepare attributes for opening message queues.
    struct mq_attr attr = {
        .mq_flags = 0,
        .mq_maxmsg = 64,
        .mq_msgsize = IPC_MESSAGE_MAX_SIZE,
        .mq_curmsgs = 0
    };

    char queue_name[64];
    for (i = 1; i < 10; i++) {
        if (!ipc_mq_enabled[i]) {
            continue;
        }
        sprintf(queue_name, "%s_%d", IPC_QUEUE_NAME, i);

        // Open the message queue or create a new one if it does not exist
        ipc_mq[i] = mq_open(queue_name, O_RDWR | O_CREAT | O_NONBLOCK, 0644, &attr);
        if(ipc_mq[i] == INVALID_QUEUE) {
            fprintf(stderr, "*** [IPC_MULTIPLEX] Can't open mqueue %s. Error: %s\n", queue_name, strerror(errno));
            exit(EXIT_FAILURE);
        }
    }

    // Find original mq_receive symbol and store it for later usage
    original_mq_receive = dlsym(RTLD_NEXT, "mq_receive");
    if (original_mq_receive == NULL) {
        fprintf(stderr, "*** [IPC_MULTIPLEX] Can't resolve mq_receive\n");
        exit(EXIT_FAILURE);
    }

    // Remember this function was called.
    is_initialized = true;
}

/**
* Extracts the message's target.
*/
inline unsigned int get_message_target(char *msg_ptr) {
    return *((unsigned int*) &(msg_ptr[MESSAGE_TARGET_OFFSET]));
}

/**
* First, calls the original mq_receive function and then forwards the received
* message onto the ipc_dispatch_x message queues.
**/
ssize_t mq_receive(mqd_t mqdes, char *msg_ptr, size_t msg_len, unsigned int *msg_prio) {

    int i;
    ssize_t bytes_read;

    // Initialize resources on first call.
    if (is_initialized == false) {
        ipc_multiplex_initialize();
    }

    // Consume confirmed cloud-only event packets without returning them to
    // dispatch. All other messages retain the original receive semantics.
    do {
        bytes_read = original_mq_receive(mqdes, msg_ptr, msg_len, msg_prio);
        if (bytes_read <= 0) {
            return bytes_read;
        }
        if (is_cloud_event(msg_ptr, bytes_read)) {
            debug_message("dropped cloud event: ", msg_ptr, bytes_read);
            continue;
        }
        break;
    } while (true);

    debug_message("", msg_ptr, bytes_read);

    // Filter out messages not targeted at the ipc_dispatch queue.
//    if (get_message_target(msg_ptr) != MESSAGE_ID_IPC_DISPATCH) {
//        return bytes_read;
//    }

    // Resend the received message to the dispatch queues
    for (i = 1; i < 10; i++) {
        if (!ipc_mq_enabled[i]) {
            continue;
        }

        // mq_send will fail with EAGAIN whenever the target message queue is full.
        if (mq_send(ipc_mq[i], msg_ptr, bytes_read, MESSAGE_PRIORITY) != 0 && errno != EAGAIN) {
            fprintf(stderr, "*** [IPC_MULTIPLEX] Resending message to %s_%d queue failed. error = %s\n", IPC_QUEUE_NAME, i, strerror(errno));
        };
    }

    // Return like the original function would do
    return bytes_read;
}
