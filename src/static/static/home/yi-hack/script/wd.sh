#!/bin/sh

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/runtime.sh"
START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

#LOG_FILE="/tmp/sd/wd.log"
LOG_FILE="/dev/null"
LOGWIFI_FILE="/tmp/hack_wififailsafe.log"

COUNTER_H=0
COUNTER_L=0
COUNTER_LIMIT=10
INTERVAL=10

PREV_LOW_PID=0
PREV_HIGH_PID=0
PREV_SERVER_PID=0
PREV_LOW_TICKS=-1
PREV_HIGH_TICKS=-1
PREV_SERVER_TICKS=-1

get_camera_config()
{
    key=$1
    line=`grep -m 1 "^$key=" $YI_HACK_PREFIX/$CAMERA_CONF_FILE`
    echo "${line#*=}"
}

get_config()
{
    key=$1
    line=`grep -m 1 "^$key=" $YI_HACK_PREFIX/$CONF_FILE`
    echo "${line#*=}"
}

restart_rtsp()
{
    # Ensure preserves explicit stop and privacy intent, even if it changed
    # between the watchdog sample and acquiring the service lock.
    "$START_STOP_SCRIPT" rtsp ensure >/dev/null 2>&1
}
restart_standard_rtsp() { restart_rtsp; }
restart_alternative_rtsp() { restart_rtsp; }
restart_go2rtc_rtsp() { restart_rtsp; }

refresh_process_state()
{
    # Read the process table once per iteration.  Besides avoiding repeated ps
    # pipelines, keeping the PIDs lets the standard RTSP stall detector read
    # cumulative CPU ticks directly from /proc instead of running top.
    PS_OUTPUT=`ps`
    set -- `printf '%s\n' "$PS_OUTPUT" | awk '
        $4 == "h264grabber_l" { low++; low_pid=$1 }
        $4 == "h264grabber_h" { high++; high_pid=$1 }
        $4 == "rRTSPServer"   { standard++; standard_pid=$1 }
        $4 == "rtsp_server_yi" { alternative++ }
        $4 == "go2rtc"        { go2rtc++ }
        $4 == "./rmm"         { rmm++ }
        $4 == "mqttv4"        { mqtt++ }
        $4 == "mqtt-config"   { mqtt_config++ }
        END {
            print low+0, high+0, standard+0, alternative+0, go2rtc+0,
                  rmm+0, mqtt+0, mqtt_config+0,
                  low_pid+0, high_pid+0, standard_pid+0
        }
    '`
    PS_1_L=$1
    PS_1_H=$2
    PS_RTSP_STANDARD=$3
    PS_RTSP_ALT=$4
    PS_RTSP_GO2RTC=$5
    PS_RMM=$6
    PS_MQTT=$7
    PS_MQTT_CONFIG=$8
    PID_1_L=$9
    PID_1_H=${10}
    PID_RTSP_STANDARD=${11}
}

refresh_rtsp_socket_state()
{
    # Avoid spawning netstat.  Linux TCP state 0A is LISTEN and 01 is
    # ESTABLISHED.  RTSP listens on IPv4 on the current Y23, but include tcp6
    # as well so this remains correct if a future server binds there.
    TCP_FILES=/proc/net/tcp
    [ ! -r /proc/net/tcp6 ] || TCP_FILES="$TCP_FILES /proc/net/tcp6"
    set -- `awk -v p=":$RTSP_PORT_HEX" '
        $2 ~ (p "$") {
            if ($4 == "0A") listen++
            if ($4 == "01") established++
        }
        END { print listen+0, established+0 }
    ' $TCP_FILES 2>/dev/null`
    LISTEN=$1
    SOCKET=$2
}

