#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
CONF_FILE=etc/camera.conf
. "$YI_HACK_PREFIX/script/config_work.sh"
. "$YI_HACK_PREFIX/script/upload.sh"
get_config() { config_get "$1" camera.conf; }
fail() { printf 'Content-type: text/html\r\n\r\nUpload failed\r\n'; exit 1; }
config_work_begin || fail
upload_read 73728 "$CONFIG_WORK/body" || fail
upload_extract "$CONFIG_WORK/body" "$CONFIG_WORK/config.tar.bz2" || fail
"$YI_HACK_PREFIX/script/restore_config.sh" "$CONFIG_WORK/config.tar.bz2" "$CONFIG_WORK" || fail
# All entries are now validated regular files. Prepare replacements first,
# retaining SD backups for rollback if committing a file fails.
mkdir "$CONFIG_WORK/backup" || fail
for FILE in "$CONFIG_WORK"/unpacked/*; do
    NAME=${FILE##*/}
    [ ! -f "$YI_HACK_PREFIX/etc/$NAME" ] || cp "$YI_HACK_PREFIX/etc/$NAME" "$CONFIG_WORK/backup/$NAME" || fail
    CONFIG_FLASH_FILES="$CONFIG_FLASH_FILES $NAME"
    cp "$FILE" "$YI_HACK_PREFIX/etc/.$NAME.restore" || fail
    chmod 0644 "$YI_HACK_PREFIX/etc/.$NAME.restore" || fail
done
for FILE in "$CONFIG_WORK"/unpacked/*; do
    NAME=${FILE##*/}
    if ! mv -f "$YI_HACK_PREFIX/etc/.$NAME.restore" "$YI_HACK_PREFIX/etc/$NAME"; then
        for ORIGINAL in "$CONFIG_WORK"/unpacked/*; do
            ORIGINAL_NAME=${ORIGINAL##*/}
            if [ -f "$CONFIG_WORK/backup/$ORIGINAL_NAME" ]; then
                cp "$CONFIG_WORK/backup/$ORIGINAL_NAME" "$YI_HACK_PREFIX/etc/$ORIGINAL_NAME"
            else
                rm -f "$YI_HACK_PREFIX/etc/$ORIGINAL_NAME"
            fi
        done
        fail
    fi
done
printf 'Content-type: text/html\r\n\r\nUpload completed successfully, restart your camera\r\n'
# Set camera settings
if [[ $(get_config SWITCH_ON) == "no" ]] ; then
    ipc_cmd -t off
else
    ipc_cmd -t on
fi

if [[ $(get_config SAVE_VIDEO_ON_MOTION) == "no" ]] ; then
    ipc_cmd -v always
else
    ipc_cmd -v detect
fi

ipc_cmd -s $(get_config SENSITIVITY)

if [[ $(get_config LED) == "no" ]] ; then
    ipc_cmd -l off
else
    ipc_cmd -l on
fi

if [[ $(get_config IR) == "no" ]] ; then
    ipc_cmd -i off
else
    ipc_cmd -i on
fi

if [[ $(get_config ROTATE) == "no" ]] ; then
    ipc_cmd -r off
else
    ipc_cmd -r on
fi
