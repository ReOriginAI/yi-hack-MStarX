#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/runtime.sh"
LOCK=/tmp/yi-wifi-recovery.lock.d
lock_acquire "$LOCK" || exit 1
trap 'lock_release "$LOCK"' 0
trap 'exit 1' 1 2 15
umask 077
case "${1:-}" in
    primary) PROFILE=/tmp/wpa_supplicant.conf ;;
    maintenance)
        [ "$(config_get WIFI_MAINTENANCE_ENABLED)" = yes ] || exit 1
        SSID=$(config_get WIFI_MAINTENANCE_SSID)
        PASSWORD=$(config_get WIFI_MAINTENANCE_PASSWORD)
        [ -n "$SSID" ] && [ "${#SSID}" -le 32 ] && [ "${#PASSWORD}" -ge 8 ] && [ "${#PASSWORD}" -le 63 ] || exit 1
        # Hex SSIDs avoid quoting ambiguities; WPA passphrases need escaping.
        SSID_HEX=$(printf '%s' "$SSID" | hexdump -v -e '1/1 "%02x"')
        ESCAPED=$(printf '%s' "$PASSWORD" | sed 's/\\/\\\\/g;s/"/\\"/g')
        PROFILE=/tmp/wpa_supplicant.maintenance.conf
        printf 'ctrl_interface=/var/run/wpa_supplicant\nnetwork={\n ssid=%s\n scan_ssid=1\n psk="%s"\n}\n' "$SSID_HEX" "$ESCAPED" > "$PROFILE" || exit 1
        ;;
    *) exit 2 ;;
esac
[ -s "$PROFILE" ] && [ "$(wc -c < "$PROFILE")" -le 4096 ] || exit 1
[ -x /home/base/tools/wpa_supplicant ] || exit 1
# Preserve both the driver and interface state while replacing the supplicant.
killall wpa_supplicant 2>/dev/null || :
sleep 1
/home/base/tools/wpa_supplicant -c"$PROFILE" -g/var/run/wpa_supplicant-global -Dnl80211 -iwlan0 -B || exit 1
if [ "$1" = maintenance ]; then touch /tmp/wifi_maintenance_active; else rm -f /tmp/wifi_maintenance_active; fi
killall -USR1 udhcpc 2>/dev/null || :
"$YI_HACK_PREFIX/script/bounded_log.sh" /tmp/hack_wififailsafe.log "$(date): selected $1 recovery profile"
