#!/bin/sh
# Run once at boot. Only validated, bounded configuration enters internal flash.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/config_work.sh"
config_work_begin || exit 1
SOURCE=/tmp/sd/.fw_upgrade
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || exit 1
COUNT=0
TOTAL=0
for FILE in "$SOURCE"/*; do
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || exit 1
    SIZE=$(wc -c < "$FILE")
    TOTAL=$((TOTAL+SIZE)); COUNT=$((COUNT+1))
    [ "$SIZE" -le 65536 ] && [ "$TOTAL" -le 262144 ] && [ "$COUNT" -le 32 ] || exit 1
done
(ulimit -f 1024 || exit 1; cd "$SOURCE" && tar cf "$CONFIG_WORK/config.tar" *) 2>/dev/null || exit 1
"$YI_HACK_PREFIX/bin/archive_check" config "$CONFIG_WORK/config.tar" "$YI_HACK_PREFIX" || exit 1
for FILE in "$SOURCE"/*; do
    NAME=${FILE##*/}
    CONFIG_FLASH_FILES="$CONFIG_FLASH_FILES $NAME"
    cp "$FILE" "$YI_HACK_PREFIX/etc/.$NAME.restore" || exit 1
    chmod 0644 "$YI_HACK_PREFIX/etc/.$NAME.restore" || exit 1
done
for FILE in "$SOURCE"/*; do
    NAME=${FILE##*/}
    mv -f "$YI_HACK_PREFIX/etc/.$NAME.restore" "$YI_HACK_PREFIX/etc/$NAME" || exit 1
done
rm -f "$YI_HACK_PREFIX/.fw_upgrade_in_progress"
rm -rf "$SOURCE"
