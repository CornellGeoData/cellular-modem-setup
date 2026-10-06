#!/usr/bin/env bash
# cell_net_test.sh - test internet access using ONLY the cellular link.
# The SIM7000G makes the requests itself (AT+CNACT / AT+SNPING4 / AT+SH* HTTP client);
# the Pi just talks to it over USB serial, so WiFi and the Pi's routing are never used.
#
# Usage: ./cell_net_test.sh [http://host/path]   (default: http://api.ipify.org/ = your cellular public IP)
# If ModemManager is running, it is paused for the test and restarted afterwards (the cellular link
# drops meanwhile), even on errors, Ctrl-C or a dropped SSH session.
# Quicker test that leaves ModemManager alone: curl --interface ppp0 http://api.ipify.org/

set -euo pipefail

APN="linksnet"
NM_CON="kiwisim"     # NetworkManager connection to bring back up afterwards
URL="${1:-http://api.ipify.org/}"
BAUD=115200
PORT=""
FD=""
RESP=""
MM_PAUSED=0
NM_WAS_UP=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ModemManager holds ttyUSB2/ttyUSB3 for NetworkManager's cellular connection ($NM_CON).
# Stop it for the test; resume_modemmanager (exit trap) starts it again.
pause_modemmanager() {
    systemctl is-active --quiet ModemManager 2>/dev/null || return 0
    sudo -n true 2>/dev/null || die "ModemManager is running and holds the modem ports, and pausing it needs sudo.
  Fix: sudo systemctl stop ModemManager   run this script, then: sudo systemctl start ModemManager"

    if [[ $(nmcli -g GENERAL.STATE con show "$NM_CON" 2>/dev/null || true) == activated ]]; then NM_WAS_UP=1; fi
    if [[ $(ip route show default 2>/dev/null | head -1) == *" dev ppp0 "* ]]; then
        echo "WARNING: the Pi's internet is currently going over cellular (no WiFi). It will be offline until this test ends." >&2
    fi
    echo "Pausing ModemManager for the test (it is restarted on exit)..."
    sudo -n systemctl stop ModemManager || die "Couldn't stop ModemManager."
    MM_PAUSED=1
    sleep 2              # let pppd hang up and the ports close
}

resume_modemmanager() {
    local state i
    (( MM_PAUSED )) || return 0
    MM_PAUSED=0
    set +e               # best effort from here on: never stop before ModemManager is restarted
    if [[ -n $FD ]]; then
        # Close the modem's own data context (opened by this test) so it can't clash with ModemManager's PPP.
        at 'AT+CNACT=0' 10 >/dev/null 2>&1
        exec {FD}>&-
        FD=""
    fi
    echo "Restarting ModemManager..."
    if ! sudo -n systemctl start ModemManager; then
        echo "WARNING: couldn't restart ModemManager. Run: sudo systemctl start ModemManager" >&2
        return 0
    fi
    (( NM_WAS_UP )) || return 0

    echo "Waiting for the cellular connection '$NM_CON' to come back (up to ~90 s)..."
    for (( i = 1; i <= 45; i++ )); do
        state=$(nmcli -g GENERAL.STATE con show "$NM_CON" 2>/dev/null)
        if [[ $state == activated ]]; then
            echo "Cellular connection '$NM_CON' is back up."
            return 0
        fi
        # Autoconnect normally handles this; nudge it if nothing is happening after ~40 s.
        if (( i == 20 )) && [[ -z $state ]]; then sudo -n nmcli con up "$NM_CON" >/dev/null 2>&1; fi
        sleep 2
    done
    echo "WARNING: '$NM_CON' isn't back up yet. Check: nmcli device status   Retry: sudo nmcli con up $NM_CON" >&2
}

# at CMD [TIMEOUT]: send CMD, collect reply lines in RESP. Returns 0 on OK, 1 on ERROR, 2 on timeout.
at() {
    local line end
    RESP=""
    while IFS= read -r -t 0.2 -u "$FD" _; do :; done   # drop leftover/unsolicited lines
    printf '%s\r' "$1" >&"$FD"
    end=$((SECONDS + ${2:-5}))
    while (( SECONDS < end )); do
        IFS= read -r -t 1 -u "$FD" line || continue
        line=${line//$'\r'/}
        [[ -n $line ]] || continue
        RESP+="$line"$'\n'
        case $line in
            OK) return 0 ;;
            ERROR | "+CME ERROR"*) return 1 ;;
        esac
    done
    return 2
}

