#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/audio_work.sh"
if [ "${QUERY_STRING:-}" = action=stop ]; then
    "$YI_HACK_PREFIX/bin/speaker" stop || audio_error 'Unable to stop playback'
    audio_ok; exit
fi
audio_options || audio_error 'Invalid audio options'
audio_begin || audio_error 'Speaker busy, disabled, or SD unavailable'
upload_read 4198400 "$AUDIO_ROOT/body" || audio_error 'Upload too large or incomplete'
upload_extract "$AUDIO_ROOT/body" "$AUDIO_ROOT/input" || audio_error 'Invalid upload'
"$YI_HACK_PREFIX/bin/speaker" play "$AUDIO_ROOT/input" "$GAIN" || audio_error 'Unsupported audio format, busy speaker, or playback failed'
audio_ok
