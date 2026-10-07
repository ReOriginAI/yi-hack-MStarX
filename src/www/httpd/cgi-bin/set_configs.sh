#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/config_work.sh"
. "$YI_HACK_PREFIX/script/upload.sh"
fail() { printf 'Content-type: application/json\r\n\r\n{"error":true}\n'; exit 1; }
case "${QUERY_STRING:-}" in
    conf=system) NAME=system ;; conf=camera) NAME=camera ;;
    conf=mqtt) NAME=mqttv4 ;; conf=mqtt_advertise) NAME=mqtt_advertise ;; conf=proxychains) NAME=proxychains ;;
    *) fail ;;
esac
CONF_FILE="$YI_HACK_PREFIX/etc/$NAME.conf"
[ -f "$CONF_FILE" ] && [ ! -L "$CONF_FILE" ] || fail
config_work_begin || fail
upload_read 16384 "$CONFIG_WORK/body" || fail
jq -e 'type == "object" and length <= 100 and all(to_entries[];
    (.key | test("^[A-Z][A-Z0-9_]*$")) and (.value | type == "string") and
    (.value | length <= 4096) and (.value | test("[\u0000-\u0008\u000b-\u001f]") | not))' "$CONFIG_WORK/body" >/dev/null 2>&1 || fail
# Reject embedded newlines except the existing escaped crontab representation.
jq -e 'all(to_entries[]; (.key == "CRONTAB" or (.value | test("[\\r\\n]") | not)))' "$CONFIG_WORK/body" >/dev/null 2>&1 || fail
OLD_BC=$(config_get RTSP_BACKCHANNEL)
cp "$CONF_FILE" "$CONFIG_WORK/new.conf" || fail
jq -r 'keys[]' "$CONFIG_WORK/body" > "$CONFIG_WORK/keys" || fail
while IFS= read -r KEY; do
    VALUE=$(jq -r --arg k "$KEY" '.[$k]' "$CONFIG_WORK/body") || fail
    case "$KEY" in
        HOSTNAME)
            [ "$NAME" = system ] || fail
            if [ -z "$VALUE" ]; then
                MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null | cut -d: -f5,6 | tr -d :)
                if [ -n "$MAC" ]; then VALUE=yi-$MAC; else VALUE=yi-hack; fi
            fi
            printf '%s\n' "$VALUE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$' || fail
            printf '%s\n' "$VALUE" > "$CONFIG_WORK/hostname" ;;
        TIMEZONE) [ "$NAME" = system ] || fail; printf '%s\n' "$VALUE" > "$CONFIG_WORK/TZ" ;;
        MOTION_IMAGE_DELAY)
            VALUE=$(printf '%s' "$VALUE" | tr , .)
            printf '%s\n' "$VALUE" | grep -Eq '^[0-9]+([.][0-9]+)?$' || fail
            awk -v v="$VALUE" 'BEGIN {exit !(v<=5)}' || fail
            sed -i "/^$KEY=/d" "$CONFIG_WORK/new.conf"
            printf '%s=%s\n' "$KEY" "$VALUE" >> "$CONFIG_WORK/new.conf" ;;
        TIMELAPSE_DT)
            case "$VALUE" in
                1|2|3|4|5|6|10|15|20|30|60|120|180|240|360|1440) ;;
                1440+*) OFFSET=${VALUE#1440+}; case "$OFFSET" in ''|*[!0-9]*|??????*) fail ;; esac
                    [ "$OFFSET" -le 1440 ] || fail ;;
                *) fail ;;
            esac
            sed -i "/^$KEY=/d" "$CONFIG_WORK/new.conf"
            printf '%s=%s\n' "$KEY" "$VALUE" >> "$CONFIG_WORK/new.conf" ;;
        RTSP_BACKCHANNEL|ONVIF_AUDIO_BC)
            [ "$NAME" = system ] || fail
            case "$VALUE" in G711|g711|ulaw) VALUE=G711 ;; AAC|aac) VALUE=AAC ;; NONE|none|'') VALUE=NONE ;; *) fail ;; esac
            for MIRROR in RTSP_BACKCHANNEL ONVIF_AUDIO_BC; do
                sed -i "/^$MIRROR=/d" "$CONFIG_WORK/new.conf"
                printf '%s=%s\n' "$MIRROR" "$VALUE" >> "$CONFIG_WORK/new.conf"
            done ;;
        RTSP_PORT|HTTPD_PORT) valid_port "$VALUE" || fail
            sed -i "/^$KEY=/d" "$CONFIG_WORK/new.conf"
            printf '%s=%s\n' "$KEY" "$VALUE" >> "$CONFIG_WORK/new.conf" ;;
        PROXYCHAINS_SERVERS)
            [ "$NAME" = proxychains ] || fail
            cp "$CONF_FILE.template" "$CONFIG_WORK/new.conf" || fail
            printf '%s\n' "$VALUE" | tr ';' '\n' >> "$CONFIG_WORK/new.conf" ;;
        *)
            grep -q "^$KEY=" "$CONF_FILE" || fail
            # Use plain text instead of interpolating user input into sed code.
            sed -i "/^$KEY=/d" "$CONFIG_WORK/new.conf"
            if [ "$KEY" = CRONTAB ]; then VALUE=$(printf '%s' "$VALUE" | awk '{printf "%s%s",sep,$0; sep="\\n"}'); fi
            printf '%s=%s\n' "$KEY" "$VALUE" >> "$CONFIG_WORK/new.conf" ;;
    esac
