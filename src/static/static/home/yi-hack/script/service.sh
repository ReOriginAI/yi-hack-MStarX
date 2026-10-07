#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/runtime.sh"
CONF_FILE=etc/system.conf
SERVICE_STATE=/tmp/yi-service-state
SERVICE_LOCK=/tmp/yi-service.lock.d
get_config() { config_get "$1"; }

init_config()
{
    MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix")
    [ "$MODEL_SUFFIX" = y23 ] || return 1
    YI_HACK_VER=$(cat "$YI_HACK_PREFIX/version")
    SERIAL_NUMBER=$(dd bs=1 count=20 skip=592 if=/tmp/mmap.info 2>/dev/null | tr '\0' '0')
    HW_ID=$(dd bs=1 count=4 skip=661 if=/tmp/mmap.info 2>/dev/null | tr '\0' '0')
    USERNAME=$(get_config USERNAME)
    PASSWORD=$(get_config PASSWORD)
    TZ_TMP=$(cat "$YI_HACK_PREFIX/etc/TZ" 2>/dev/null)
    RTSP_PORT=$(get_config RTSP_PORT)
    valid_port "$RTSP_PORT" || RTSP_PORT=554
    HTTPD_PORT=$(get_config HTTPD_PORT)
    valid_port "$HTTPD_PORT" || HTTPD_PORT=80
    D_RTSP_PORT= D_HTTPD_PORT= RTSP_USERPWD= ONVIF_USERPWD=
    [ "$RTSP_PORT" = 554 ] || D_RTSP_PORT=:$RTSP_PORT
    [ "$HTTPD_PORT" = 80 ] || D_HTTPD_PORT=:$HTTPD_PORT
    if [ -n "$USERNAME" ]; then
        ONVIF_USERPWD="user=$USERNAME\npassword=$PASSWORD"
        URI_USER=$(printf '%s' "$USERNAME" | hexdump -v -e '1/1 "%%%02X"')
        URI_PASSWORD=$(printf '%s' "$PASSWORD" | hexdump -v -e '1/1 "%%%02X"')
        RTSP_USERPWD="$URI_USER:$URI_PASSWORD@"
    fi
    RTSP_ALT=$(get_config RTSP_ALT)
    GO2RTC_BIN="$YI_HACK_PREFIX/bin/go2rtc"
    [ -x "$GO2RTC_BIN" ] || GO2RTC_BIN=/tmp/sd/yi-hack/bin/go2rtc
    case "$RTSP_ALT" in
        go2rtc) if [ -x "$GO2RTC_BIN" ]; then RTSP_DAEMON=go2rtc; else RTSP_ALT=standard; RTSP_DAEMON=rRTSPServer; fi ;;
        alternative) RTSP_DAEMON=rtsp_server_yi ;;
        *) RTSP_ALT=standard; RTSP_DAEMON=rRTSPServer ;;
    esac
    RTSP_RES=$(get_config RTSP_STREAM)
    case "$RTSP_RES" in high|low|both) ;; *) RTSP_RES=high ;; esac
    RTSP_AUDIO=$(get_config RTSP_AUDIO)
    case "$RTSP_AUDIO" in aac|pcm|alaw|ulaw|yes) ;; *) RTSP_AUDIO=no ;; esac
    [ "$RTSP_ALT:$RTSP_AUDIO" != alternative:aac ] || RTSP_AUDIO=alaw
    # MStar go2rtc consumes vendor AAC directly; PCM encoding stays with the
    # standard/alternative servers. Never advertise a codec we cannot produce.
    [ "$RTSP_ALT" != go2rtc ] || { [ "$RTSP_AUDIO" = no ] || RTSP_AUDIO=aac; }
    ONVIF_AUDIO_ENCODER="audio_encoder=$RTSP_AUDIO"
    [ "$RTSP_AUDIO" != no ] || ONVIF_AUDIO_ENCODER=audio_encoder=none
    BACKCHANNEL=$(get_config RTSP_BACKCHANNEL)
    [ -n "$BACKCHANNEL" ] || BACKCHANNEL=$(get_config ONVIF_AUDIO_BC)
    case "$BACKCHANNEL" in G711|g711|ulaw) BACKCHANNEL=G711; BC_CODEC=ulaw ;; AAC|aac) BACKCHANNEL=AAC; BC_CODEC=aac ;; *) BACKCHANNEL=NONE; BC_CODEC= ;; esac
    [ "$(get_config SPEAKER_AUDIO)" = yes ] || { BACKCHANNEL=NONE; BC_CODEC=; }
    # AAC reverse audio is supported by the standard server only.
    if [ "$BACKCHANNEL" = AAC ] && [ "$RTSP_ALT" != standard ]; then BACKCHANNEL=NONE; BC_CODEC=; fi
    [ "$RTSP_ALT" != alternative ] || { BACKCHANNEL=NONE; BC_CODEC=; }
    ONVIF_AUDIO_DECODER="audio_decoder=$BACKCHANNEL"
    for KEY in ONVIF_ENABLE_MEDIA2 ONVIF_FAULT_IF_UNKNOWN ONVIF_FAULT_IF_SET ONVIF_SYNOLOGY_NVR; do
        if [ "$(get_config "$KEY")" = yes ]; then VALUE=1; else VALUE=0; fi
        # KEY comes from the literal list above, not from configuration.
        eval "$KEY=$VALUE"
    done
}

