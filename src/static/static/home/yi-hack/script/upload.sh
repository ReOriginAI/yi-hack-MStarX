#!/bin/sh
# Read a bounded, length-delimited body and strip one multipart upload.
# Caller owns the private SD staging directory and cleanup trap.
upload_read()
{
    local max="$1" file="$2"
    [ "${REQUEST_METHOD:-}" = POST ] || return 1
    case "${CONTENT_LENGTH:-}" in ''|*[!0-9]*|?????????*) return 1 ;; esac
    [ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le "$max" ] || return 1
    # dd can return success at early EOF; verify the actual body length.
    head -c "$CONTENT_LENGTH" > "$file" || return 1
    [ "$(wc -c < "$file")" -eq "$CONTENT_LENGTH" ]
}

upload_extract()
{
    local input="$1" output="$2" boundary start trailer length actual
    case "${CONTENT_TYPE:-}" in
        multipart/form-data\;*)
            # Parse bounded ASCII headers until the first empty CRLF line.
            start=$(awk 'NR<=20 {n+=length($0)+1; if ($0=="\r") {print n; exit}} NR>20 {exit}' "$input")
            case "$start" in ''|*[!0-9]*) return 1 ;; esac
            [ "$start" -le 4096 ] || return 1
            boundary=$(sed -n '1p' "$input" | tr -d '\r')
            case "$boundary" in --*) ;; *) return 1 ;; esac
            [ "${#boundary}" -le 200 ] || return 1
            trailer=$((${#boundary}+6))
            actual=$(tail -c "$trailer" "$input")
            [ "$actual" = "$(printf '\r\n%s--\r\n' "$boundary")" ] || return 1
            length=$(($(wc -c < "$input")-start-trailer))
            [ "$length" -gt 0 ] || return 1
            dd if="$input" of="$output" bs=1 skip="$start" count="$length" 2>/dev/null
            ;;
        *) cp "$input" "$output" ;;
    esac
}