read_cpu_ticks()
{
    CPU_TICKS_RESULT=-1
    pid=$1

    if [ -z "$pid" ] || [ "$pid" -le 0 ] || [ ! -r "/proc/$pid/stat" ]; then
        return
    fi

    IFS= read -r stat_line < "/proc/$pid/stat" || return
    set -- $stat_line
    if [ $# -lt 15 ]; then
        return
    fi

    CPU_TICKS_RESULT=$((${14} + ${15}))
}

reset_rtsp_cpu_baseline()
{
    PREV_LOW_PID=0
    PREV_HIGH_PID=0
    PREV_SERVER_PID=0
    PREV_LOW_TICKS=-1
    PREV_HIGH_TICKS=-1
    PREV_SERVER_TICKS=-1
}

check_standard_rtsp_stall()
{
    read_cpu_ticks "$PID_RTSP_STANDARD"
    CUR_SERVER_TICKS=$CPU_TICKS_RESULT

    read_cpu_ticks "$PID_1_L"
    CUR_LOW_TICKS=$CPU_TICKS_RESULT

    read_cpu_ticks "$PID_1_H"
    CUR_HIGH_TICKS=$CPU_TICKS_RESULT

    LOW_STALLED=0
    HIGH_STALLED=0

    if [[ "$RTSP_RES" == "low" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PID_1_L" -eq "$PREV_LOW_PID" ] && \
           [ "$PID_RTSP_STANDARD" -eq "$PREV_SERVER_PID" ] && \
           [ "$CUR_LOW_TICKS" -ge 0 ] && \
           [ "$CUR_SERVER_TICKS" -ge 0 ] && \
           [ "$CUR_LOW_TICKS" -eq "$PREV_LOW_TICKS" ] && \
           [ "$CUR_SERVER_TICKS" -eq "$PREV_SERVER_TICKS" ]; then
            LOW_STALLED=1
        fi
    fi

    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PID_1_H" -eq "$PREV_HIGH_PID" ] && \
           [ "$PID_RTSP_STANDARD" -eq "$PREV_SERVER_PID" ] && \
           [ "$CUR_HIGH_TICKS" -ge 0 ] && \
           [ "$CUR_SERVER_TICKS" -ge 0 ] && \
           [ "$CUR_HIGH_TICKS" -eq "$PREV_HIGH_TICKS" ] && \
           [ "$CUR_SERVER_TICKS" -eq "$PREV_SERVER_TICKS" ]; then
            HIGH_STALLED=1
        fi
    fi

    PREV_LOW_PID=$PID_1_L
    PREV_HIGH_PID=$PID_1_H
    PREV_SERVER_PID=$PID_RTSP_STANDARD
    PREV_LOW_TICKS=$CUR_LOW_TICKS
    PREV_HIGH_TICKS=$CUR_HIGH_TICKS
    PREV_SERVER_TICKS=$CUR_SERVER_TICKS

    if [ "$LOW_STALLED" -eq 1 ]; then
        COUNTER_L=$((COUNTER_L+1))
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Detected possible locked process for low res ($COUNTER_L)" >> $LOG_FILE
    else
        COUNTER_L=0
    fi

    if [ "$HIGH_STALLED" -eq 1 ]; then
        COUNTER_H=$((COUNTER_H+1))
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Detected possible locked process for high res ($COUNTER_H)" >> $LOG_FILE
    else
        COUNTER_H=0
    fi

    if [ $COUNTER_L -ge $COUNTER_LIMIT ] || [ $COUNTER_H -ge $COUNTER_LIMIT ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting stalled RTSP processes" >> $LOG_FILE
        "$START_STOP_SCRIPT" rtsp recover >/dev/null 2>&1
        COUNTER_L=0
        COUNTER_H=0
        reset_rtsp_cpu_baseline
    fi
}

check_rtsp()
{
    if [[ "$CAMERA_SWITCH" != "yes" ]] ; then
        echo "Camera is switched off no rtsp restart needed" >> $LOG_FILE
        COUNTER_L=0
        COUNTER_H=0
        reset_rtsp_cpu_baseline
        return
    fi

    if [ "$LISTEN" -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
        restart_standard_rtsp
        COUNTER_L=0
        COUNTER_H=0
        reset_rtsp_cpu_baseline
        return
    fi

    if [[ "$RTSP_RES" == "low" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_L" -ne 1 ] || [ "$PS_RTSP_STANDARD" -ne 1 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for low res, restarting..." >> $LOG_FILE
            restart_standard_rtsp
            COUNTER_L=0
            COUNTER_H=0
            reset_rtsp_cpu_baseline
            return
        fi
    fi

    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_H" -ne 1 ] || [ "$PS_RTSP_STANDARD" -ne 1 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for high res, restarting..." >> $LOG_FILE
            restart_standard_rtsp
            COUNTER_L=0
            COUNTER_H=0
            reset_rtsp_cpu_baseline
            return
        fi
    fi

    if [ "$SOCKET" -le 0 ]; then
        COUNTER_L=0
        COUNTER_H=0
        reset_rtsp_cpu_baseline
        return
    fi

    check_standard_rtsp_stall
}

check_rtsp_alt()
{
    if [[ "$CAMERA_SWITCH" != "yes" ]] ; then
        echo "Camera is switched off no rtsp restart needed" >> $LOG_FILE
        return
    fi

    if [ "$LISTEN" -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
        restart_alternative_rtsp
        return
    fi
    if [[ "$RTSP_RES" == "low" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_L" -ne 1 ] || [ "$PS_RTSP_ALT" -ne 1 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for low res, restarting..." >> $LOG_FILE
            restart_alternative_rtsp
            return
        fi
    fi
    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_H" -ne 1 ] || [ "$PS_RTSP_ALT" -ne 1 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for high res, restarting..." >> $LOG_FILE
            restart_alternative_rtsp
            return
        fi
    fi
}

check_rtsp_go2rtc()
{
    # Exec producers and speaker helpers are deliberately absent while idle.
    if [ "$LISTEN" -eq 0 ] || [ "$PS_RTSP_GO2RTC" -ne 1 ]; then
        restart_go2rtc_rtsp
    fi
}

check_rmm()
{
    if [ "$PS_RMM" -eq 0 ]; then
        echo "check_rmm failed, reboot!" >> $LOG_FILE
        sync
        reboot -f
    fi
}

check_mqtt()
{
    if [[ "$MQTT_ENABLED" != "yes" ]] ; then
        if [ "$PS_MQTT" -gt 0 ]; then
            $START_STOP_SCRIPT mqtt ensure >/dev/null 2>&1
        fi
        if [ "$PS_MQTT_CONFIG" -gt 0 ]; then
            $START_STOP_SCRIPT mqtt-config ensure >/dev/null 2>&1
        fi
        return
    fi

    if [ "$PS_MQTT" -eq 0 ]; then
        echo "check_mqtt failed, restart it!" >> $LOG_FILE
        $START_STOP_SCRIPT mqtt ensure
    fi
}

wifi_log()
{
    "$YI_HACK_PREFIX/script/bounded_log.sh" "$LOGWIFI_FILE" "$(date): $*"
}

check_wifi()
{
    WIFI_STATUS=$(wpa_cli -i wlan0 status 2>&1)
    case "$WIFI_STATUS" in
        *"wpa_state=COMPLETED"*)
            if [ "$failsafecounter" -gt 0 ]; then
                # Renew the existing DHCP client, do not create a second one.
                killall -USR1 udhcpc 2>/dev/null || :
                wifi_log 'Association restored'
            fi
            failsafecounter=0; return ;;
    esac
    failsafecounter=$((failsafecounter+1))
    wifi_log "Association lost; soft recovery attempt $failsafecounter"
    case "$failsafecounter" in
        1) wpa_cli -i wlan0 reassociate >/dev/null 2>&1 ;;
        2) wpa_cli -i wlan0 reconfigure >/dev/null 2>&1 ;;
        3) if [ -f /tmp/wifi_maintenance_active ]; then PROFILE=maintenance; else PROFILE=primary; fi
            "$YI_HACK_PREFIX/script/wifi_failover.sh" "$PROFILE" >/dev/null 2>&1 ;;
        6) "$YI_HACK_PREFIX/script/wifi_failover.sh" maintenance >/dev/null 2>&1 ;;
        *)
            # Leave the interface up. A missing maintenance profile does not
            # justify a reboot loop or repeated SDIO down/up transitions.
            if [ "$failsafecounter" -ge 12 ]; then
                wpa_cli -i wlan0 reassociate >/dev/null 2>&1
                failsafecounter=6
            fi ;;
    esac
}

# Use the already cached process table for optional-service recovery.
cached_count()
{
    printf '%s\n' "$PS_OUTPUT" | awk -v name="$1" '
        NR>1 {cmd=$4; gsub(/[{}]/,"",cmd); sub(/^.*\//,"",cmd); if (cmd==name) n++}
        END {print n+0}'
}

check_local_services()
{
    for spec in 'onvif:ONVIF:onvif_notify_server' 'wsdd:ONVIF_WSDD:wsd_simple_server' \
        'ftpd:FTPD:pure-ftpd' 'mqtt:MQTT:mqttv4' 'mqtt-config:MQTT:mqtt-config' \
        'httpd:HTTPD:httpd' 'sshd:SSHD:dropbear' 'telnetd:TELNETD:telnetd' \
        'ntpd:NTPD:ntpd' 'mdnsd:MDNSD:mdnsd'; do
        NAME=${spec%%:*}; rest=${spec#*:}; KEY=${rest%%:*}; DAEMON=${rest#*:}
        [ "$NAME" != ftpd ] || [ "$(get_config BUSYBOX_FTPD)" != yes ] || DAEMON=tcpsvd
        COUNT=$(cached_count "$DAEMON")
        if [ "$(get_config "$KEY")" = yes ] && [ ! -f "/tmp/yi-service-state/$NAME.stopped" ]; then
            if [ "$COUNT" -eq 0 ] || { [ "$NAME" != sshd ] && [ "$COUNT" -gt 1 ]; }; then
                "$START_STOP_SCRIPT" "$NAME" ensure >/dev/null 2>&1
            fi
        elif [ "$COUNT" -gt 0 ]; then
            "$START_STOP_SCRIPT" "$NAME" ensure >/dev/null 2>&1
        fi
    done
    REC_COUNT=$(cached_count mp4record)
    if [ "$REC_COUNT" -ne 1 ] || [ "$CAMERA_SWITCH" != yes ] || [ -f /tmp/privacy ] ||
        [ -f /tmp/yi-service-state/mp4record.stopped ] ||
        { [ "$(get_config DISABLE_CLOUD)" != no ] && [ "$(get_config REC_WITHOUT_CLOUD)" != yes ]; }; then
        "$START_STOP_SCRIPT" mp4record ensure >/dev/null 2>&1
    fi
    # Repair a lost queue consumer while ONVIF itself remains alive.
    if [ "$(cached_count onvif_notify_server)" -eq 1 ] && [ "$(cached_count ipc2file)" -ne 1 ]; then
        "$START_STOP_SCRIPT" onvif ensure >/dev/null 2>&1
    fi
}

WATCHDOG_LOCK=/tmp/yi-watchdog.lock.d
lock_acquire "$WATCHDOG_LOCK" || exit 0
trap 'lock_release "$WATCHDOG_LOCK"' 0
trap 'exit 1' 1 2 15
failsafecounter=0
POLICY_COUNTER=0
while true; do
    refresh_process_state
    RTSP_PORT_NUMBER=$(get_config RTSP_PORT)
    valid_port "$RTSP_PORT_NUMBER" || RTSP_PORT_NUMBER=554
    RTSP_PORT_HEX=$(printf '%04X' "$RTSP_PORT_NUMBER")
    refresh_rtsp_socket_state
    CAMERA_SWITCH=$(get_camera_config SWITCH_ON)
    RTSP_ALT=$(get_config RTSP_ALT)
    RTSP_RES=$(get_config RTSP_STREAM)
    MQTT_ENABLED=$(get_config MQTT)
    if [ "$RTSP_ALT" = go2rtc ] && [ ! -x "$YI_HACK_PREFIX/bin/go2rtc" ] && [ ! -x /tmp/sd/yi-hack/bin/go2rtc ]; then RTSP_ALT=standard; fi
    if [ "$(get_config RTSP)" = yes ] && [ "$CAMERA_SWITCH" = yes ] && [ ! -f /tmp/privacy ] && [ ! -f /tmp/yi-service-state/rtsp.stopped ]; then
        case "$RTSP_ALT" in
            alternative) check_rtsp_alt ;; go2rtc) check_rtsp_go2rtc ;; *) check_rtsp ;;
        esac
    else
        COUNTER_L=0; COUNTER_H=0; reset_rtsp_cpu_baseline
        if [ "$PS_RTSP_STANDARD" -gt 0 ] || [ "$PS_RTSP_ALT" -gt 0 ] || [ "$PS_RTSP_GO2RTC" -gt 0 ]; then
            "$START_STOP_SCRIPT" rtsp ensure >/dev/null 2>&1
        fi
    fi
    check_rmm
    check_mqtt
    check_wifi
    if [ "$POLICY_COUNTER" -eq 0 ]; then
        check_local_services
        "$YI_HACK_PREFIX/script/oom_policy.sh" >/dev/null 2>&1
    fi
    POLICY_COUNTER=$(((POLICY_COUNTER+1)%3))
    if [ "$COUNTER_H" -eq 0 ] && [ "$COUNTER_L" -eq 0 ]; then sleep "$INTERVAL"; else sleep 1; fi
done