stop_process()
{
    local name="$1" n=0
    killall -q "$name" 2>/dev/null || :
    while [ "$(process_count "$name")" -gt 0 ] && [ "$n" -lt 3 ]; do
        sleep 1; n=$((n+1))
    done
    [ "$(process_count "$name")" -eq 0 ] || killall -q -KILL "$name" 2>/dev/null
    return 0
}

stop_rtsp()
{
    for daemon in go2rtc rRTSPServer rtsp_server_yi h264grabber h264grabber_h h264grabber_l h264grabber2; do
        stop_process "$daemon"
    done
    rm -f /tmp/go2rtc.yaml /tmp/h264_high_fifo /tmp/h264_low_fifo
}

rtsp_healthy()
{
    [ "$(process_count "$RTSP_DAEMON")" -eq 1 ] || return 1
    local hex=$(printf '%04X' "$RTSP_PORT")
    set -- /proc/net/tcp
    [ ! -r /proc/net/tcp6 ] || set -- "$@" /proc/net/tcp6
    awk -v p=":$hex" '$2 ~ (p "$" ) && $4=="0A" {found=1} END {exit !found}' "$@" 2>/dev/null || return 1
    [ "$RTSP_ALT" != go2rtc ] || return 0
    case "$RTSP_RES" in high|both) [ "$(process_count h264grabber_h)" -eq 1 ] || return 1 ;; esac
    case "$RTSP_RES" in low|both) [ "$(process_count h264grabber_l)" -eq 1 ] || return 1 ;; esac
}

