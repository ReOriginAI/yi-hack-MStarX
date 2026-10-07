#include "config.h"
#include <stdlib.h>
#include <sys/stat.h>
#include <signal.h>

void (*fconf_handler)(const char* key, const char* value);

void ucase(char *string) {
    // Convert to upper case
    char *s = string;
    while (*s) {
        *s = toupper((unsigned char) *s);
        s++;
    }
}

void lcase(char *string) {
    // Convert to lower case
    char *s = string;
    while (*s) {
        *s = tolower((unsigned char) *s);
        s++;
    }
}

void config_set_handler(void (*f)(const char* key, const char* value))
{
    if (f != NULL)
        fconf_handler = f;
}

void config_parse(FILE *fp)
{
    char buf[MAX_LINE_LENGTH];
    char key[128];
    char value[128];

    int parsed;

    if (fp == NULL)
        return;

    while (fgets(buf, MAX_LINE_LENGTH, fp)) {
        if (buf[0]!='#') // ignore the comments
        {
            parsed=sscanf(buf, "%127[^=] = %127s", key, value);
            if (parsed==2 && fconf_handler!=NULL)
                (*fconf_handler)(key, value);
        }
    }
}

static int take_config_lock(void)
{
    const char *lock = "/tmp/yi-config-work.lock.d";
    const char *recover = "/tmp/yi-config-work.lock.d.recover";
    const char *pidfile = "/tmp/yi-config-work.lock.d/pid";
    long owner = 0;
    FILE *pid;
    if (!mkdir(lock, 0700)) return 0;
    if (errno != EEXIST || mkdir(recover, 0700)) return -1;
    pid = fopen(pidfile, "r");
    if (pid) { if (fscanf(pid, "%ld", &owner) != 1) owner = 0; fclose(pid); }
    if (owner > 0 && kill((pid_t)owner, 0) && errno == ESRCH) {
        unlink(pidfile); rmdir(lock);
    }
    rmdir(recover);
    return mkdir(lock, 0700);
}

static int remove_stale_temp(const char *path)
{
    struct stat st;
    if (lstat(path, &st)) return errno == ENOENT ? 0 : -1;
    /* These reserved names are never configuration inputs or symlinks. */
    if (!S_ISREG(st.st_mode) || st.st_size > 65536) return -1;
    return unlink(path);
}

/* Same mkdir lock as the CGI writers, with bounded SD staging and an
 * atomic, small replacement on the configuration filesystem. */
void config_replace(char *filename, char *key, char *value)
{
    const char *lock = "/tmp/yi-config-work.lock.d";
    const char *pidfile = "/tmp/yi-config-work.lock.d/pid";
    const char *temp = "/tmp/sd/.yi-mqtt-config.tmp";
    char buf[MAX_LINE_LENGTH], oldkey[128], replacement[512];
    char device[256], mountpoint[256], type[64], options[256];
    struct stat st;
    FILE *in = NULL, *out = NULL, *mounts;
    size_t total = 0;
    int mounted = 0, fd, locked = 0, staged = 0, replacing = 0;
    lcase(filename); ucase(key);
    if (strlen(key) >= 128 || strlen(value) >= 128 || strpbrk(value, "\r\n")) return;
    for (fd = 0; key[fd]; fd++) if (!(isalnum((unsigned char)key[fd]) || key[fd] == '_')) return;
    if (snprintf(replacement, sizeof(replacement), "%s.mqtt.new", filename) >= (int)sizeof(replacement)) return;
    mounts = fopen("/proc/mounts", "r");
    if (!mounts) return;
    while (fgets(buf, sizeof(buf), mounts)) {
        if (sscanf(buf, "%255s %255s %63s %255s", device, mountpoint, type, options) == 4 &&
            !strcmp(mountpoint, "/tmp/sd") && !strncmp(device, "/dev/", 5) &&
            strcmp(type, "tmpfs") && !strncmp(options, "rw,", 3)) mounted = 1;
    }
    fclose(mounts);
    if (!mounted || take_config_lock()) return;
    locked = 1;
    out = fopen(pidfile, "w"); if (!out) goto cleanup;
    fprintf(out, "%ld\n", (long)getpid()); fclose(out); out = NULL;
    if (lstat(filename, &st) || !S_ISREG(st.st_mode) || st.st_size > 65536) goto cleanup;
    if (remove_stale_temp(temp) || remove_stale_temp(replacement)) goto cleanup;
    in = fopen(filename, "r"); if (!in) goto cleanup;
    fd = open(temp, O_WRONLY|O_CREAT|O_EXCL, 0600); if (fd < 0) goto cleanup;
    staged = 1;
    out = fdopen(fd, "w"); if (!out) { close(fd); goto cleanup; }
    while (fgets(buf, sizeof(buf), in)) {
        if (buf[0] != '#' && sscanf(buf, "%127[^=]", oldkey) == 1 && !strcasecmp(oldkey, key))
            snprintf(buf, sizeof(buf), "%s=%s\n", key, value);
        total += strlen(buf);
        if (total > 65536 || fputs(buf, out) == EOF) goto cleanup;
    }
    if (ferror(in) || fflush(out)) goto cleanup;
    fclose(in); in = NULL; fclose(out); out = NULL;
    in = fopen(temp, "r"); if (!in) goto cleanup;
    fd = open(replacement, O_WRONLY|O_CREAT|O_EXCL, st.st_mode & 0777); if (fd < 0) goto cleanup;
    replacing = 1;
    out = fdopen(fd, "w"); if (!out) { close(fd); goto cleanup; }
    while (fgets(buf, sizeof(buf), in)) if (fputs(buf, out) == EOF) goto cleanup;
    if (ferror(in) || fflush(out) || fsync(fileno(out))) goto cleanup;
    fclose(out); out = NULL;
    rename(replacement, filename);
cleanup:
    if (in) fclose(in);
    if (out) fclose(out);
    /* We only own temporary files after successfully taking the shared lock. */
    if (staged) unlink(temp);
    if (replacing) unlink(replacement);
    if (locked) { unlink(pidfile); rmdir(lock); }
}

FILE *open_conf_file(const char* filename)
{
    FILE *fp;

    fp = fopen(filename, "r");
    if (fp == NULL) {
        printf("Can't open file \"%s\": %s\n", filename, strerror(errno));
        return NULL;
    }

    return fp;
}

void close_conf_file(FILE *fp)
{
    if (fp != NULL)
        fclose(fp);
    fp = NULL;
}
