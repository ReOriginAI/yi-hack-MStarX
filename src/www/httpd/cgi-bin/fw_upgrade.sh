#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/runtime.sh"
RELEASE_REPO=ReOriginAI/yi-hack-MStarX
API="https://api.github.com/repos/$RELEASE_REPO/releases/latest"
LOCK=/tmp/yi-upgrade.lock.d
WORK=/tmp/sd/.yi-upgrade-work
fail() { printf 'Content-type: text/plain\r\n\r\nUpgrade failed: %s\n' "$1"; exit 1; }
cleanup() { [ -z "$OWNS_WORK" ] || rm -rf "$WORK"; [ -z "$CONFIG_LOCK" ] || lock_release "$CONFIG_LOCK"; lock_release "$LOCK"; }
latest_version()
{
    # stdout only: wget diagnostics must never become JSON/release metadata.
    wget -q -T 20 -O - "$API" | head -c 65536 | jq -er '.tag_name' 2>/dev/null
}
valid_version()
{
    printf '%s\n' "$1" | grep -Eq '^v?[0-9]+[.][0-9]+[.][0-9]+([.-][A-Za-z0-9]+)*$'
}
[ "$(cat "$YI_HACK_PREFIX/model_suffix")" = y23 ] || fail 'unsupported model'
case "${QUERY_STRING:-}" in
    get=info)
        LATEST=$(latest_version); valid_version "$LATEST" || LATEST=unknown
        if sd_available && [ -f /tmp/sd/y23_x.x.x.tgz ]; then LOCAL=true; else LOCAL=false; fi
        VERSION=$(cat "$YI_HACK_PREFIX/version")
        printf 'Content-type: application/json\r\n\r\n'
        jq -n --arg current "$VERSION" --arg latest "$LATEST" --argjson local "$LOCAL" '{error:false,fw_version:$current,latest_fw:$latest,local_fw:$local}'
        exit ;;
    get=upgrade|get=prepare) ;;
    *) fail 'invalid request' ;;
esac
sd_available || fail 'writable SD required'
FREE=$(df -k /tmp/sd | awk 'NR==2 {print $4}')
case "$FREE" in ''|*[!0-9]*) fail 'cannot measure SD space' ;; esac
[ "$FREE" -ge 100000 ] || fail 'insufficient SD space'
lock_acquire "$LOCK" || fail 'another upgrade is active'
trap cleanup 0
trap 'exit 1' 1 2 15
CONFIG_LOCK=/tmp/yi-config-work.lock.d
lock_acquire "$CONFIG_LOCK" || fail 'configuration work is active'
[ ! -L "$WORK" ] || fail 'unsafe staging path'
# Existing bootloader triggers are never silently replaced.
[ ! -e /tmp/sd/sys_y23 ] && [ ! -e /tmp/sd/home_y23 ] || fail 'pending flash images on SD'
[ ! -e /tmp/sd/.fw_upgrade ] || fail 'pending configuration recovery on SD'
OWNS_WORK=yes
rm -rf "$WORK"; mkdir "$WORK" || fail 'cannot stage upgrade'
umask 077
if [ -f /tmp/sd/y23_x.x.x.tgz ]; then
    [ ! -L /tmp/sd/y23_x.x.x.tgz ] && [ -f /tmp/sd/y23_x.x.x.tgz.sha256 ] || fail 'local archive requires a SHA256 sidecar'
    [ "$(wc -c < /tmp/sd/y23_x.x.x.tgz)" -le 20971520 ] || fail 'archive too large'
    cp /tmp/sd/y23_x.x.x.tgz "$WORK/firmware.tgz" || fail 'cannot stage archive'
    HASH=$(awk 'NR==1 {print $1}' /tmp/sd/y23_x.x.x.tgz.sha256)
else
    LATEST=$(latest_version); valid_version "$LATEST" || fail 'invalid release metadata'
    [ "$LATEST" != "$(cat "$YI_HACK_PREFIX/version")" ] || fail 'already on latest release'
    FILE="y23_${LATEST}.tgz"
    BASE="https://github.com/$RELEASE_REPO/releases/download/$LATEST"
    (ulimit -f 20480 || exit 1; wget -q -T 30 "$BASE/$FILE" -O "$WORK/firmware.tgz") || fail 'download failed'
    (ulimit -f 64 || exit 1; wget -q -T 20 "$BASE/y23_${LATEST}.sha256" -O "$WORK/checksums") || fail 'release checksums unavailable'
    HASH=$(awk -v file="$FILE" '$2==file {print $1}' "$WORK/checksums")
fi
printf '%s\n' "$HASH" | grep -Eq '^[0-9a-f]{64}$' || fail 'invalid checksum'
printf '%s  %s\n' "$HASH" "$WORK/firmware.tgz" | sha256sum -c - >/dev/null 2>&1 || fail 'checksum mismatch'
"$YI_HACK_PREFIX/script/firmware_check.sh" "$WORK/firmware.tgz" "$WORK" || fail 'invalid Y23 archive or flash images'
# Preserve a bounded allowlist of configuration files before publishing images.
mkdir "$WORK/config" || fail 'cannot preserve configuration'
TOTAL=0; COUNT=0
for FILE in "$YI_HACK_PREFIX"/etc/*.conf "$YI_HACK_PREFIX/etc/hostname" "$YI_HACK_PREFIX/etc/TZ" "$YI_HACK_PREFIX/etc/passwd"; do
    [ -f "$FILE" ] || continue
    [ ! -L "$FILE" ] || fail 'unsafe configuration file'
    SIZE=$(wc -c < "$FILE"); TOTAL=$((TOTAL+SIZE)); COUNT=$((COUNT+1))
    [ "$SIZE" -le 65536 ] && [ "$TOTAL" -le 262144 ] && [ "$COUNT" -le 32 ] || fail 'configuration too large'
    cp "$FILE" "$WORK/config/" || fail 'configuration preservation failed'
done
# Preparation is reviewable and never creates filenames the bootloader flashes.
if [ "$QUERY_STRING" = get=prepare ]; then
    OWNS_WORK=
    printf 'Content-type: text/plain\r\n\r\nValidated images and configuration staged in %s; no reboot requested.\n' "$WORK"
    exit 0
fi
mv "$WORK/config" /tmp/sd/.fw_upgrade || fail 'cannot publish configuration recovery'
if ! mv "$WORK/images/home_y23" /tmp/sd/home_y23; then
    mv /tmp/sd/.fw_upgrade "$WORK/config"; fail 'cannot publish home image'
fi
if ! mv "$WORK/images/sys_y23" /tmp/sd/sys_y23; then
    mv /tmp/sd/home_y23 "$WORK/images/home_y23"
    mv /tmp/sd/.fw_upgrade "$WORK/config"; fail 'cannot publish root image'
fi
printf 'Content-type: text/plain\r\n\r\nValidated Y23 images staged; rebooting to upgrade.\n'
sync
sleep 2
reboot -f
