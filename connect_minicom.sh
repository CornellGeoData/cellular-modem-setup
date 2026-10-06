#!/usr/bin/env bash
# connect_minicom.sh - bring up the SIM7000G HAT over USB, register it on LTE-M / NB-IoT,
# pause so the SIM can be activated, test data, then optionally hand off to minicom.
#
# Usage: ./connect_minicom.sh             full interactive run
#        ./connect_minicom.sh --check     detection + read-only status only (changes no modem settings)
#        ./connect_minicom.sh --minicom   just open minicom on the AT port
# If ModemManager is running, it is paused for the run and restarted afterwards (the cellular link
# drops meanwhile), even on errors, Ctrl-C or a dropped SSH session.

# ---- user settings ---------------------------------------------------------
APN_NAME="kiwisim"
APN="linksnet"
APN_USER=""
APN_PASS=""
NM_CON="kiwisim"              # NetworkManager connection to bring back up afterwards
# ----------------------------------------------------------------------------

set -euo pipefail

BAUD=115200
REG_TIMEOUT=180               # seconds to wait for registration in each mode
POLL_INTERVAL=10
REQUIRED_BANDS=(2 4 12 13)    # US bands for Cat-M and NB-IoT
MODES=("1:Cat-M" "2:NB-IoT" "3:Cat-M + NB-IoT")   # AT+CMNB value : label
LOG_DIR="$HOME/cell_logs"
LOG="$LOG_DIR/connect_$(date +%Y%m%d_%H%M%S).log"

CHECK_ONLY=0
MINICOM_ONLY=0
MM_PAUSED=0      # 1 once we stopped ModemManager (so the exit trap restarts it)
NM_WAS_UP=0      # 1 if NM_CON was active before we paused ModemManager
PORT=""
MODEM_FD=""
RESP=""          # reply lines from the last AT command
SUMMARY=()       # one line per failed mode, for the final diagnosis
SAW_SIGNAL=0
SAW_DENIED=0

# ---- output helpers ----------------------------------------------------------

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }
say()  { printf '%s\n' "$*"; log "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; log "WARNING: $*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; log "ERROR: $*"; printf 'Log: %s\n' "$LOG" >&2; exit 1; }

ask_yes() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ $reply == [yY]* ]]
}

# ---- serial I/O --------------------------------------------------------------

# Log and discard anything the modem sent unprompted (SMS Ready, DST, *PSUTTZ, ...).
drain() {
    local line
    while IFS= read -r -t 0.2 -u "$MODEM_FD" line; do
        line=${line//$'\r'/}
        if [[ -n $line ]]; then log "<< (unsolicited) $line"; fi
    done
    return 0
}

# Read reply lines into RESP until OK / ERROR or the deadline.
# Returns 0 on OK, 1 on ERROR, 2 on timeout.
read_reply() {
    local wait=$1 chunk partial="" line end
    end=$((SECONDS + wait))
    while (( SECONDS < end )); do
        if ! IFS= read -r -t 1 -u "$MODEM_FD" chunk; then
            partial+=$chunk      # keep a line that straddled the 1 s read timeout
            [[ -e $PORT ]] || die "$PORT disappeared: the modem reset or dropped off USB (check: dmesg | tail)."
            continue
        fi
        line=${partial}${chunk}
        partial=""
        line=${line//$'\r'/}
        [[ -n $line ]] || continue
        # The modem echoes commands back; never let a PIN reach the log.
        [[ $line == AT+CPIN=* ]] && line='AT+CPIN="****"'
        log "<< $line"
        RESP+="$line"$'\n'
        case $line in
            OK) return 0 ;;
            ERROR | "+CME ERROR"* | "+CMS ERROR"*) return 1 ;;
        esac
    done
    log "!! no OK/ERROR within ${wait}s"
    return 2
}

# at_raw CMD TIMEOUT SHOWN: send CMD, log SHOWN instead (lets the PIN be masked).
at_raw() {
    RESP=""
    drain
    log ">> $3"
    printf '%s\r' "$1" >&"$MODEM_FD"
    read_reply "$2"
}

at_cmd() { at_raw "$1" "${2:-5}" "$1"; }

