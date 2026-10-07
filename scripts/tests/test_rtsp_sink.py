#!/usr/bin/env python3
"""Exercise the real PCM sink against a small live555 I/O shim on the host."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    source = ROOT / 'src/rRTSPServer'
    for name in ('PCMFileSink.hh', 'SpeakerLock.hh'):
        text = (source / 'include' / name).read_text().replace('/tmp/yi-speaker.lock', str(folder / 'lock'))
        (folder / name).write_text(text)
    (folder / 'GroupsockHelper.hh').write_text('')
    (folder / 'OutputFile.hh').write_text('')
    (folder / 'uLawAudioFilter.hh').write_text('')
    (folder / 'aLawAudioFilter.hh').write_text('')
    (folder / 'FileSink.hh').write_text(r'''
#ifndef TEST_FILE_SINK_HH
#define TEST_FILE_SINK_HH
#include <stdint.h>
#include <sys/types.h>
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
typedef bool Boolean;
const Boolean True = true, False = false;
struct UsageEnvironment { void setResultMsg(const char*) {} };
struct TestSource { void stopGettingFrames() {} };
class FileSink {
public:
 FileSink(UsageEnvironment&, FILE* fid, unsigned size, void*)
  : fOutFid(fid), fBufferSize(size), fBuffer(new unsigned char[size]), fSource(NULL) {}
 virtual ~FileSink() { if (fOutFid) fclose(fOutFid); delete[] fBuffer; }
 virtual Boolean continuePlaying() { return True; }
 void onSourceClosure() {}
protected:
 FILE* fOutFid; unsigned fBufferSize; unsigned char* fBuffer; TestSource* fSource;
};
#endif
''')
    (folder / 'test.cpp').write_text(r'''
#include "PCMFileSink.hh"
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
extern int yiSpeakerBusy;
class SinkAccess: public PCMFileSink {
public: static void close(PCMFileSink* sink) { delete static_cast<FileSink*>(sink); }
};
int main(int, char** argv) {
 signal(SIGPIPE, SIG_IGN);
 UsageEnvironment env;
 const char* fifo = argv[1];
 assert(mkfifo(fifo, 0600) == 0);
 // Neither a missing endpoint nor an unread FIFO may block SETUP or retain lock.
 assert(PCMFileSink::createNew(env, fifo, 16000, ULAW) == NULL);
 assert(yiSpeakerBusy == 0);
 assert(PCMFileSink::createNew(env, argv[2], 16000, ULAW) == NULL);
 int reader = open(fifo, O_RDONLY|O_NONBLOCK);
 assert(reader >= 0);
 PCMFileSink* sink = PCMFileSink::createNew(env, fifo, 16000, ULAW);
 assert(sink && yiSpeakerBusy);
 pid_t child = fork();
 assert(child >= 0);
 if (child == 0) {
  yiSpeakerBusy = 0; // Only the parent owns the kernel record lock.
  assert(PCMFileSink::createNew(env, fifo, 16000, ULAW) == NULL);
  _exit(0);
 }
 int status = 0;
 assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
 assert(PCMFileSink::createNew(env, fifo, 16000, ULAW) == NULL);
 // Discovery succeeds while another playback owns the lock; it cannot release it.
 PCMFileSink* preview = PCMFileSink::createNew(env, argv[2], 16000, ULAW, 8192, True);
 assert(preview);
 SinkAccess::close(preview);
 assert(yiSpeakerBusy);
 unsigned char silence[160];
 for (unsigned i=0; i<sizeof silence; ++i) silence[i] = 0xff;
 sink->addData(silence, sizeof silence, timeval());
 unsigned char output[1024];
 assert(read(reader, output, sizeof output) == 640); // 20 ms at 16k mono PCM16
 for (unsigned i=0; i<640; ++i) assert(output[i] == 0);
 // A full FIFO is best-effort, and reader loss does not kill the process.
 for (int i=0; i<1000; ++i) sink->addData(silence, sizeof silence, timeval());
 close(reader);
 sink->addData(silence, sizeof silence, timeval());
 SinkAccess::close(sink);
 assert(yiSpeakerBusy == 0);
 reader = open(fifo, O_RDONLY|O_NONBLOCK);
 sink = PCMFileSink::createNew(env, fifo, 16000, ALAW);
 assert(sink);
 for (unsigned i=0; i<sizeof silence; ++i) silence[i] = 0x55; // negative A-law
 sink->addData(silence, sizeof silence, timeval());
 assert(read(reader, output, sizeof output) == 640);
 const int16_t* samples = (const int16_t*)output;
 for (unsigned i=0; i<320; ++i) assert(samples[i] < 0 && samples[i] >= -16);
 SinkAccess::close(sink); close(reader);
 return 0;
}
''')
    executable = folder / 'sink-test'
    subprocess.run(['c++', '-std=c++11', '-Wall', '-Wextra', '-Wno-unused-parameter', '-I'+str(folder),
                    str(source / 'src/PCMFileSink.cpp'), str(folder / 'test.cpp'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(folder / 'fifo'), str(folder / 'missing')], check=True, timeout=5)
print('PASS: native PCM sink preview/exclusion, 8k-to-16k silence, missing/full FIFO, reader loss, lock release')
