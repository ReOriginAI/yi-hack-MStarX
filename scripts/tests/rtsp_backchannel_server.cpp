// Hardware protocol fixture using the production backchannel classes.
// Output is a caller-owned file/FIFO, never the camera's playback path by default.
#include "BasicUsageEnvironment.hh"
#include "liveMedia.hh"
#include "PCMAudioFileServerMediaSubsession_BC.hh"
#include "ADTSAudioFileServerMediaSubsession_BC.hh"
#include "PCMFileSink.hh"
#include <signal.h>
#include <stdlib.h>

int debug = 0;
int main(int argc, char** argv) {
    if (argc != 3) return 2; // port, existing output file/FIFO
    signal(SIGPIPE, SIG_IGN);
    TaskScheduler* scheduler = BasicTaskScheduler::createNew();
    UsageEnvironment* env = BasicUsageEnvironment::createNew(*scheduler);
    RTSPServer* server = RTSPServer::createNew(*env, atoi(argv[1]), NULL, 5);
    if (server == NULL) return 1;
    const char* names[] = {"pcmu", "pcma", "aac"};
    for (int i = 0; i < 3; ++i) {
        ServerMediaSession* session = ServerMediaSession::createNew(*env, names[i], names[i]);
        if (i == 2)
            session->addSubsession(ADTSAudioFileServerMediaSubsession_BC::createNew(
                *env, argv[2], True, 16000, 1));
        else
            session->addSubsession(PCMAudioFileServerMediaSubsession_BC::createNew(
                *env, argv[2], True, 16000, 1, i == 0 ? ULAW : ALAW));
        server->addServerMediaSession(session);
    }
    env->taskScheduler().doEventLoop();
    return 0;
}