# resp_value PREFIX [TEXT]: first line of TEXT (default RESP) starting with PREFIX, minus the prefix.
resp_value() {
    local line
    while IFS= read -r line; do
        if [[ $line == "$1"* ]]; then
            printf '%s\n' "${line#"$1"}"
            return 0
        fi
    done <<<"${2-$RESP}"
    return 0
}

# First all-digit line of RESP (IMEI from AT+GSN, ICCID from AT+CCID).
resp_digits() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9]{10,}[0-9A-Fa-f]*$ ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done <<<"$RESP"
    return 0
}

# ---- interpreting replies ------------------------------------------------------

cereg_stat() {   # "+CEREG: 0,5" -> 5
    local v stat
    v=$(resp_value "+CEREG: ")
    IFS=, read -r _ stat _ <<<"$v"
    printf '%s\n' "${stat:-}"
}

stat_text() {
    case ${1:-} in
        0) echo "not searching" ;;
        1) echo "registered, home" ;;
        2) echo "searching" ;;
        3) echo "DENIED" ;;
        4) echo "unknown" ;;
        5) echo "registered, roaming" ;;
        *) echo "no answer" ;;
    esac
}

signal_text() {  # "17,99" or "17" -> "CSQ 17 (~-79 dBm, good)"
    local rssi=${1%%,*} dbm q
    if [[ ! $rssi =~ ^[0-9]+$ || $rssi == 99 ]]; then
        echo "no signal (CSQ 99)"
        return 0
    fi
    dbm=$(( -113 + 2 * rssi ))
    if   (( rssi >= 20 )); then q=excellent
    elif (( rssi >= 15 )); then q=good
    elif (( rssi >= 10 )); then q=fair
    else q=poor
    fi
    echo "CSQ $rssi (~${dbm} dBm, $q)"
}

# Run a read-only query and print its reply on one line (used by --check).
show() {
    local line out=()
    at_cmd "$1" "${2:-5}" || true
    while IFS= read -r line; do
        [[ -z $line || $line == OK || $line == "$1" ]] && continue
        out+=("$line")
    done <<<"$RESP"
    printf '  %-16s %s\n' "$1" "${out[*]:-(no reply)}"
}

# ---- steps -------------------------------------------------------------------

