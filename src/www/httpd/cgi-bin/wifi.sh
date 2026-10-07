#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/config_work.sh"
. "$YI_HACK_PREFIX/script/upload.sh"
fail() { printf 'Content-type: application/json\r\n\r\n{"error":true}\n'; exit 1; }
case "${QUERY_STRING:-}" in
    action=scan)
        printf 'Content-type: application/json\r\n\r\n'
        "$YI_HACK_PREFIX/bin/iwlist" wlan0 scan | sed -n 's/.*ESSID:"\(.*\)"/\1/p' | jq -R -s '{wifi: (split("\n") | map(select(length>0)))}'
        ;;
    action=save)
        config_work_begin || fail
        upload_read 4096 "$CONFIG_WORK/body" || fail
        jq -e '(.WIFI_ESSID | type=="string") and (.WIFI_PASSWORD | type=="string") and
            (.WIFI_PASSWORD==.WIFI_PASSWORD2) and
            all(.WIFI_ESSID,.WIFI_PASSWORD; test("[\u0000-\u001f]") | not)' "$CONFIG_WORK/body" >/dev/null 2>&1 || fail
        { printf 'wifi_ssid='; jq -r '.WIFI_ESSID' "$CONFIG_WORK/body";
          printf 'wifi_psk='; jq -r '.WIFI_PASSWORD' "$CONFIG_WORK/body"; } > "$CONFIG_WORK/wifi.cfg"
        CFG_FILE="$CONFIG_WORK/wifi.cfg" "$YI_HACK_PREFIX/script/configure_wifi.sh" >/dev/null 2>&1 || fail
        printf 'Content-type: application/json\r\n\r\n{"error":false}\n'
        ;;
    *) fail ;;
esac
