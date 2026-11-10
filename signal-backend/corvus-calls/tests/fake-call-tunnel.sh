#!/bin/sh
# A scripted stand-in for signal-call-tunnel, used by tests/tunnel.rs.
#
#   fake-call-tunnel.sh SCRIPT LOG
#
# Every stdin line (the config line, then commands) is appended to LOG as it is read. SCRIPT is run
# one line at a time:
#   expect TYPE   read stdin until a line with "type":"TYPE" (TYPE "config": a line with "call_id")
#   emit JSON     write JSON as one stdout line
#   sleep SECS
#   exit CODE     exit at once (stdin is not drained)
# When SCRIPT is done, the rest of stdin is logged until EOF, then the fake exits 0, like the real
# tunnel when its control channel closes.
script=$1
log=$2
: > "$log"

expect() {
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$log"
        case "$1" in
            config) case "$line" in *'"call_id"'*) return 0 ;; esac ;;
            *) case "$line" in *"\"type\":\"$1\""*) return 0 ;; esac ;;
        esac
    done
    echo "fake tunnel: EOF while waiting for $1" >&2
    exit 3
}

while IFS= read -r step <&3; do
    case "$step" in
        'expect '*) expect "${step#expect }" ;;
        'emit '*) printf '%s\n' "${step#emit }" ;;
        'sleep '*) sleep "${step#sleep }" ;;
        'exit '*) exit "${step#exit }" ;;
        '' | '#'*) ;;
        *) echo "fake tunnel: bad step: $step" >&2; exit 2 ;;
    esac
done 3< "$script"

while IFS= read -r line; do
    printf '%s\n' "$line" >> "$log"
done
exit 0
