#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
. "$YI_HACK_PREFIX/script/audio_work.sh"
audio_options || audio_error 'Invalid speech options'
audio_begin || audio_error 'Speaker busy, disabled, or SD unavailable'
NANOTTS=/tmp/sd/yi-hack/bin/nanotts
LANG_DIR=/tmp/sd/yi-hack/usr/share/pico/lang
[ -x "$NANOTTS" ] && [ -d "$LANG_DIR" ] || audio_error 'Install the SD companion for offline speech'
upload_read 1024 "$AUDIO_ROOT/text" || audio_error 'Text empty, too long, or incomplete'
TEXT=$(cat "$AUDIO_ROOT/text")
[ -n "$TEXT" ] || audio_error 'Text is empty'
# Explicit SD staging and a file limit bound even very slow/long synthesis.
(ulimit -f 4096 || exit 1; "$NANOTTS" -l "$LANG_DIR" -v "$VOICE" --speed "$SPEED" --pitch "$PITCH" -c < "$AUDIO_ROOT/text" > "$AUDIO_ROOT/speech.pcm" 2>/dev/null) || audio_error 'Speech synthesis failed'
"$YI_HACK_PREFIX/bin/speaker" play "$AUDIO_ROOT/speech.pcm" "$GAIN" || audio_error 'Audio playback failed'
audio_ok
