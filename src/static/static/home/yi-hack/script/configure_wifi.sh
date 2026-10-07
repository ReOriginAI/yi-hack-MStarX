#!/bin/sh
# Keep MStar's erase/staged-image write semantics; only the parser is shared.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/runtime.sh"
LC_ALL=C; export LC_ALL
CFG_FILE=${CFG_FILE:-/tmp/configure_wifi.cfg}
MTD_DEVICE=/dev/mtd/mtd5
FORCE=no; [ "${1:-}" != force ] || FORCE=yes
LOCK=/tmp/yi-wifi-config.lock.d
sd_available || exit 1
lock_acquire "$LOCK" || exit 1
WORK=/tmp/sd/.yi-wifi-config
cleanup() { rm -rf "$WORK"; lock_release "$LOCK"; }
fail() { echo "configure_wifi.sh: $*" >&2; exit 1; }
trap cleanup 0
trap 'exit 1' 1 2 15
umask 077
[ -f "$CFG_FILE" ] && [ ! -L "$CFG_FILE" ] && [ "$(wc -c < "$CFG_FILE")" -le 4096 ] || fail 'invalid config file'
[ ! -L "$WORK" ] || fail 'unsafe staging path'
rm -rf "$WORK"; mkdir "$WORK" || fail 'cannot stage Wi-Fi configuration'
RAW_CFG="$WORK/raw"
CLEAN_CFG="$WORK/clean"
# Normalize common editor/OS encodings without silently changing credential bytes.
# UTF-8 BOM and CRLF/CR line endings are accepted. UTF-16 is rejected explicitly
# because stripping NUL bytes can corrupt non-ASCII SSIDs/passwords.
PREFIX=$(dd if="$CFG_FILE" bs=1 count=3 2>/dev/null | hexdump -v -e '1/1 "%02x"')
case "$PREFIX" in
    efbbbf*)
        dd if="$CFG_FILE" of="$RAW_CFG" bs=1 skip=3 2>/dev/null || fail "cannot remove UTF-8 BOM"
        ;;
    fffe*|feff*)
        fail "UTF-16 configure_wifi.cfg is not supported; save it as UTF-8 or plain text"
        ;;
    *)
        cat "$CFG_FILE" > "$RAW_CFG" || fail "cannot read configure_wifi.cfg"
        ;;
esac

# Embedded NUL usually means UTF-16 without a BOM or a damaged file. Refuse it
# instead of producing an empty/partial SSID and touching flash.
if hexdump -v -e '1/1 "%02x\n"' "$RAW_CFG" | grep -q '^00$'; then
    fail "configure_wifi.cfg contains NUL bytes; save it as UTF-8 or plain text"
fi

# Accept Unix LF, Windows CRLF, and classic CR line endings. A CR inside a value
# is not a valid credential delimiter and is therefore normalized to a newline.
tr '\r' '\n' < "$RAW_CFG" > "$CLEAN_CFG" || fail "cannot normalize line endings"

# Reject common invisible Unicode formatting characters. Silently stripping
# these could change a legitimate SSID, so fail with a useful error instead.
HEX=$(hexdump -v -e '1/1 "%02x"' "$CLEAN_CFG")
case "$HEX" in
    *efbbbf*|*c2ad*|*c2a0*|*e28087*|*e2808b*|*e2808c*|*e2808d*|*e2808e*|*e2808f*|*e280aa*|*e280ab*|*e280ac*|*e280ad*|*e280ae*|*e280af*|*e281a0*|*e281a6*|*e281a7*|*e281a8*|*e281a9*)
        fail "configure_wifi.cfg contains an invisible Unicode formatting character"
        ;;
esac

SSID=
KEY=
SSID_SEEN=0
KEY_SEEN=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
    case "$LINE" in
        wifi_ssid=*)
            [ "$SSID_SEEN" -eq 0 ] || fail "duplicate wifi_ssid entry"
            SSID=${LINE#wifi_ssid=}
            SSID_SEEN=1
            ;;
        wifi_psk=*)
            [ "$KEY_SEEN" -eq 0 ] || fail "duplicate wifi_psk entry"
            KEY=${LINE#wifi_psk=}
            KEY_SEEN=1
            ;;
    esac
done < "$CLEAN_CFG"

[ "$SSID_SEEN" -eq 1 ] || fail "wifi_ssid entry is missing"
[ "$KEY_SEEN" -eq 1 ] || fail "wifi_psk entry is missing"
[ -n "$SSID" ] || fail "SSID has not been set"
[ -n "$KEY" ] || fail "Wi-Fi key has not been set"

SSID_LEN=${#SSID}
KEY_LEN=${#KEY}
[ "$SSID_LEN" -le 32 ] || fail "SSID is too long ($SSID_LEN bytes; maximum is 32)"
[ "$KEY_LEN" -le 63 ] || fail "Wi-Fi key is too long ($KEY_LEN bytes; maximum is 63)"


[ "$KEY_LEN" -ge 8 ] || fail 'Wi-Fi key must have at least 8 bytes'
CURRENT_SSID=$(dd if="$MTD_DEVICE" bs=1 skip=28 count=64 2>/dev/null | tr -d '\000')
CURRENT_KEY=$(dd if="$MTD_DEVICE" bs=1 skip=92 count=64 2>/dev/null | tr -d '\000')
CONNECTED=$(hexdump -s 24 -n 4 -v -e '1/1 "%02x"' "$MTD_DEVICE")
if [ "$SSID" = "$CURRENT_SSID" ] && [ "$KEY" = "$CURRENT_KEY" ] && [ "$CONNECTED" = 00000000 ] && [ "$FORCE" != yes ]; then exit 0; fi
# Y23 conf partition is exactly 64 KiB. Refuse a different live layout.
grep -q '^mtd5: 00010000 00010000 "conf"$' /proc/mtd || fail 'unsupported MTD layout'
BACKUP="/tmp/sd/mtdblock5_$(date +%Y%m%dT%H%M%S)_$$.bin"
dd if="$MTD_DEVICE" of="$BACKUP" bs=65536 2>/dev/null || fail 'partition backup failed'
[ "$(wc -c < "$BACKUP")" -eq 65536 ] || fail 'incomplete partition backup'
cp "$BACKUP" "$WORK/image" || fail 'cannot stage image'
for OFFSET in 28 92; do
    dd if=/dev/zero of="$WORK/image" bs=1 seek="$OFFSET" count=64 conv=notrunc 2>/dev/null || fail 'cannot clear field'
done
printf '%s' "$SSID" | dd of="$WORK/image" bs=1 seek=28 conv=notrunc 2>/dev/null || fail 'cannot stage SSID'
printf '%s' "$KEY" | dd of="$WORK/image" bs=1 seek=92 conv=notrunc 2>/dev/null || fail 'cannot stage key'
printf '\000\000\000\000' | dd of="$WORK/image" bs=1 seek=24 conv=notrunc 2>/dev/null || fail 'cannot stage state'
[ "$(wc -c < "$WORK/image")" -eq 65536 ] || fail 'invalid image size'
flash_eraseall "$MTD_DEVICE" >/dev/null || fail "erase failed; backup retained at $BACKUP"
dd if="$WORK/image" of="$MTD_DEVICE" bs=65536 2>/dev/null || fail "write failed; backup retained at $BACKUP"
sync
dd if="$MTD_DEVICE" of="$WORK/readback" bs=65536 2>/dev/null || fail 'readback failed'
cmp "$WORK/image" "$WORK/readback" || fail "verification failed; backup retained at $BACKUP"
echo 'configure_wifi.sh: credentials written and verified; used on next boot'