yaml_quote()
{
    # Single-quoted YAML treats backslashes literally and doubles apostrophes.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

start_rtsp()
{
    rtsp_healthy && return 0
    stop_rtsp
    if [ "$RTSP_ALT" = go2rtc ]; then
        umask 077
        {
            printf 'streams:\n'
            for RES in high low; do
                case "$RTSP_RES:$RES" in high:low|low:high) continue ;; esac
                if [ "$RES" = high ]; then CH=0; SUFFIX=h; else CH=1; SUFFIX=l; fi
                printf '  ch0_%s.h264:\n    - exec:%s/bin/h264grabber_%s -m y23 -r %s#backchannel=0\n' "$CH" "$YI_HACK_PREFIX" "$SUFFIX" "$RES"
                if [ "$RTSP_AUDIO" != no ]; then
                    printf '    - exec:%s/bin/h264grabber2 -r none -a#backchannel=0\n' "$YI_HACK_PREFIX"
                fi
                if [ "$BACKCHANNEL" = G711 ]; then
                    printf '    - exec:%s/bin/speaker stream ulaw#backchannel=1#audio=pcmu/8000#killsignal=15#killtimeout=2\n' "$YI_HACK_PREFIX"
                fi
            done
            printf 'rtsp:\n  listen: ":%s"\n' "$RTSP_PORT"
            if [ -n "$USERNAME" ]; then
                printf '  username: '; yaml_quote "$USERNAME"; printf '\n  password: '; yaml_quote "$PASSWORD"; printf '\n'
            fi
        } > /tmp/go2rtc.yaml || return 1
        "$GO2RTC_BIN" -c /tmp/go2rtc.yaml >/dev/null 2>&1 &
    else
        case "$RTSP_RES" in low|both) h264grabber_l -m y23 -r low -f >/dev/null 2>&1 & ;; esac
        case "$RTSP_RES" in high|both) h264grabber_h -m y23 -r high -f >/dev/null 2>&1 & ;; esac
        set -- -r "$RTSP_RES" -a "$RTSP_AUDIO" -p "$RTSP_PORT"
        [ -z "$USERNAME" ] || set -- "$@" -u "$USERNAME"
        [ -z "$PASSWORD" ] || set -- "$@" -w "$PASSWORD"
        [ -z "$BC_CODEC" ] || set -- "$@" -b "$BC_CODEC"
        NR_LEVEL=$(get_config RTSP_AUDIO_NR_LEVEL)
        case "$NR_LEVEL" in ''|*[!0-9]*) ;; *) set -- "$@" -n "$NR_LEVEL" ;; esac
        if [ "$RTSP_ALT" = alternative ]; then
            CODEC_LOW=$(cat /tmp/lowres 2>/dev/null); CODEC_HIGH=$(cat /tmp/highres 2>/dev/null)
            [ -z "$CODEC_LOW" ] || set -- "$@" -c "$CODEC_LOW"
            [ -z "$CODEC_HIGH" ] || set -- "$@" -C "$CODEC_HIGH"
            set -- "$@" -m y23
        else
            # The packaged FIFO-only server has no upstream -i option.
            set -- "$@" -c h264 -C h264
        fi
        "$RTSP_DAEMON" "$@" >/dev/null 2>&1 &
    fi
    # Keep concurrent starts from mistaking a newly spawned daemon for stale.
    local tries=0
    while [ "$tries" -lt 5 ]; do
        sleep 1
        rtsp_healthy && return 0
        tries=$((tries+1))
    done
    return 1
}

ensure_ipc()
{
    [ "$(process_count ipc2file)" -eq 1 ] && return 0
    stop_process ipc2file
    ipc2file
}

release_ipc()
{
    # ONVIF and MQTT may share the event consumer. Keep it for either owner.
    if [ "$(process_count onvif_notify_server)" -eq 0 ] && [ "$(process_count mqttv4)" -eq 0 ]; then
        stop_process ipc2file
    fi
}

