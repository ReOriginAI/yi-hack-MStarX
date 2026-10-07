#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
case "${1:-}" in
    on|yes) ACTION=on ;; off|no) ACTION=off ;; status) ACTION=status ;; *) exit 2 ;;
esac
exec "$YI_HACK_PREFIX/script/service.sh" privacy "$ACTION"
