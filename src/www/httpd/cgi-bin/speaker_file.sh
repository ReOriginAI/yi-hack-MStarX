#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/audio_work.sh"
audio_options || audio_error 'Invalid audio options'
audio_begin || audio_error 'Speaker busy, disabled, or SD unavailable'
upload_read 128 "$AUDIO_ROOT/name" || audio_error 'Invalid file name'
NAME=$(cat "$AUDIO_ROOT/name")
# Only one top-level SD audio file. Reject symlinks and path traversal.
printf '%s\n' "$NAME" | grep -Eq '^[A-Za-z0-9_-][A-Za-z0-9_.-]*[.](wav|pcm)$' || audio_error 'Invalid file name'
FILE="/tmp/sd/audio/$NAME"
[ -f "$FILE" ] && [ ! -L "$FILE" ] && [ ! -L /tmp/sd/audio ] || audio_error 'Audio file not found'
"$YI_HACK_PREFIX/bin/speaker" play "$FILE" "$GAIN" || audio_error 'Audio playback failed'
audio_ok
