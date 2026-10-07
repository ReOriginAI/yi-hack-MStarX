#!/bin/sh
# Validate only; committing settings belongs to the serialized CGI caller.
[ "$#" -eq 2 ] || exit 2
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/home/yi-hack}
ARCHIVE=$1
DEST=$2
[ "$(wc -c < "$ARCHIVE")" -le 65536 ] || exit 1
(ulimit -f 1024 || exit 1; bzip2 -dc "$ARCHIVE" > "$DEST/config.tar") 2>/dev/null || exit 1
"$YI_HACK_PREFIX/bin/archive_check" config "$DEST/config.tar" "$YI_HACK_PREFIX" || exit 1
mkdir "$DEST/unpacked" || exit 1
(ulimit -f 128 || exit 1; cd "$DEST/unpacked" && tar -xf "$DEST/config.tar") 2>/dev/null || exit 1