start_onvif()
{
    # If "null" use default

    if [[ "$2" == "null" ]]; then
        ONVIF_WM_SNAPSHOT=$(get_config ONVIF_WM_SNAPSHOT)
        WATERMARK="&watermark="$ONVIF_WM_SNAPSHOT
    elif [[ "$2" == "yes" ]]; then
        WATERMARK="&watermark=yes"
    fi
    if [[ "$1" == "null" ]]; then
        ONVIF_PROFILE=$(get_config ONVIF_PROFILE)
    elif [[ "$1" == "low" ]] || [[ "$1" == "high" ]] || [[ "$1" == "both" ]]; then
        ONVIF_PROFILE=$1
    fi
    if [[ $ONVIF_PROFILE == "high" ]]; then
        ONVIF_PROFILE_0="name=Profile_0\nwidth=1920\nheight=1080\nurl=rtsp://$RTSP_USERPWD%s$D_RTSP_PORT/ch0_0.h264\nsnapurl=http://$RTSP_USERPWD%s$D_HTTPD_PORT/cgi-bin/snapshot.sh?res=high$WATERMARK\ntype=H264\n$ONVIF_AUDIO_ENCODER\n$ONVIF_AUDIO_DECODER"
    fi
    if [[ $ONVIF_PROFILE == "low" ]]; then
        ONVIF_PROFILE_1="name=Profile_1\nwidth=640\nheight=360\nurl=rtsp://$RTSP_USERPWD%s$D_RTSP_PORT/ch0_1.h264\nsnapurl=http://$RTSP_USERPWD%s$D_HTTPD_PORT/cgi-bin/snapshot.sh?res=low$WATERMARK\ntype=H264\n$ONVIF_AUDIO_ENCODER\n$ONVIF_AUDIO_DECODER"
    fi
    if [[ $ONVIF_PROFILE == "both" ]]; then
        ONVIF_PROFILE_0="name=Profile_0\nwidth=1920\nheight=1080\nurl=rtsp://$RTSP_USERPWD%s$D_RTSP_PORT/ch0_0.h264\nsnapurl=http://$RTSP_USERPWD%s$D_HTTPD_PORT/cgi-bin/snapshot.sh?res=high$WATERMARK\ntype=H264\n$ONVIF_AUDIO_ENCODER\n$ONVIF_AUDIO_DECODER"
        ONVIF_PROFILE_1="name=Profile_1\nwidth=640\nheight=360\nurl=rtsp://$RTSP_USERPWD%s$D_RTSP_PORT/ch0_1.h264\nsnapurl=http://$RTSP_USERPWD%s$D_HTTPD_PORT/cgi-bin/snapshot.sh?res=low$WATERMARK\ntype=H264\n$ONVIF_AUDIO_ENCODER\n$ONVIF_AUDIO_DECODER"
    fi

    ONVIF_SRVD_CONF="/tmp/onvif_simple_server.conf"

    echo "model=Yi Hack" > $ONVIF_SRVD_CONF
    echo "manufacturer=Yi" >> $ONVIF_SRVD_CONF
    echo "firmware_ver=$YI_HACK_VER" >> $ONVIF_SRVD_CONF
    echo "hardware_id=$HW_ID" >> $ONVIF_SRVD_CONF
    echo "serial_num=$SERIAL_NUMBER" >> $ONVIF_SRVD_CONF
    echo "ifs=wlan0" >> $ONVIF_SRVD_CONF
    echo "port=$HTTPD_PORT" >> $ONVIF_SRVD_CONF
    echo "scope=onvif://www.onvif.org/Profile/Streaming" >> $ONVIF_SRVD_CONF
    echo "scope=onvif://www.onvif.org/Profile/T" >> $ONVIF_SRVD_CONF
    echo "scope=onvif://www.onvif.org/hardware" >> $ONVIF_SRVD_CONF
    echo "scope=onvif://www.onvif.org/name" >> $ONVIF_SRVD_CONF
    echo "adv_enable_media2=$ONVIF_ENABLE_MEDIA2" >> $ONVIF_SRVD_CONF
    echo "adv_fault_if_unknown=$ONVIF_FAULT_IF_UNKNOWN" >> $ONVIF_SRVD_CONF
    echo "adv_fault_if_set=$ONVIF_FAULT_IF_SET" >> $ONVIF_SRVD_CONF
    echo "adv_synology_nvr=$ONVIF_SYNOLOGY_NVR" >> $ONVIF_SRVD_CONF
    echo "" >> $ONVIF_SRVD_CONF
    if [ -n "$ONVIF_USERPWD" ]; then
        printf 'user=%s\npassword=%s\n' "$USERNAME" "$PASSWORD" >> $ONVIF_SRVD_CONF
        echo "" >> $ONVIF_SRVD_CONF
    fi
    if [ -n "$ONVIF_PROFILE_0" ]; then
        echo "#Profile 0" >> $ONVIF_SRVD_CONF
        printf '%b\n' "$ONVIF_PROFILE_0" >> $ONVIF_SRVD_CONF
        echo "" >> $ONVIF_SRVD_CONF
    fi
    if [ -n "$ONVIF_PROFILE_1" ]; then
        echo "#Profile 1" >> $ONVIF_SRVD_CONF
        printf '%b\n' "$ONVIF_PROFILE_1" >> $ONVIF_SRVD_CONF
        echo "" >> $ONVIF_SRVD_CONF
    fi

    if [[ $MODEL_SUFFIX == "h201c" ]] || [[ $MODEL_SUFFIX == "h305r" ]] || [[ $MODEL_SUFFIX == "y30" ]] || [[ $MODEL_SUFFIX == "h307" ]] ; then
        echo "#PTZ" >> $ONVIF_SRVD_CONF
        echo "ptz=1" >> $ONVIF_SRVD_CONF
        echo "max_step_x=360" >> $ONVIF_SRVD_CONF
        echo "max_step_y=180" >> $ONVIF_SRVD_CONF
        echo "get_position=/home/yi-hack/bin/ipc_cmd -g" >> $ONVIF_SRVD_CONF
        echo "is_moving=/home/yi-hack/bin/ipc_cmd -u" >> $ONVIF_SRVD_CONF
        echo "move_left=/home/yi-hack/bin/ipc_cmd -m left" >> $ONVIF_SRVD_CONF
        echo "move_right=/home/yi-hack/bin/ipc_cmd -m right" >> $ONVIF_SRVD_CONF
        echo "move_up=/home/yi-hack/bin/ipc_cmd -m up" >> $ONVIF_SRVD_CONF
        echo "move_down=/home/yi-hack/bin/ipc_cmd -m down" >> $ONVIF_SRVD_CONF
        echo "move_stop=/home/yi-hack/bin/ipc_cmd -m stop" >> $ONVIF_SRVD_CONF
        echo "move_preset=/home/yi-hack/bin/ipc_cmd -p %d" >> $ONVIF_SRVD_CONF
        echo "goto_home_position=/home/yi-hack/bin/ipc_cmd -p 0" >> $ONVIF_SRVD_CONF
        echo "set_preset=/home/yi-hack/script/ptz_presets.sh -a add_preset -n %d -m %s" >> $ONVIF_SRVD_CONF
        echo "set_home_position=/home/yi-hack/script/ptz_presets.sh -a set_home_position" >> $ONVIF_SRVD_CONF
        echo "remove_preset=/home/yi-hack/script/ptz_presets.sh -a del_preset -n %d" >> $ONVIF_SRVD_CONF
        echo "jump_to_abs=/home/yi-hack/bin/ipc_cmd -j %f,%f" >> $ONVIF_SRVD_CONF
        echo "jump_to_rel=/home/yi-hack/bin/ipc_cmd -J %f,%f" >> $ONVIF_SRVD_CONF
        echo "get_presets=/home/yi-hack/script/ptz_presets.sh -a get_presets" >> $ONVIF_SRVD_CONF
        echo "" >> $ONVIF_SRVD_CONF
    fi

    echo "#EVENT" >> $ONVIF_SRVD_CONF
    echo "events=3" >> $ONVIF_SRVD_CONF
    echo "#Event 0" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:VideoSource/MotionAlarm" >> $ONVIF_SRVD_CONF
    echo "source_name=Source" >> $ONVIF_SRVD_CONF
    echo "source_type=tt:ReferenceToken" >> $ONVIF_SRVD_CONF
    echo "source_value=VideoSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/motion_alarm" >> $ONVIF_SRVD_CONF
    echo "#Event 1" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:RuleEngine/MyRuleDetector/PeopleDetect" >> $ONVIF_SRVD_CONF
    echo "source_name=VideoSourceConfigurationToken" >> $ONVIF_SRVD_CONF
    echo "source_type=xsd:string" >> $ONVIF_SRVD_CONF
    echo "source_value=VideoSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/human_detection" >> $ONVIF_SRVD_CONF
    echo "#Event 2" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:RuleEngine/MyRuleDetector/VehicleDetect" >> $ONVIF_SRVD_CONF
    echo "source_name=VideoSourceConfigurationToken" >> $ONVIF_SRVD_CONF
    echo "source_type=xsd:string" >> $ONVIF_SRVD_CONF
    echo "source_value=VideoSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/vehicle_detection" >> $ONVIF_SRVD_CONF
    echo "#Event 3" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:RuleEngine/MyRuleDetector/DogCatDetect" >> $ONVIF_SRVD_CONF
    echo "source_name=VideoSourceConfigurationToken" >> $ONVIF_SRVD_CONF
    echo "source_type=xsd:string" >> $ONVIF_SRVD_CONF
    echo "source_value=VideoSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/animal_detection" >> $ONVIF_SRVD_CONF
    echo "#Event 4" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:RuleEngine/MyRuleDetector/BabyCryingDetect" >> $ONVIF_SRVD_CONF
    echo "source_name=VideoSourceConfigurationToken" >> $ONVIF_SRVD_CONF
    echo "source_type=xsd:string" >> $ONVIF_SRVD_CONF
    echo "source_value=VideoSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/baby_crying" >> $ONVIF_SRVD_CONF
    echo "#Event 5" >> $ONVIF_SRVD_CONF
    echo "topic=tns1:AudioAnalytics/Audio/DetectedSound" >> $ONVIF_SRVD_CONF
    echo "source_name=AudioSourceConfigurationToken" >> $ONVIF_SRVD_CONF
    echo "source_type=tt:ReferenceToken" >> $ONVIF_SRVD_CONF
    echo "source_value=AudioSourceToken" >> $ONVIF_SRVD_CONF
    echo "input_file=/tmp/onvif_notify_server/sound_detection" >> $ONVIF_SRVD_CONF

    chmod 0600 $ONVIF_SRVD_CONF
    ensure_ipc
    mkdir -p /tmp/onvif_notify_server
    onvif_notify_server --conf_file $ONVIF_SRVD_CONF
}


