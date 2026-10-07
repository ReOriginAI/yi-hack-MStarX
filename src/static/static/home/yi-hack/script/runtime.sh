#!/bin/sh
# Shared BusyBox helpers. Never source camera configuration as shell code.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
export PATH="$YI_HACK_PREFIX/bin:$YI_HACK_PREFIX/sbin:/home/base/tools:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"
export LD_LIBRARY_PATH="$YI_HACK_PREFIX/lib:/home/lib:/home/ms:/home/app/locallib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

config_get()
{
    local line
    line=$(grep -m 1 "^$1=" "$YI_HACK_PREFIX/etc/${2:-system.conf}" 2>/dev/null)
    printf '%s\n' "${line#*=}"
}

sd_available()
{
    awk '$2 == "/tmp/sd" && $1 ~ /^\/dev\// && $3 != "tmpfs" && $4 ~ /(^|,)rw(,|$)/ {found=1} END {exit !found}' /proc/mounts
}

# The camera's ps has PID USER TIME COMMAND. Handle paths and {script.sh}
# without matching arguments, grep processes, or unrelated executable names.
process_pids()
{
    ps | awk -v name="$1" '
        NR>1 { cmd=$4; gsub(/[{}]/,"",cmd); sub(/^.*\//,"",cmd)
            if (cmd == name) print $1 }
    '
}

process_count()
{
    process_pids "$1" | awk 'END {print NR+0}'
}

# One lock owner per operation. Stale lock recovery itself is serialized.
# A missing pid is never assumed dead: the creator may still be publishing it.
lock_acquire()
{
    local path="$1" attempts="${2:-0}" owner
    while ! mkdir "$path" 2>/dev/null; do
        if mkdir "$path.recover" 2>/dev/null; then
            owner=$(cat "$path/pid" 2>/dev/null)
            case "$owner" in
                ''|*[!0-9]*) ;;
                *) if ! kill -0 "$owner" 2>/dev/null; then
                       rm -f "$path/pid"
                       rmdir "$path" 2>/dev/null
                   fi ;;
            esac
            rmdir "$path.recover" 2>/dev/null
        fi
        [ "$attempts" -gt 0 ] || return 1
        attempts=$((attempts - 1))
        sleep 1
    done
    printf '%s\n' "$$" > "$path/pid" || { rmdir "$path"; return 1; }
}

lock_release()
{
    [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$1/pid"
    rmdir "$1" 2>/dev/null
}

valid_port()
{
    case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
