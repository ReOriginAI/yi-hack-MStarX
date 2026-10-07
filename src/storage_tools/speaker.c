/* MStar TinyALSA speaker FIFO: S16LE / 16 kHz / mono.
 * Streaming G711 input is PCMU / 8 kHz, expanded to 16 kHz. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop_signal(int sig) { (void)sig; stopped=1; }
static unsigned le16(const unsigned char *p) { return p[0]|(p[1]<<8); }
static unsigned le32(const unsigned char *p) { return le16(p)|(le16(p+2)<<16); }
static int ulaw(unsigned char b)
{
    int value; b=~b;
    value=(((b&15)<<3)+132)<<((b>>4)&7);
    return (b&128) ? 132-value : value-132;
}

static int lock_speaker(void)
{
    struct flock lock; int fd=open("/tmp/yi-speaker.lock",O_RDWR|O_CREAT,0600);
    if (fd<0) return -1;
    memset(&lock,0,sizeof(lock)); lock.l_type=F_WRLCK; lock.l_whence=SEEK_SET;
    if (fcntl(fd,F_SETLK,&lock)) { close(fd); return -1; }
    return fd; /* kernel releases this lock on exit, including SIGKILL */
}

static int cancel_speaker(void)
{
    struct flock lock; char path[64],name[32]; FILE *f;
    int fd=open("/tmp/yi-speaker.lock",O_RDWR);
    if (fd<0) return 0;
    memset(&lock,0,sizeof(lock)); lock.l_type=F_WRLCK; lock.l_whence=SEEK_SET;
    if (fcntl(fd,F_GETLK,&lock)) { close(fd); return 1; }
    close(fd); if (lock.l_type==F_UNLCK) return 0;
    snprintf(path,sizeof(path),"/proc/%ld/comm",(long)lock.l_pid);
    f=fopen(path,"r"); if (!f) return 1;
    if (!fgets(name,sizeof(name),f)) { fclose(f); return 1; }
    fclose(f);
    /* Do not cancel a legacy RTSP daemon using the same playback lock. */
    if (strcmp(name,"speaker\n")) return 1;
    return kill(lock.l_pid,SIGTERM) ? 1 : 0;
}

static int write_pcm(int fd, unsigned char *p, size_t n)
{
    struct pollfd pollfd={fd,POLLOUT,0};
    while (n && !stopped) {
        ssize_t written=write(fd,p,n);
        if (written>0) { p+=written; n-=written; }
        else if (written<0 && errno==EINTR) continue;
        else if (written<0 && errno==EAGAIN) {
            if (poll(&pollfd,1,2000)<=0) return 1;
        } else return 1;
    }
    return n ? 1 : 0;
}

static int wav_data(FILE *f, long *remaining, int *rate)
{
    unsigned char h[16]; long end; int fmt=0;
    if (fseek(f,0,SEEK_END) || (end=ftell(f))<12 || end>(4L<<20) || fseek(f,0,SEEK_SET)) return 1;
    if (fread(h,1,12,f)!=12 || memcmp(h,"RIFF",4) || memcmp(h+8,"WAVE",4) || le32(h+4)+8UL!=(unsigned long)end) return 1;
    while (ftell(f)+8<=end) {
        unsigned size; long next;
        if (fread(h,1,8,f)!=8) return 1;
        size=le32(h+4); next=ftell(f)+size+(size&1);
        if (next>end) return 1;
        if (!memcmp(h,"fmt ",4)) {
            if (fmt || size<16 || fread(h,1,16,f)!=16 || le16(h)!=1 || le16(h+2)!=1 ||
                (le32(h+4)!=8000 && le32(h+4)!=16000) || le16(h+12)!=2 || le16(h+14)!=16) return 1;
            *rate=le32(h+4); fmt=1;
        } else if (!memcmp(h,"data",4)) {
            if (!fmt || !size || size%2) return 1;
            *remaining=size; return 0;
        }
        if (fseek(f,next,SEEK_SET)) return 1;
    }
    return 1;
}

int main(int argc,char **argv)
{
    unsigned char input[512],output[2048]; struct stat st; struct sigaction sa;
    FILE *f=stdin; int lock=-1,fd=-1,law=0,rate=16000,rc=1;
    long remaining=-1; double gain=1; char *end; size_t n,i,out;
    if (argc==2 && !strcmp(argv[1],"stop")) return cancel_speaker();
    if (argc!=3 && argc!=4) return 2;
    if (argc==4) {
        gain=strtod(argv[3],&end);
        if (*end || !isfinite(gain) || gain<0 || gain>5) return 2;
    }
    if (!strcmp(argv[1],"stream")) {
        if (!strcmp(argv[2],"ulaw")) { law=1; rate=8000; }
        else if (strcmp(argv[2],"pcm")) return 2;
    } else if (!strcmp(argv[1],"play")) {
        f=fopen(argv[2],"rb"); if (!f) return 1;
        if (fstat(fileno(f),&st) || !S_ISREG(st.st_mode) || st.st_size>(4L<<20)) goto done;
        n=fread(input,1,4,f); rewind(f);
        if (n==4 && !memcmp(input,"RIFF",4)) { if (wav_data(f,&remaining,&rate)) goto done; }
        else { remaining=st.st_size; if (!remaining || remaining%2) goto done; }
    } else return 2;
    memset(&sa,0,sizeof(sa)); sa.sa_handler=stop_signal; sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM,&sa,NULL); sigaction(SIGINT,&sa,NULL); sigaction(SIGHUP,&sa,NULL);
    signal(SIGPIPE,SIG_IGN);
    lock=lock_speaker(); if (lock<0) { fprintf(stderr,"Speaker busy\n"); goto done; }
    if (stat("/tmp/audio_in_fifo",&st) || !S_ISFIFO(st.st_mode)) goto done;
    fd=open("/tmp/audio_in_fifo",O_WRONLY|O_NONBLOCK); if (fd<0) goto done;
    while (!stopped && remaining!=0) {
        n=fread(input,1,remaining>=0 && remaining<512 ? (size_t)remaining : 512,f);
        if (!n) { if (!ferror(f) && remaining<0) rc=0; goto done; }
        if (!law && n%2) goto done;
        if (remaining>=0) remaining-=n;
        out=0;
        for (i=0; i<n; i+=law ? 1 : 2) {
            int sample=law ? ulaw(input[i]) : (int16_t)le16(input+i);
            double amplified=sample*gain;
            sample=amplified>32767 ? 32767 : amplified<-32768 ? -32768 : (int)amplified;
            output[out++]=sample&255; output[out++]=(sample>>8)&255;
            if (rate==8000) { output[out++]=sample&255; output[out++]=(sample>>8)&255; }
        }
        if (write_pcm(fd,output,out)) goto done;
    }
    rc=stopped ? 1 : 0;
done:
    if (fd>=0) close(fd);
    if (lock>=0) close(lock);
    if (f!=stdin) fclose(f);
    return rc;
}