service_enabled()
{
    case "$1" in
        rtsp) KEY=RTSP ;;
        onvif) KEY=ONVIF ;;
        wsdd) [ "$(get_config ONVIF)" = yes ] || return 1; KEY=ONVIF_WSDD ;;
        ftpd) KEY=FTPD ;;
        mqtt|mqtt-config) KEY=MQTT ;;
        mp4record) [ "$(get_config DISABLE_CLOUD)" = no ] || [ "$(get_config REC_WITHOUT_CLOUD)" = yes ]; return ;;
        httpd) KEY=HTTPD ;; sshd) KEY=SSHD ;; telnetd) KEY=TELNETD ;; ntpd) KEY=NTPD ;; mdnsd) KEY=MDNSD ;;
        *) return 1 ;;
    esac
    [ "$(get_config "$KEY")" = yes ]
}

service_wanted()
{
    service_enabled "$1" || return 1
    [ ! -f "$SERVICE_STATE/$1.stopped" ] || return 1
    case "$1" in
        rtsp|mp4record) [ ! -f /tmp/privacy ] && [ "$(config_get SWITCH_ON camera.conf)" != no ] || return 1 ;;
    esac
}

service_daemon()
{
    case "$1" in
        rtsp) printf '%s\n' "$RTSP_DAEMON" ;;
        onvif) echo onvif_notify_server ;; wsdd) echo wsd_simple_server ;;
        ftpd) if [ "$(get_config BUSYBOX_FTPD)" = yes ]; then echo tcpsvd; else echo pure-ftpd; fi ;;
        mqtt) echo mqttv4 ;; mqtt-config) echo mqtt-config ;; mp4record) echo mp4record ;;
        sshd) echo dropbear ;; telnetd) echo telnetd ;; httpd) echo httpd ;; ntpd) echo ntpd ;; mdnsd) echo mdnsd ;;
        *) return 1 ;;
    esac
}

