#!/bin/sh
# Validation only. Never publish bootloader flash triggers in this helper.
[ "$#" -eq 2 ] || exit 2
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
ARCHIVE=$1 WORK=$2
[ "$(cat "$YI_HACK_PREFIX/model_suffix")" = y23 ] || exit 1
[ "$(wc -c < "$ARCHIVE")" -le 20971520 ] || exit 1
(ulimit -f 20480 || exit 1; gzip -dc "$ARCHIVE" > "$WORK/firmware.tar") 2>/dev/null || exit 1
"$YI_HACK_PREFIX/bin/archive_check" firmware "$WORK/firmware.tar" "$YI_HACK_PREFIX" || exit 1
mkdir "$WORK/images" || exit 1
(ulimit -f 16384 || exit 1; cd "$WORK/images" && tar -xf "$WORK/firmware.tar") 2>/dev/null || exit 1
for SPEC in sys_y23:1966080 home_y23:12779520; do
    NAME=${SPEC%%:*}; MAX=${SPEC#*:}
    SIZE=$(wc -c < "$WORK/images/$NAME")
    [ "$SIZE" -ge 65536 ] && [ "$SIZE" -le "$MAX" ] || exit 1
    MAGIC=$(hexdump -n 2 -v -e '1/1 "%02x"' "$WORK/images/$NAME")
    [ "$MAGIC" = 8519 ] || exit 1
done
