#ifndef YI_SPEAKER_LOCK_HH
#define YI_SPEAKER_LOCK_HH
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
// Same kernel-owned lock as the speaker helper; released on process death.
extern int yiSpeakerBusy;
static int acquireSpeakerLock() {
    if (yiSpeakerBusy) return -1;
    int fd = open("/tmp/yi-speaker.lock", O_RDWR|O_CREAT, 0600);
    if (fd < 0) return -1;
    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = F_WRLCK;
    lock.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLK, &lock) < 0) { close(fd); return -1; }
    yiSpeakerBusy = 1;
    return fd;
}
// A missing FIFO reader must not block the RTSP event loop during SETUP.
static FILE* openSpeakerOutput(char const* path) {
    int fd = open(path, O_WRONLY|O_NONBLOCK);
    if (fd < 0) return NULL;
    FILE* output = fdopen(fd, "wb");
    if (output == NULL) close(fd);
    return output;
}
#endif