service_stop()
{
    case "$1" in
        rtsp) stop_rtsp ;;
        onvif) stop_process onvif_notify_server; stop_process onvif_simple_server; release_ipc ;;
        ftpd) stop_process tcpsvd; stop_process pure-ftpd ;;
        mqtt) stop_process mqttv4; release_ipc ;;
        *) stop_process "$(service_daemon "$1")" ;;
    esac
}

service_start()
{
    service_wanted "$1" || { service_stop "$1"; return 0; }
    [ "$1" != rtsp ] || { start_rtsp; return; }
    DAEMON=$(service_daemon "$1")
    COUNT=$(process_count "$DAEMON")
    # dropbear children are sessions: never collapse them as duplicate listeners.
    [ "$COUNT" -ne 1 ] || { [ "$1" != onvif ] || ensure_ipc; return 0; }
    [ "$1" != sshd ] || { [ "$COUNT" -eq 0 ] || return 0; }
    service_stop "$1"
    case "$1" in
        onvif) "$YI_HACK_PREFIX/script/log_store.sh" || return 1; start_onvif null null ;;
        wsdd) "$YI_HACK_PREFIX/script/log_store.sh" || return 1; wsd_simple_server --pid_file /var/run/wsd_simple_server.pid --if_name wlan0 --xaddr "http://%s$D_HTTPD_PORT/onvif/device_service" -m "$(hostname)" -n Yi ;;
        ftpd) if [ "$DAEMON" = tcpsvd ]; then tcpsvd -E 0.0.0.0 21 ftpd -w >/dev/null 2>&1 & else pure-ftpd -B; fi ;;
        mqtt) mqttv4 >/dev/null 2>&1 & ;;
        mqtt-config) mqtt-config >/dev/null 2>&1 & ;;
        mp4record) (
            cd /home/app || exit 1
            if [ "$(get_config TIME_OSD)" = yes ]; then
                TZP=$(TZ="$TZ_TMP" date +%z); TZP=${TZP:0:3}:${TZP:3:2}
                export TZ="GMT$TZP"
            fi
            exec ./mp4record >/dev/null 2>&1
        ) & ;;
        httpd) httpd -p "$HTTPD_PORT" -h "$YI_HACK_PREFIX/www/" -c /tmp/httpd.conf ;;
        sshd) dropbear -R ;; telnetd) telnetd ;;
        ntpd) ntpd -p "$(get_config NTP_SERVER)" ;;
        mdnsd) "$YI_HACK_PREFIX/sbin/mdnsd" /tmp/mdns.d ;;
    esac
}