modem_on_usb() {
    if command -v lsusb >/dev/null; then
        [[ $(lsusb) == *"ID 1e0e:"* ]]
    else
        grep -qsx 1e0e /sys/bus/usb/devices/*/idVendor
    fi
}

preflight() {
    local waited=0 holders pid

    if [[ " $(id -nG) " != *" dialout "* ]]; then
        die "User $USER is not in the dialout group, so it can't open the serial ports.
  Fix: sudo usermod -aG dialout $USER   then log out and back in (or reboot)."
    fi

    until modem_on_usb && compgen -G '/dev/ttyUSB*' >/dev/null; do
        if (( waited >= 20 )); then
            die "No SIMCom modem (USB vendor 1e0e) with /dev/ttyUSB* ports after 20 s.
  Fix: the HAT's micro-USB must go to the Pi's USB *data* port, and the modem must be powered on
  (PWR LED lit; press the HAT's PWRKEY). If it keeps appearing and vanishing, check: dmesg | tail -20"
        fi
        if (( waited == 0 )); then say "Waiting for the modem to show up on USB..."; fi
        sleep 2
        waited=$((waited + 2))
    done
    say "SIMCom modem found on USB."

    pause_modemmanager

    if command -v fuser >/dev/null; then
        holders=$(fuser /dev/ttyUSB* 2>/dev/null || true)
        if [[ -n ${holders//[[:space:]]/} ]]; then
            say "These processes have a modem port open:"
            for pid in $holders; do ps -o pid=,user=,args= -p "$pid" || true; done
            die "Close them first (e.g. quit minicom/screen), then run this again."
        fi
    fi
}

# ModemManager holds ttyUSB2/ttyUSB3 for NetworkManager's cellular connection ($NM_CON).
# Stop it for the run; resume_modemmanager (exit trap) starts it again.
pause_modemmanager() {
    systemctl is-active --quiet ModemManager 2>/dev/null || return 0
    sudo -n true 2>/dev/null || die "ModemManager is running and holds the modem ports, and pausing it needs sudo.
  Fix: sudo systemctl stop ModemManager   run this script, then: sudo systemctl start ModemManager"

    if [[ $(nmcli -g GENERAL.STATE con show "$NM_CON" 2>/dev/null || true) == activated ]]; then NM_WAS_UP=1; fi
    if [[ $(ip route show default 2>/dev/null | head -1) == *" dev ppp0 "* ]]; then
        warn "The Pi's internet is currently going over cellular (no WiFi). It will be offline until this script ends."
    fi
    say "Pausing ModemManager while this script uses the modem (it is restarted on exit)..."
    sudo -n systemctl stop ModemManager || die "Couldn't stop ModemManager."
    MM_PAUSED=1
    sleep 2              # let pppd hang up and the ports close
}

resume_modemmanager() {
    local state i
    (( MM_PAUSED )) || return 0
    MM_PAUSED=0
    set +e               # best effort from here on: never stop before ModemManager is restarted
    if [[ -n $MODEM_FD ]]; then
        # Precaution: close the modem's own data context so it can't clash with ModemManager's PPP session.
        ( at_cmd 'AT+CNACT?' 5; [[ $RESP == *"+CNACT: 1,"* ]] && at_cmd 'AT+CNACT=0' 10 ) >/dev/null 2>&1
        exec {MODEM_FD}>&-
        MODEM_FD=""
    fi
    say "Restarting ModemManager..."
    if ! sudo -n systemctl start ModemManager; then
        warn "Couldn't restart ModemManager. Run: sudo systemctl start ModemManager"
        return 0
    fi
    (( NM_WAS_UP )) || return 0

    say "Waiting for the cellular connection '$NM_CON' to come back (up to ~90 s)..."
    for (( i = 1; i <= 45; i++ )); do
        state=$(nmcli -g GENERAL.STATE con show "$NM_CON" 2>/dev/null)
        if [[ $state == activated ]]; then
            say "Cellular connection '$NM_CON' is back up."
            return 0
        fi
        # Autoconnect normally handles this; nudge it if nothing is happening after ~40 s.
        if (( i == 20 )) && [[ -z $state ]]; then sudo -n nmcli con up "$NM_CON" >/dev/null 2>&1; fi
        sleep 2
    done
    warn "'$NM_CON' isn't back up yet. Check: nmcli device status   Retry: sudo nmcli con up $NM_CON"
}

# Exit 0 if PORT answers AT with OK. Runs under timeout so the GPS/NMEA port can't block us.
probe_port() {
    # USB serial ports can't apply every termios flag; stty complains but the port works.
    timeout 2 stty -F "$1" "$BAUD" raw -echo clocal -hupcl 2>/dev/null || true
    # shellcheck disable=SC2016  # the inner script expands its own variables
    timeout 5 bash -c '
        exec 3<>"$1"
        for _ in 1 2; do
            printf "AT\r" >&3
            end=$((SECONDS + 2))
            while (( SECONDS < end )); do
                IFS= read -r -t 1 -u 3 line || continue
                [[ $line == OK* ]] && exit 0
            done
        done
        exit 1' _ "$1"
}

detect_port() {
    local p
    for p in /dev/ttyUSB*; do
        printf 'Probing %s ... ' "$p"
        if probe_port "$p"; then
            echo "answers AT"
            PORT=$p
            log "AT port: $PORT"
            return 0
        fi
        echo "no"
    done
    die "No /dev/ttyUSB* port answered AT. The modem may still be booting (wait ~10 s and retry)
  or be resetting (check: dmesg | tail -20)."
}

open_port() {
    exec {MODEM_FD}<>"$PORT"
    stty -F "$PORT" "$BAUD" raw -echo clocal -hupcl 2>/dev/null || true
}

check_sim() {
    local state="" pin tries
    for tries in 1 2 3 4 5; do         # right after AT+CFUN=1 the SIM can report "busy" briefly
        at_cmd 'AT+CPIN?' 5 || true
        state=$(resp_value "+CPIN: ")
        [[ -n $state ]] && break
        [[ $RESP == *"+CME ERROR: 10"* ]] && break   # SIM not inserted
        log "SIM not ready yet (try $tries)"
        sleep 2
    done

    case $state in
        READY)
            say "SIM: ready" ;;
        "SIM PIN")
            if (( CHECK_ONLY )); then
                say "SIM: locked, needs its PIN (the full run will ask for it)"
                return 0
            fi
            read -r -s -p "SIM PIN required. Enter PIN (hidden): " pin
            echo
            if [[ ! $pin =~ ^[0-9]{4,8}$ ]]; then
                pin=""
                die "A SIM PIN is 4-8 digits. Nothing was sent to the SIM."
            fi
            if at_raw "AT+CPIN=\"$pin\"" 10 'AT+CPIN="****"'; then
                pin=""
                say "PIN accepted."
                sleep 3
            else
                pin=""
                die "The SIM rejected the PIN. Not retrying: 3 wrong PINs lock the SIM (PUK)."
            fi ;;
        "SIM PUK"*)
            die "The SIM is PUK-locked (too many wrong PINs). Get the PUK from KiwiSIM; this script won't enter it." ;;
        *)
            if [[ $RESP == *"+CME ERROR: 10"* ]]; then
                die "No SIM detected. Power off, reseat the SIM (contacts down, notch as marked on the HAT), and try again."
            fi
            die "Unexpected SIM state: '${state:-no answer}'. Details in $LOG" ;;
    esac
}

check_bands() {
    local cfg rat line b missing newlist
    at_cmd 'AT+CBANDCFG?' 5 || true
    cfg=$RESP
    for rat in CAT-M NB-IOT; do
        line=$(resp_value "+CBANDCFG: \"$rat\"," "$cfg")
        missing=()
        for b in "${REQUIRED_BANDS[@]}"; do
            [[ ",$line," == *",$b,"* ]] || missing+=("$b")
        done
        if (( ${#missing[@]} == 0 )); then
            say "Bands $rat: $line (includes ${REQUIRED_BANDS[*]})"
            continue
        fi
        warn "$rat band list '${line}' is missing US band(s): ${missing[*]}"
        (( CHECK_ONLY )) && continue
        if ask_yes "Add the missing bands to $rat (AT+CBANDCFG)?"; then
            newlist=$(printf '%s\n' "$line" "${missing[@]}" | tr ',' '\n' | grep . | sort -nu | paste -sd,)
            at_cmd "AT+CBANDCFG=\"$rat\",$newlist" 10 || warn "AT+CBANDCFG failed: ${RESP//$'\n'/ }"
        fi
    done
}

# try_mode CMNB LABEL: configure one mode, restart the radio, poll for registration.
try_mode() {
    local mode=$1 label=$2 start stat="" psi="" csq="" rssi best=99 status
    say ""
    say "=== Trying $label (AT+CMNB=$mode) ==="
    at_cmd 'AT+CNMP=38' 5 || warn "AT+CNMP=38 failed"
    at_cmd "AT+CMNB=$mode" 5 || warn "AT+CMNB=$mode failed"
    at_cmd "AT+CGDCONT=1,\"IP\",\"$APN\"" 5 || warn "AT+CGDCONT failed"
    say "Restarting the radio (AT+CFUN=0, AT+CFUN=1)..."
    at_cmd 'AT+CFUN=0' 15 || warn "AT+CFUN=0 failed"
    sleep 2
    at_cmd 'AT+CFUN=1' 15 || warn "AT+CFUN=1 failed"
    sleep 3
    check_sim

    say "Waiting up to ${REG_TIMEOUT}s for registration (polling every ${POLL_INTERVAL}s)..."
    start=$SECONDS
    while (( SECONDS - start <= REG_TIMEOUT )); do
        at_cmd 'AT+CEREG?' 5 || true
        stat=$(cereg_stat)
        at_cmd 'AT+CPSI?' 5 || true
        psi=$(resp_value "+CPSI: ")
        at_cmd 'AT+CSQ' 5 || true
        csq=$(resp_value "+CSQ: ")
        rssi=${csq%%,*}
        if [[ $rssi =~ ^[0-9]+$ ]] && (( rssi != 99 )); then
            SAW_SIGNAL=1
            if (( best == 99 || rssi > best )); then best=$rssi; fi
        fi
        printf -v status '  [%3ds] CEREG %s (%s) | %s | %s' "$((SECONDS - start))" \
            "${stat:-?}" "$(stat_text "$stat")" "$(signal_text "$csq")" "${psi:-no CPSI}"
        say "$status"
        case $stat in
            1 | 5) return 0 ;;
            3) SAW_DENIED=1; say "Registration denied in $label mode, moving on."; break ;;
        esac
        sleep "$POLL_INTERVAL"
    done
    SUMMARY+=("$label: last CEREG ${stat:-?} ($(stat_text "$stat")), best $(signal_text "$best"), last CPSI: ${psi:-none}")
    return 1
}

register() {
    local m stat
    at_cmd 'AT+CEREG?' 5 || true
    stat=$(cereg_stat)
    if [[ $stat == 1 || $stat == 5 ]]; then
        say "The modem is already registered ($(stat_text "$stat"))."
        if ! ask_yes "Redo the network setup anyway (restarts the radio)?"; then return 0; fi
    fi
    for m in "${MODES[@]}"; do
        if try_mode "${m%%:*}" "${m#*:}"; then return 0; fi
    done
    return 1
}

diagnose() {
    local s
    say ""
    say "!!! Could not register in any mode. What was seen:"
    for s in "${SUMMARY[@]}"; do say "  - $s"; done
    say ""
    if (( ! SAW_SIGNAL )); then
        say "Likely cause: no usable signal at all. Check that the LTE antenna is screwed onto the"
        say "HAT's main (LTE) connector, not GNSS, and try near a window. There may also be no"
        say "Cat-M/NB-IoT coverage here."
    elif (( SAW_DENIED )); then
        say "Likely cause: the network refused the SIM. That usually means it isn't activated yet or"
        say "the plan isn't provisioned for Cat-M/NB-IoT. Try activating it on KiwiSIM's website first,"
        say "then run this again, and ask KiwiSIM whether the plan supports LTE-M / NB-IoT."
    else
        say "Likely cause: there is signal but no registration. The SIM may need activating first, the plan"
        say "may not support Cat-M/NB-IoT on the local carrier, or coverage for these modes is weak here."
    fi
}

show_success() {
    local stat cops carrier="unknown" psi rat csq imei iccid
    at_cmd 'AT+CEREG?' 5 || true;  stat=$(cereg_stat)
    at_cmd 'AT+COPS?' 10 || true;  cops=$(resp_value "+COPS: ")
    if [[ $cops =~ \"([^\"]*)\" ]]; then carrier=${BASH_REMATCH[1]}; fi
    at_cmd 'AT+CPSI?' 5 || true;   psi=$(resp_value "+CPSI: ")
    rat=${psi%%,*}
    at_cmd 'AT+CSQ' 5 || true;     csq=$(resp_value "+CSQ: ")
    at_cmd 'AT+GSN' 5 || true;     imei=$(resp_digits)
    at_cmd 'AT+CCID' 5 || true;    iccid=$(resp_digits)

    say ""
    say "################################################################"
    say "#                                                              #"
    say "#          MODEM IS REGISTERED ON THE NETWORK                  #"
    say "#                                                              #"
    say "################################################################"
    say "  Carrier : $carrier"
    say "  Mode    : ${rat:-unknown}   (CEREG $stat: $(stat_text "$stat"))"
    say "  Signal  : $(signal_text "$csq")"
    say "  IMEI    : ${imei:-unknown}"
    say "  ICCID   : ${iccid:-unknown}"
    say "  APN     : $APN (profile $APN_NAME)"
    say ""
    say "  >>> Ready: you can now activate the SIM with the provider (KiwiSIM). <<<"
    say "  (KiwiSIM has no web form: using APN $APN with roaming allowed activates it,"
    say "   which the data test below does.)"
    say "################################################################"
}

test_data() {
    local reply v ip=""
    say ""
    read -r -p "Press Enter to test data / activate the SIM (or type s + Enter to skip): " reply
    if [[ $reply == [sS]* ]]; then say "Data test skipped."; return 0; fi

    at_cmd 'AT+CNACT?' 5 || true
    v=$(resp_value "+CNACT: ")
    if [[ $v != 1,* ]]; then
        say "Opening the modem's data connection (AT+CNACT=1)..."
        at_cmd "AT+CNACT=1,\"$APN\"" 30 || warn "AT+CNACT=1 returned: ${RESP//$'\n'/ }"
    fi
    for _ in {1..10}; do
        at_cmd 'AT+CNACT?' 5 || true
        v=$(resp_value "+CNACT: ")
        if [[ $v =~ ^1,\"([0-9.]+)\" && ${BASH_REMATCH[1]} != 0.0.0.0 ]]; then
            ip=${BASH_REMATCH[1]}
            break
        fi
        sleep 3
    done
    if [[ -z $ip ]]; then
        warn "No IP address after ~30 s (last AT+CNACT?: ${v:-no reply}). If you just activated the SIM,"
        warn "wait a few minutes and run the script again; activation can take a while to reach the network."
        return 0
    fi
    say "Data connection up. Modem IP: $ip"

    say "Pinging 8.8.8.8 from the modem..."
    at_cmd 'AT+SNPING4="8.8.8.8",3,16,1000' 20 || true
    if [[ $RESP == *"+SNPING4:"* ]]; then
        say "Ping replies (id,ip,ms):"
        grep '^+SNPING4:' <<<"$RESP" | while IFS= read -r v; do say "  $v"; done
        say "Data works."
    else
        warn "No ping replies: ${RESP//$'\n'/ }"
    fi
}

check_report() {
    say ""
    say "Read-only status:"
    show 'AT+CNMP?'
    show 'AT+CMNB?'
    show 'AT+CGDCONT?'
    show 'AT+CEREG?'
    show 'AT+CPSI?'
    show 'AT+COPS?' 10
    show 'AT+CSQ'
    show 'AT+GSN'
    show 'AT+CCID'
    show 'AT+CNACT?'
}

# Run minicom as a child (not exec), so the exit trap still restarts ModemManager afterwards.
run_minicom() {
    if ! command -v minicom >/dev/null; then
        say "minicom isn't installed (sudo apt install minicom). The AT port is $PORT."
        return 0
    fi
    exec {MODEM_FD}>&-
    MODEM_FD=""
    log "Running: minicom -D $PORT -b $BAUD"
    minicom -D "$PORT" -b "$BAUD" || true
}

offer_minicom() {
    say ""
    if ask_yes "Open minicom on $PORT now? (quit with Ctrl-A then X)"; then
        run_minicom
    else
        say "Later, run: ./connect_minicom.sh --minicom"
    fi
}

# ---- main --------------------------------------------------------------------

case ${1:-} in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    --minicom) MINICOM_ONLY=1 ;;
    -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
esac

mkdir -p "$LOG_DIR"
log "connect_minicom.sh started (check_only=$CHECK_ONLY, minicom_only=$MINICOM_ONLY, APN=$APN)"
say "Log: $LOG"
if [[ -n $APN_USER || -n $APN_PASS ]]; then
    warn "APN_USER/APN_PASS are set, but this script doesn't send them (KiwiSIM doesn't need them)."
fi

trap resume_modemmanager EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP   # SSH session dropped

preflight
detect_port
open_port

if (( MINICOM_ONLY )); then
    say "Opening minicom on $PORT (quit with Ctrl-A then X)..."
    run_minicom
    exit 0
fi

at_cmd 'AT' 5 || die "$PORT stopped answering AT."
at_cmd 'ATI' 5 || true
say "Modem: $(grep -m1 '^SIM' <<<"$RESP" || echo unknown)"   # e.g. "SIM7000G R1529"
check_sim
at_cmd 'AT+CSQ' 5 || true
say "Signal: $(signal_text "$(resp_value "+CSQ: ")")"
check_bands

if (( CHECK_ONLY )); then
    check_report
    say ""
    say "Check done (no modem settings were changed). AT port: $PORT"
    exit 0
fi

if register; then
    show_success
    test_data
else
    diagnose
fi
offer_minicom
say "Log: $LOG"
