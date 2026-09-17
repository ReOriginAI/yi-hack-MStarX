#!/bin/sh

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX="/home/yi-hack"
START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

#LOG_FILE="/tmp/sd/wd.log"
LOG_FILE="/dev/null"
LOGWIFI_FILE="/tmp/sd/hack_wififailsafe.log"

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
    $START_STOP_SCRIPT rtsp start
}

restart_standard_rtsp()
{
    killall -q rRTSPServer
    killall -q h264grabber h264grabber_l h264grabber_h
    sleep 1
    restart_rtsp
}

restart_alternative_rtsp()
{
    killall -q rtsp_server_yi
    killall -q h264grabber_l
    killall -q h264grabber_h
    sleep 1
    restart_rtsp
}

restart_go2rtc_rtsp()
{
    killall -q go2rtc
    killall -q h264grabber_l
    killall -q h264grabber_h
    sleep 1
    restart_rtsp
}

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
    set -- `awk -v p=":$RTSP_PORT_HEX" '
        $2 ~ (p "$") {
            if ($4 == "0A") listen++
            if ($4 == "01") established++
        }
        END { print listen+0, established+0 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null`
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
        restart_standard_rtsp
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
        if [ "$PS_1_L" -eq 0 ] || [ "$PS_RTSP_STANDARD" -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for low res, restarting..." >> $LOG_FILE
            restart_standard_rtsp
            COUNTER_L=0
            COUNTER_H=0
            reset_rtsp_cpu_baseline
            return
        fi
    fi

    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_H" -eq 0 ] || [ "$PS_RTSP_STANDARD" -eq 0 ]; then
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
        if [ "$PS_1_L" -eq 0 ] || [ "$PS_RTSP_ALT" -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for low res, restarting..." >> $LOG_FILE
            restart_alternative_rtsp
            return
        fi
    fi
    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_H" -eq 0 ] || [ "$PS_RTSP_ALT" -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for high res, restarting..." >> $LOG_FILE
            restart_alternative_rtsp
            return
        fi
    fi
}

check_rtsp_go2rtc()
{
    if [[ "$CAMERA_SWITCH" != "yes" ]] ; then
        echo "Camera is switched off no rtsp restart needed" >> $LOG_FILE
        return
    fi

    if [ "$LISTEN" -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
        restart_go2rtc_rtsp
        return
    fi
    if [[ "$RTSP_RES" == "low" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_L" -eq 0 ] || [ "$PS_RTSP_GO2RTC" -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for low res, restarting..." >> $LOG_FILE
            restart_go2rtc_rtsp
            return
        fi
    fi
    if [[ "$RTSP_RES" == "high" ]] || [[ "$RTSP_RES" == "both" ]]; then
        if [ "$PS_1_H" -eq 0 ] || [ "$PS_RTSP_GO2RTC" -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes for high res, restarting..." >> $LOG_FILE
            restart_go2rtc_rtsp
            return
        fi
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
            $START_STOP_SCRIPT mqtt stop >/dev/null 2>&1
        fi
        if [ "$PS_MQTT_CONFIG" -gt 0 ]; then
            $START_STOP_SCRIPT mqtt-config stop >/dev/null 2>&1
        fi
        return
    fi

    if [ "$PS_MQTT" -eq 0 ]; then
        echo "check_mqtt failed, restart it!" >> $LOG_FILE
        $START_STOP_SCRIPT mqtt start
    fi
}

check_wifi()
{
    WIFI_STATUS=`wpa_cli -i wlan0 status 2>&1`
    case "$WIFI_STATUS" in
        *"wpa_state=COMPLETED"*)
            failsafecounter=0
            return
            ;;
    esac

    if [ -e "$LOGWIFI_FILE" ]; then
        /usr/bin/tail -n 145 "$LOGWIFI_FILE" > "$LOGWIFI_FILE.tmp" && mv "$LOGWIFI_FILE.tmp" "$LOGWIFI_FILE"
    fi
    echo -e "$(date): Wifi connection lost:\n$WIFI_STATUS" >> "$LOGWIFI_FILE"
    failsafecounter=$((failsafecounter + 1))

    if [ "$failsafecounter" -ge 6 ]; then
        echo -e "$(date): Wifi connection still could't be restored. Restarting." >> "$LOGWIFI_FILE"
        sync
        reboot -f
    fi

    echo -e "$(date): Attempting reconnect." >> "$LOGWIFI_FILE"
    sleep 2
    ifconfig wlan0 down
    sleep 1
    ifconfig wlan0 up
    sleep 1
    wpa_cli -i wlan0 reconfigure >/dev/null 2>&1
}

if [[ $(get_config RTSP) == "no" ]] ; then
    exit
fi

case $(get_config RTSP_PORT) in
    ''|*[!0-9]*) RTSP_PORT_NUMBER=554 ;;
    *) RTSP_PORT_NUMBER=$(get_config RTSP_PORT) ;;
esac
RTSP_PORT_HEX=`printf '%04X' "$RTSP_PORT_NUMBER"`

# These values take effect when their services start, so read them once rather
# than spawning configuration pipelines in every watchdog pass.
RTSP_ALT=$(get_config RTSP_ALT)
RTSP_RES=$(get_config RTSP_STREAM)
MQTT_ENABLED=$(get_config MQTT)
failsafecounter=0

echo "$(date +'%Y-%m-%d %H:%M:%S') - Starting RTSP watchdog..." >> $LOG_FILE

while true
do
    refresh_process_state
    refresh_rtsp_socket_state
    CAMERA_SWITCH=$(get_camera_config SWITCH_ON)

    if [[ "$RTSP_ALT" == "standard" ]] ; then
        check_rtsp
    elif [[ "$RTSP_ALT" == "alternative" ]] ; then
        check_rtsp_alt
    else
        check_rtsp_go2rtc
    fi

    check_rmm
    check_mqtt
    check_wifi

    # Normal cadence remains ten seconds.  Once cumulative CPU ticks indicate
    # a possible stall, sample once per second until activity resumes or the
    # historical ten-sample restart threshold is reached.
    if [ $COUNTER_H -eq 0 ] && [ $COUNTER_L -eq 0 ]; then
        sleep $INTERVAL
    else
        sleep 1
    fi
done
