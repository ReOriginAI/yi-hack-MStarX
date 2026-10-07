#!/bin/sh
. "$YI_HACK_PREFIX/script/runtime.sh"

config_work_begin()
{
    sd_available || return 1
    CONFIG_LOCK=/tmp/yi-config-work.lock.d
    lock_acquire "$CONFIG_LOCK" || return 1
    trap 'config_work_cleanup' 0
    trap 'exit 1' 1 2 15
    umask 077
    # MStar's prefix is internal FLASH, so it must never be used for staging.
    CONFIG_ROOT=/tmp/sd/.yi-config-work
    [ ! -L "$CONFIG_ROOT" ] || return 1
    rm -rf "$CONFIG_ROOT" || return 1
    mkdir "$CONFIG_ROOT" || return 1
    CONFIG_WORK="$CONFIG_ROOT/request"
    mkdir "$CONFIG_WORK"
}

config_work_cleanup()
{
    for FILE in ${CONFIG_FLASH_FILES:-}; do
        rm -f "$YI_HACK_PREFIX/etc/.$FILE.restore" "$YI_HACK_PREFIX/etc/.$FILE.new"
    done
    [ -z "$CONFIG_ROOT" ] || rm -rf "$CONFIG_ROOT"
    [ -z "$CONFIG_LOCK" ] || lock_release "$CONFIG_LOCK"
}
