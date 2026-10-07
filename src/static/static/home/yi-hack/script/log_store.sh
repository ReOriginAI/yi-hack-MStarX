#!/bin/sh
# Native rotation must stay inside this hard byte/inode cap.
LOGDIR=/tmp/yi-service-logs
if ! awk '$2=="/tmp/yi-service-logs" && $3=="tmpfs" {found=1} END {exit !found}' /proc/mounts; then
    [ ! -L "$LOGDIR" ] || rm -f "$LOGDIR"
    mkdir -p "$LOGDIR" || exit 1
    if ! mount -t tmpfs -o size=128k,nr_inodes=16,mode=0755 tmpfs "$LOGDIR"; then
        # ENOTDIR also prevents native log rotation from recreating a file.
        # Never leave an ordinary /tmp directory as a logging fallback.
        if rmdir "$LOGDIR" 2>/dev/null; then
            ln -s /dev/null "$LOGDIR" || exit 1
        fi
        # Native log open also verifies the mount's byte/inode capacity; an
        # existing directory with stale files cannot become a fallback store.
        echo 'yi-hack: bounded log mount unavailable; file logging disabled' >&2
    fi
fi
for name in onvif_notify_server onvif_simple_server wsd_simple_server; do
    ln -sf "$LOGDIR/$name.log" "/tmp/$name.log" || exit 1
done