# wait_for PREFIX TIMEOUT: wait for a line starting with PREFIX (results that arrive after OK) and print it.
wait_for() {
    local line end=$((SECONDS + $2))
    while (( SECONDS < end )); do
        IFS= read -r -t 1 -u "$FD" line || continue
        line=${line//$'\r'/}
        if [[ $line == "$1"* ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done
    return 1
}

find_port() {
    local p
    for p in /dev/ttyUSB*; do
        [[ -e $p ]] || continue
        timeout 2 stty -F "$p" "$BAUD" raw -echo clocal -hupcl 2>/dev/null || true
        # shellcheck disable=SC2016  # the inner script expands its own variables
        if timeout 5 bash -c '
            exec 3<>"$1"
            for _ in 1 2; do
                printf "AT\r" >&3
                end=$((SECONDS + 2))
                while (( SECONDS < end )); do
                    IFS= read -r -t 1 -u 3 line || continue
                    [[ $line == OK* ]] && exit 0
                done
            done
            exit 1' _ "$p"; then
            PORT=$p
            return 0
        fi
    done
    die "No /dev/ttyUSB* port answered AT. Is the modem on USB, and is nothing else (minicom, ModemManager) using it?"
}

# 1. Modem data connection (the modem's own, not the Pi's)
ensure_data() {
    local v ip=""
    at 'AT+CNACT?' || true
    if [[ $RESP != *'+CNACT: 1,'* ]]; then
        echo "Opening the modem's data connection (APN $APN)..."
        at "AT+CNACT=1,\"$APN\"" 30 || true
    fi
    for _ in {1..10}; do
        at 'AT+CNACT?' || true
        v=$(grep -m1 '^+CNACT:' <<<"$RESP" || true)
        if [[ $v =~ ^\+CNACT:\ 1,\"([0-9.]+)\" && ${BASH_REMATCH[1]} != 0.0.0.0 ]]; then
            ip=${BASH_REMATCH[1]}
            break
        fi
        sleep 3
    done
    [[ -n $ip ]] || die "The modem has no data connection (last: ${v:-no reply}). Is it registered? Try ./connect_minicom.sh --check"
    echo "[ok] Modem data connection up, cellular IP $ip"
}

# 2. Ping from the modem
ping_test() {
    local n
    at 'AT+SNPING4="8.8.8.8",3,16,1000' 20 || true
    n=$(grep -c '^+SNPING4:' <<<"$RESP" || true)
    if (( n > 0 )); then
        echo "[ok] Ping 8.8.8.8: $n/3 replies ($(grep '^+SNPING4:' <<<"$RESP" | cut -d, -f3 | paste -sd/) ms)"
    else
        echo "[FAIL] Ping 8.8.8.8: no replies"
    fi
}

# 3. HTTP GET with the modem's built-in HTTP client
http_test() {
    local base path res status len line
    [[ $URL =~ ^(http://[^/]+)(/.*)?$ ]] || die "URL must be plain http://host/path (https needs certificate setup on the modem)."
    base=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]:-/}

    at 'AT+SHDISC' || true                        # clear any leftover HTTP session
    at "AT+SHCONF=\"URL\",\"$base\"" || die "AT+SHCONF URL failed: ${RESP//$'\n'/ }"
    at 'AT+SHCONF="BODYLEN",1024' || true
    at 'AT+SHCONF="HEADERLEN",350' || true
    if ! at 'AT+SHCONN' 30; then
        echo "[FAIL] HTTP: couldn't connect to $base (DNS or network problem): ${RESP//$'\n'/ }"
        return 0
    fi
    at "AT+SHREQ=\"$path\",1" 10 || true           # 1 = GET; result arrives later as +SHREQ: "GET",<status>,<len>
    if ! res=$(wait_for '+SHREQ:' 30); then
        echo "[FAIL] HTTP: no response to GET $URL"
        at 'AT+SHDISC' || true
        return 0
    fi
    IFS=, read -r _ status len <<<"$res"
    echo "[ok] HTTP GET $URL -> status $status, $len bytes"

    if (( len > 0 )); then
        (( len > 1024 )) && len=1024
        at "AT+SHREAD=0,$len" 10 || true
        if wait_for '+SHREAD:' 10 >/dev/null; then
            echo "----- response body (first $len bytes) -----"
            while :; do
                if IFS= read -r -t 2 -u "$FD" line; then
                    printf '%s\n' "${line//$'\r'/}"
                else
                    [[ -n $line ]] && printf '%s\n' "${line//$'\r'/}"   # last line without a newline
                    break
                fi
            done
            echo "--------------------------------------------"
        fi
    fi
    at 'AT+SHDISC' || true
}

trap resume_modemmanager EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP   # SSH session dropped

pause_modemmanager
find_port
exec {FD}<>"$PORT"
echo "Modem AT port: $PORT"
ensure_data
ping_test
http_test
echo "All requests above were made by the modem over the cellular network (the Pi's WiFi was not used)."