done < "$CONFIG_WORK/keys"
[ "$(wc -c < "$CONFIG_WORK/new.conf")" -le 65536 ] || fail
if [ "$NAME" = system ]; then
    ENABLED=$(grep -m 1 '^WIFI_MAINTENANCE_ENABLED=' "$CONFIG_WORK/new.conf")
    case "${ENABLED#*=}" in
        yes)
            SSID=$(grep -m 1 '^WIFI_MAINTENANCE_SSID=' "$CONFIG_WORK/new.conf"); SSID=${SSID#*=}
            PASS=$(grep -m 1 '^WIFI_MAINTENANCE_PASSWORD=' "$CONFIG_WORK/new.conf"); PASS=${PASS#*=}
            SSID_SIZE=$(printf '%s' "$SSID" | wc -c); PASS_SIZE=$(printf '%s' "$PASS" | wc -c)
            [ "$SSID_SIZE" -ge 1 ] && [ "$SSID_SIZE" -le 32 ] && [ "$PASS_SIZE" -ge 8 ] && [ "$PASS_SIZE" -le 63 ] || fail ;;
        no|'') ;;
        *) fail ;;
    esac
fi
# Prepare every small flash replacement before committing it.
CONFIG_FLASH_FILES="$NAME.conf"
cp "$CONFIG_WORK/new.conf" "$YI_HACK_PREFIX/etc/.$NAME.conf.new" || fail
chmod 0644 "$YI_HACK_PREFIX/etc/.$NAME.conf.new" || fail
mv -f "$YI_HACK_PREFIX/etc/.$NAME.conf.new" "$CONF_FILE" || fail
for FILE in hostname TZ; do
    [ ! -f "$CONFIG_WORK/$FILE" ] || cp "$CONFIG_WORK/$FILE" "$YI_HACK_PREFIX/etc/$FILE" || fail
done
[ ! -f "$CONFIG_WORK/hostname" ] || hostname "$(cat "$CONFIG_WORK/hostname")" || fail
NEW_BC=$(config_get RTSP_BACKCHANNEL)
config_work_cleanup
trap - 0 1 2 15
if [ "$NAME" = system ] && [ "$OLD_BC" != "$NEW_BC" ]; then
    "$YI_HACK_PREFIX/script/service.sh" rtsp recover >/dev/null 2>&1
    "$YI_HACK_PREFIX/script/service.sh" onvif recover >/dev/null 2>&1
fi
printf 'Content-type: application/json\r\n\r\n{"error":false}\n'
