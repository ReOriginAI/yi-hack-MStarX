#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/config_work.sh"
fail() { printf 'Status: 503 Service Unavailable\r\nContent-type: text/plain\r\n\r\nConfiguration backup unavailable\n'; exit 1; }
config_work_begin || fail
cd "$CONFIG_WORK" || fail
TOTAL=0
COUNT=0
for FILE in "$YI_HACK_PREFIX"/etc/*.conf "$YI_HACK_PREFIX/etc/TZ" "$YI_HACK_PREFIX/etc/hostname" "$YI_HACK_PREFIX/etc/passwd"; do
    [ -f "$FILE" ] || continue
    [ ! -L "$FILE" ] || fail
    SIZE=$(wc -c < "$FILE")
    TOTAL=$((TOTAL+SIZE))
    COUNT=$((COUNT+1))
    [ "$SIZE" -le 65536 ] && [ "$TOTAL" -le 262144 ] && [ "$COUNT" -le 32 ] || fail
    cp "$FILE" . || fail
done
set -- *.conf
for FILE in TZ hostname passwd; do
    [ ! -f "$FILE" ] || set -- "$@" "$FILE"
done
(ulimit -f 1024 || exit 1; tar cf config.tar "$@") 2>/dev/null || fail
"$YI_HACK_PREFIX/bin/archive_check" config config.tar "$YI_HACK_PREFIX" || fail
bzip2 config.tar || fail
[ "$(wc -c < config.tar.bz2)" -le 65536 ] || fail
printf 'Content-type: application/octet-stream\r\nContent-Disposition: attachment; filename="config.tar.bz2"\r\n\r\n'
cat config.tar.bz2
