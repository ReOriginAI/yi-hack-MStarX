#!/bin/sh
. "$YI_HACK_PREFIX/script/runtime.sh"
. "$YI_HACK_PREFIX/script/upload.sh"
audio_cleanup()
{
    [ -z "$AUDIO_ROOT" ] || rm -rf "$AUDIO_ROOT"
    lock_release /tmp/yi-audio-work.lock.d
}
audio_begin()
{
    [ "$(config_get SPEAKER_AUDIO)" = yes ] && [ ! -f /tmp/privacy ] && [ -p /tmp/audio_in_fifo ] || return 1
    sd_available || return 1
    lock_acquire /tmp/yi-audio-work.lock.d || return 1
    trap 'audio_cleanup' 0
    trap 'exit 1' 1 2 15
    umask 077
    AUDIO_ROOT=/tmp/sd/.yi-audio-work
    [ ! -L "$AUDIO_ROOT" ] || return 1
    rm -rf "$AUDIO_ROOT"
    mkdir "$AUDIO_ROOT"
}
audio_error()
{
    printf 'Content-type: application/json\r\n\r\n{"error":true,"description":"%s"}\n' "$1"
    exit 1
}
audio_ok()
{
    printf 'Content-type: application/json\r\n\r\n{"error":false,"description":"Playback complete"}\n'
}
audio_options()
{
    GAIN=1; VOICE=en-US; SPEED=1; PITCH=1
    local saved_ifs="$IFS" pair value
    IFS='&'
    for pair in ${QUERY_STRING:-}; do
        value=${pair#*=}
        case "$pair" in
            voldb=*) printf '%s\n' "$value" | grep -Eq '^-?[0-9]+([.][0-9]+)?$' || return 1
                GAIN=$(awk -v v="$value" 'BEGIN {if(v < -24 || v > 12) exit 1; print exp(v*log(10)/20)}') || return 1 ;;
            vol=*|volume=*) GAIN=$value ;; lang=*|voice=*) VOICE=$value ;; speed=*) SPEED=$value ;; pitch=*) PITCH=$value ;;
            action=*) ;; *) return 1 ;;
        esac
    done
    IFS="$saved_ifs"
    for value in "$GAIN" "$SPEED" "$PITCH"; do
        printf '%s\n' "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$' || return 1
    done
    awk -v g="$GAIN" -v s="$SPEED" -v p="$PITCH" 'BEGIN {exit !(g>=0 && g<=5 && s>=.2 && s<=5 && p>=.5 && p<=2)}' || return 1
    case "$VOICE" in en-US|en-GB|de-DE|es-ES|fr-FR|it-IT) ;; *) return 1 ;; esac
}