NAME=${1:-} ACTION=${2:-}
ALL_SERVICES='rtsp onvif wsdd ftpd mqtt mqtt-config mp4record httpd sshd telnetd ntpd mdnsd'
case "$NAME" in all|privacy) ;; *) service_daemon "$NAME" >/dev/null || exit 2 ;; esac
case "$ACTION" in start|stop|restart|ensure|recover|status|on|off) ;; *) exit 2 ;; esac
if [ "$ACTION" = status ] && [ "$NAME" = privacy ]; then
    if [ -f /tmp/privacy ]; then echo on; else echo off; fi
    exit 0
fi
init_config || exit 1
if [ "$NAME" = rtsp ]; then
    case "${3:-}" in high|low|both) RTSP_RES=$3 ;; esac
    case "${4:-}" in no|yes|aac|pcm|alaw|ulaw) RTSP_AUDIO=$4 ;; esac
fi
if [ "$ACTION" = status ]; then
    [ "$NAME" != all ] || NAME=rtsp
    if [ "$(process_count "$(service_daemon "$NAME")")" -gt 0 ]; then echo started; else echo stopped; fi
    exit 0
fi
lock_acquire "$SERVICE_LOCK" 20 || exit 1
trap 'lock_release "$SERVICE_LOCK"' 0
trap 'exit 1' 1 2 15
mkdir -p "$SERVICE_STATE" || exit 1
if [ "$NAME" = privacy ]; then
    case "$ACTION" in
        on) touch /tmp/privacy /tmp/snapshot.disabled; service_stop rtsp; service_stop mp4record; echo on ;;
        off) rm -f /tmp/privacy; [ "$(get_config SNAPSHOT)" != yes ] || rm -f /tmp/snapshot.disabled; service_start rtsp; service_start mp4record; echo off ;;
        *) exit 2 ;;
    esac
    exit 0
fi
[ "$NAME" != all ] || NAME="$ALL_SERVICES"
RESULT=0
for SERVICE in $NAME; do
    case "$ACTION" in
        stop) touch "$SERVICE_STATE/$SERVICE.stopped"; service_stop "$SERVICE" ;;
        start) rm -f "$SERVICE_STATE/$SERVICE.stopped"; service_start "$SERVICE" || RESULT=1 ;;
        restart) rm -f "$SERVICE_STATE/$SERVICE.stopped"; service_stop "$SERVICE"; service_start "$SERVICE" || RESULT=1 ;;
        recover) if service_wanted "$SERVICE"; then service_stop "$SERVICE"; service_start "$SERVICE" || RESULT=1; fi ;;
        ensure) service_start "$SERVICE" || RESULT=1 ;;
    esac
done
exit "$RESULT"
