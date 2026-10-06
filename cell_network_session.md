# Cellular network session: SIM7000G on the Pi Zero 2

## Summary / quick reference (status: working, updated 2026-10-04)

**Result:** the KiwiSIM is active. The modem registers roaming on **AT&T, LTE Cat-M1, band 12**
(CSQ 21-24, about -70 dBm). Since 2026-10-04 it's also a **NetworkManager connection (`kiwisim`, interface `ppp0`)**
that any program can use. It's a lower-priority fallback: traffic only goes over cellular when WiFi is down
(cellular IP `100.x.x.x`, public IP `<cellular-public-ip>`).

| Item | Value |
|---|---|
| Pi | `<user>@<pi-ip>` (Pi Zero 2 WH, key-auth SSH over WiFi) |
| Modem | Waveshare SIM7000G HAT, `SIM7000G R1529`, USB `1e0e:9001` |
| AT port | `/dev/ttyUSB2` (first to answer; ttyUSB3 also answers). Scripts detect it automatically. |
| PPP port | `/dev/ttyUSB3` (ModemManager dials PPP here; see the udev rule below) |
| NM connection | `kiwisim` → `ppp0`, route metric 1000 (WiFi: 600), autoconnect, retries forever |
| SIM | KiwiSIM, ICCID `<ICCID>`, no PIN |
| IMEI | `<IMEI>` |
| APN | `linksnet` (profile name `kiwisim`, no user/pass, roaming on); fallback APN `plus` |
| Network mode | `CNMP=38` (LTE only), `CMNB=1` (Cat-M) |

**Files** (in this folder; copies in `~/` on the Pi; pre-2026-10-04 versions in `old/` and `~/old/`, not committed):
- `connect_minicom.sh`: bring-up / registration / data test / minicom.
- `cell_net_test.sh`: tests internet access using **only** the cellular link (the modem makes the requests).
- `cell_network_session.md`: this file.

### How to run the scripts

Run everything from the laptop over SSH. Quote the `~` so it expands on the Pi, not on the laptop. Use `ssh -t`
for anything interactive (prompts, minicom).

```bash
# Day to day: nothing to run. NetworkManager keeps cellular up as a fallback for WiFi.
ssh <user>@<pi-ip> 'nmcli device status; ip route | grep default'      # status
ssh <user>@<pi-ip> 'curl -s --interface ppp0 http://api.ipify.org'     # quick cellular test (no disruption)

# Scripts (each one pauses ModemManager and restores it automatically):
ssh    <user>@<pi-ip> '~/connect_minicom.sh --check'    # read-only modem status (no modem settings changed)
ssh    <user>@<pi-ip> '~/cell_net_test.sh'              # modem-only ping + HTTP test
ssh    <user>@<pi-ip> '~/cell_net_test.sh http://example.com/'   # any plain-http URL
ssh -t <user>@<pi-ip> '~/connect_minicom.sh --minicom'  # manual AT commands in minicom (quit: Ctrl-A, then X)
ssh -t <user>@<pi-ip> '~/connect_minicom.sh'            # full interactive bring-up (re-registration, bands, data test)
```
Logs from `connect_minicom.sh`: `~/cell_logs/connect_YYYYmmdd_HHMMSS.log` on the Pi.

**What the scripts do automatically.** ModemManager owns the modem's serial ports while NetworkManager's
cellular connection is up, so the scripts can't talk to the modem alongside it. Each script therefore:
1. **Before:** if ModemManager is running, notes whether `kiwisim` is up, then stops ModemManager (`sudo -n`; user
   `water` has passwordless sudo). If the Pi has no WiFi at that moment, it warns that the Pi will be **offline**
   for the run, because its only internet path is the cellular link being paused.
2. **After** (an exit trap, so it also runs on errors, Ctrl-C, and a dropped SSH session): closes the modem's own
   data context (`AT+CNACT=0`, a precaution), starts ModemManager again, and waits up to ~90 s for `kiwisim` to
   reconnect (running `nmcli con up` itself if autoconnect hasn't started after ~40 s).

Expect cellular to be down for the length of the run plus about 10-15 s. WiFi is never touched.
Tested 2026-10-04: normal runs of `cell_net_test.sh` and `--check`, `cell_net_test.sh` killed with SIGHUP mid-test,
and `--minicom` killed with SIGHUP. In every case ModemManager and `kiwisim` came back. The full interactive run
uses the same pause/restore code but hasn't been re-run since the change.

**Don't** run bare `minicom -D /dev/ttyUSB2 …` while ModemManager is running. It fights ModemManager for the port.
Use `--minicom`, or stop ModemManager yourself first: `sudo systemctl stop ModemManager` … `sudo systemctl start ModemManager`.
If a script is ever killed with SIGKILL (`kill -9`, power loss), the trap can't run. Run
`sudo systemctl start ModemManager` (a reboot also works, since ModemManager is enabled at boot).

**Key lessons**
1. **ModemManager must never open the QMI interface.** It reset the modem every ~5-11 s (USB reboot loop) via
   `cdc-wdm0`. Since 2026-10-04 ModemManager is back on, with a udev rule that hides QMI from it (see
   "NetworkManager integration" below). If the modem starts vanishing again, check that the rule
   `/etc/udev/rules.d/78-mm-sim7000-no-qmi.rules` still exists and look at `dmesg | tail`.
2. `stty` on the USB serial ports always exits non-zero ("unable to perform all requested operations"). That's
   harmless and must not be treated as a failure.
3. **Correction (2026-10-04):** the SIM also has to be activated/topped up in **KiwiSIM's top-up portal**. The
   2026-09-28 note below ("no web activation form") missed that. Data did work on 09-28 before the top-up,
   but data failures on 10-04 before the top-up can't be told apart from the power problem found the same day.
4. The cellular default route always has a higher metric (1000) than WiFi (600), so SSH over WiFi isn't affected
   by the cellular link. (Before 2026-10-04 only the modem's built-in data connection, `AT+CNACT`, was used.)
5. On Cat-M, the first ping or two after the link sits idle are often lost while the radio reconnects. That's normal.

Goal: `connect_minicom.sh` brings up the Waveshare SIM7000G HAT over USB, registers it
on LTE-M/NB-IoT with the KiwiSIM, tells you when to activate the SIM, and then tests data.

Target: `<user>@<pi-ip>` (key auth, `ssh -o BatchMode=yes`). Script is copied to `~/connect_minicom.sh`.

## Plan

### Modes
- `./connect_minicom.sh`: full interactive run (you run this with `ssh -t`).
- `./connect_minicom.sh --check`: preflight, port detection, and **read-only** status queries
  (`?` reads only). No prompts and no setting changes. This is the part I test over SSH.

### Steps the script takes
1. **Preflight** (each failure prints how to fix it):
   - User is in `dialout` (fix: `sudo usermod -aG dialout $USER`, then log in again).
   - A SIMCom USB device (vendor `1e0e`) is present (via `lsusb`, or `/sys` if `lsusb` is missing).
     Fix: check that the HAT's micro-USB goes to the Pi's USB *data* port.
   - `/dev/ttyUSB*` ports exist.
   - ModemManager is active: **warn** and print `sudo systemctl stop ModemManager`. The script
     never stops it. The full run asks whether to continue; `--check` only warns.
   - Another process holds a ttyUSB port (`fuser`): stop and show which PID.
2. **Detect the AT port**: for each `/dev/ttyUSB*`, set it raw at 115200 with `stty` and send `AT` in
   a subshell wrapped in `timeout 5`, so the GPS/NMEA port (which streams forever) or a dead port
   can't block. The first port that replies `OK` wins.
3. **Serial I/O**: open the port once on a file descriptor. `at_cmd` drains stale input (logging
   it as URCs), writes `CMD\r`, then reads lines with `read -t` until `OK`/`ERROR`/`+CME ERROR` or
   a per-command deadline. Values are pulled out by response prefix (`+CEREG:`, `+CSQ:` …), so
   unsolicited lines (`SMS Ready`, `Call Ready`, `+CPIN: READY`, `DST: 1`, `*PSUTTZ`, `+APP PDP`)
   and command echo are tolerated without special cases.
4. **AT sequence** (full run):
   1. `AT`, `ATI`
   2. `AT+CPIN?` → `READY` continues; `SIM PIN` → prompt with `read -s` and send `AT+CPIN=...`
      (masked in the log, never echoed); `SIM PUK` / not inserted → stop with a message.
      The script never retries a PIN automatically, so it can't lock the SIM.
   3. `AT+CSQ` (shows rssi → dBm)
   4. `AT+CBANDCFG?` → check that bands 2, 4, 12, and 13 are in both the CAT-M and NB-IOT lists.
      If any are missing, ask before `AT+CBANDCFG="CAT-M",<current+missing>` (same for NB-IOT).
   5. If already registered (CEREG 1/5), offer to skip re-attaching.
   6. For each mode in Cat-M (`CMNB=1`), NB-IoT (`CMNB=2`), and both (`CMNB=3`):
      `AT+CNMP=38`, `AT+CMNB=<mode>`, `AT+CGDCONT=1,"IP","$APN"`, `AT+CFUN=0`, `AT+CFUN=1`,
      re-check `AT+CPIN?`, then every 10 s for up to 180 s run `AT+CEREG?`, `AT+CPSI?`, `AT+CSQ`.
      - stat 1 (home) / 5 (roaming) → success
      - stat 3 (denied) → next mode right away
      - timeout → next mode
5. **Success banner**: carrier (`AT+COPS?`), RAT (from `AT+CPSI?`: CAT-M1 / NB-IOT), signal,
   IMEI (`AT+GSN`), ICCID (`AT+CCID`), and "activate the SIM now".
6. **Wait for Enter**, then test data: `AT+CNACT=1,"$APN"`, poll `AT+CNACT?` for an IP, then
   `AT+SNPING4="8.8.8.8",3,16,1000`. This does not touch the Pi's routing, PPP, or interfaces.
7. **All modes failed**: print a summary per mode (last CEREG stat, best CSQ, last CPSI) and a likely
   cause: no signal at all → antenna/coverage; denied → the SIM plan or carrier won't accept that
   RAT; searching with signal → coverage or plan.
8. **Offer minicom**: `minicom -D <port> -b 115200` (the script closes its own fd first).

### Logging
`~/cell_logs/connect_YYYYmmdd_HHMMSS.log` gets every AT command and reply. The PIN command is logged
as `AT+CPIN="****"`, and the PIN variable is unset right after use.

### Testing plan
- `shellcheck` on the script (on the Pi or locally, whichever has it).
- `bash -n` syntax check.
- Over SSH: `lsusb`, `ls /dev/ttyUSB*`, `id`, ModemManager status, and read-only AT queries.
- Run `~/connect_minicom.sh --check` on the Pi over BatchMode SSH and compare its output with the manual queries.
- Setting changes (CNMP/CMNB/CGDCONT/CFUN/CBANDCFG/CNACT) and the PIN / Enter / minicom parts are **not**
  run by me. You run them with `ssh -t <user>@<pi-ip> '~/connect_minicom.sh'`.

## Progress log
- Wrote the plan (this file).
- **Read-only checks of the Pi (2026-09-28 17:28):** `water` is in `dialout`. `fuser`, `lsusb`, `minicom`,
  `shellcheck`, and `timeout` are installed; bash is 5.2. Pi power is fine (`vcgencmd get_throttled` = 0x0).
- **Finding: the modem is in a reset loop.** dmesg showed 38 connects of `1e0e:9001` in the first 10 minutes of uptime,
  on a steady cycle: ~5.3 s on USB, then ~5.7 s gone. ModemManager (active) picks it up on every connect; its log shows
  `enabling` → `power state updated: on`, and the modem disconnects right after. This probably explains the
  earlier `NO SERVICE` result. Suspects: (a) ModemManager's radio power-on/QMI setup resets it; (b) the radio
  powering up pulls too much current from the Pi's USB (behind a hub) and the module browns out.
  Next step: stop ModemManager (needs sudo, so the user runs it) and see whether the loop stops.
- Wrote `connect_minicom.sh` following the plan. Decisions:
  - Values are pulled out by response prefix, so URCs and command echo need no special handling. `ATE0` isn't sent, so `--check` changes nothing.
  - The modem echoes commands back, so the reader masks any `AT+CPIN=` echo line before logging it (the PIN would otherwise land in the log).
  - A partial line left after a 1 s `read -t` timeout is kept and joined with the next read, so no lines are lost.
  - If the port node disappears mid-run (modem reset), the script stops with a dmesg hint instead of spinning.
  - A wrong PIN is never retried automatically, and PUK is never entered.
  - If the modem is already registered, the full run offers to skip the radio restart.
  - The failure diagnosis points out that the network may *deny* the SIM until it's activated. That clashes with
    "register first, then activate", so if every mode fails, try activating first.
- Tested: `bash -n` passes, and `shellcheck` on the Pi is clean (one intended SC2016 disabled for the probe subshell).
  `--check` on the Pi waited for USB, warned about ModemManager, and probed all 5 ports without blocking.
  None answered AT because of the reset loop, and the script stopped with the right hint (exit 1).

- User stopped ModemManager (17:37). **The reset loop stopped right away** (no USB disconnects since), which
  confirms ModemManager was the cause. It's only stopped until the next reboot unless it's also `disable`d.
- Bug found: `stty` on the option-driver ports prints "unable to perform all requested operations" and exits
  non-zero, and `probe_port` treated that as a dead port, so no port was ever probed. A raw test showed ttyUSB2 **and**
  ttyUSB3 both answer `AT` → `OK` now. Fix: `stty` failure is non-fatal in `probe_port` and `open_port`.
  Shellcheck is still clean.
- `--check` now passes end-to-end (exit 0). It picked `/dev/ttyUSB2` (the first port that answers; ttyUSB3 also works).
  All the parsing checked out:
  - SIM7000G R1529, SIM READY (no PIN), CSQ 21 (~-71 dBm)
  - **Already registered: `+CEREG: 0,5` (roaming), AT&T (310-410), LTE CAT-M1, EUTRAN-BAND12**
  - CNMP=38, CMNB=1 (Cat-M) already set; CGDCONT cid 1 has an empty APN (IPV4V6), probably left by ModemManager
  - CAT-M bands include 2/4/12/13; NB-IOT is missing band 4 (the full run offers to add it; only matters if Cat-M fails)
  - IMEI <IMEI>, ICCID <ICCID>, CNACT inactive
- Because it's already registered, the full run will offer to skip the radio restart. Answering N (the default)
  goes straight to the success banner.

### Checkpoint (later items below)
- [x] Stop ModemManager and re-check → loop gone.
- [x] `--check` against the live modem.
- (Later resolved: ModemManager disabled; the full interactive run succeeded; see below.)
- Correction: the run command must quote the tilde: `ssh -t <user>@<pi-ip> '~/connect_minicom.sh'`. Unquoted, the
  local shell expands `~` to the laptop's home directory, which doesn't exist on the Pi.
- Checked KiwiSIM's site (2026-09-28): there is **no web activation form**. Their "USA SIM Card Activation" page
  (kiwisimcard.com/pages/usa-sim-card-activation) only covers APN setup: "Turn on Roaming and set the APN to Activate
  SIM Card" (APN name kiwisim, APN linksnet, no user/pass). So activation is simply using APN `linksnet` with
  roaming allowed; the script's data test (`AT+CNACT=1,"linksnet"`) *is* the activation step. KiwiSIM also lists
  `plus` as an alternative APN in some instructions; that's a fallback if `linksnet` gets no IP.
  Open: the success banner still says "activate on the provider's website"; reword it once the data test is confirmed.
- **Full interactive run by the user succeeded (2026-09-28 17:56, log `~/cell_logs/connect_20260928_175545.log`):**
  answered N to the NB-IOT band change and N to redoing the setup. The banner showed AT&T / LTE CAT-M1 / CEREG 5 / CSQ 23.
  After Enter: `AT+CNACT=1,"linksnet"` → `+APP PDP: ACTIVE`, IP 100.x.x.x; `AT+SNPING4` got 3/3 replies (296/132/122 ms).
  **The SIM is active and modem data works.**
- Reworded the success banner and the Enter prompt (activation = using the APN, no web form). Redeployed; shellcheck clean.

### Status: done
- [x] Detection, registration, SIM activation, and data test all work end-to-end.
- [x] ModemManager is disabled (checked with `systemctl is-enabled`), so the reset loop won't return after a reboot.
- Note: the modem's own data context (CNACT) stays open until `AT+CNACT=0` or a power cycle. It doesn't affect the Pi's routing.

## Cellular-only network test: `cell_net_test.sh`

Goal: prove that internet requests work over **only** the cellular network, without touching the Pi's WiFi,
routes, or interfaces. Approach: the SIM7000G's built-in IP stack does the networking and the Pi just sends AT
commands over USB serial. The public IP returned by the HTTP test is the carrier's, not the WiFi network's,
which shows the path.

Read-only capability probe first (test commands `=?` only; 2026-09-28): `AT+SHCONF=?`, `AT+SHREQ=?` (HTTP client),
`AT+CAOPEN=?` (TCP/UDP), `AT+CDNSGIP=?`, `AT+HTTPINIT=?`, and `AT+SAPBR=?` all answer OK on R1529. `AT+CDNSCFG?` shows
0.0.0.0, but hostname lookups through the SH* client still work (DNS comes from the network).

What the script does:
1. Detects the AT port (same probe as `connect_minicom.sh`).
2. Makes sure the modem's data connection is up: `AT+CNACT?`; if inactive, `AT+CNACT=1,"linksnet"`, then polls for an IP.
3. Ping from the modem: `AT+SNPING4="8.8.8.8",3,16,1000`.
4. HTTP GET with the modem's HTTP client (default `http://api.ipify.org/` returns the cellular public IP):
   ```
   AT+SHDISC                              (clear a leftover session)
   AT+SHCONF="URL","http://api.ipify.org"
   AT+SHCONF="BODYLEN",1024
   AT+SHCONF="HEADERLEN",350
   AT+SHCONN                              (connect; up to 30 s)
   AT+SHREQ="/",1                         → OK, then later: +SHREQ: "GET",200,12
   AT+SHREAD=0,12                         → OK, then: +SHREAD: 12 / <body>
   AT+SHDISC
   ```
   The same sequence can be typed by hand in minicom. Only plain `http://` is supported (https would need
   certificate setup on the modem via `AT+CSSLCFG`/`AT+SHSSL`).

Tested on the Pi (2026-09-28): shellcheck clean, exit 0:
```
Modem AT port: /dev/ttyUSB2
[ok] Modem data connection up, cellular IP 100.x.x.x
[ok] Ping 8.8.8.8: 1/3 replies (351 ms)
[ok] HTTP GET http://api.ipify.org/ -> status 200, 12 bytes
----- response body (first 12 bytes) -----
<cellular-public-ip>
```
The 1/3 ping result was checked with a raw capture: replies arrive *before* `OK` (the script isn't missing them),
and a second run also got 1/3 (reply #3 only). This is real loss on the first packets while the Cat-M radio wakes
from idle; the earlier 3/3 run came right after the link was opened. HTTP (TCP retransmits) isn't affected.

### Possible next steps
- For a Pi program to use cellular *without* PPP, drive the modem's TCP/HTTP commands (`AT+CAOPEN`/`AT+SH*`)
  as `cell_net_test.sh` does. Full Linux networking over cellular would need PPP or QMI (`wwan0`), which changes routing.
  Only do that with a plan that keeps SSH on WiFi (e.g. no default route via the modem).
- `APN_USER`/`APN_PASS` in `connect_minicom.sh` aren't sent (not needed for KiwiSIM). If ever needed, check
  `AT+CNCFG=?` (read-only) for support.
- NB-IoT band list is missing band 4; only matters if Cat-M stops working.

## NetworkManager integration (2026-10-04)

Goal: expose the modem as an ordinary NetworkManager connection that any program can use, with **lower priority
than WiFi**, so cellular carries traffic only when WiFi is down.

**Status: working.** `ppp0` comes up automatically (cellular IP 100.x.x.x). WiFi keeps the default route.

What was found:
- Starting ModemManager brought the reset loop back right away. The kernel log showed `-71` USB protocol errors on
  **interface 05 (QMI, `cdc-wdm0`/`wwan0`)** just before each drop, beginning when ModemManager opened it (once
  during the QMI probe itself). So the QMI interface is the trigger, not ModemManager in general.
- With QMI hidden, ModemManager uses the AT ports and PPP and stays stable (0 USB resets).
- The first PPP attempt dialed on the primary AT port ttyUSB2. A cancelled activation (my manual `con up` racing
  autoconnect) left ttyUSB2 stuck in data mode, so ModemManager timed out and dropped the modem. Recovered with
  `+++` (1 s guard time) and then `ATH`. Fix: dial PPP on ttyUSB3 instead.

Changes on the Pi:
1. `/etc/udev/rules.d/78-mm-sim7000-no-qmi.rules`:
   - USB interface 05 (cdc-wdm0, wwan0) → `ID_MM_PORT_IGNORE=1`
   - USB interface 03 (ttyUSB3) → `ID_MM_PORT_TYPE_AT_PPP=1` (clears the stock `AT_SECONDARY` hint)
   - ttyUSB2 stays the primary AT (control) port; ttyUSB0 (QCDM) and ttyUSB1 (GPS) are left as they were.
2. ModemManager is **enabled and running** again.
3. NetworkManager connection `kiwisim` (type gsm): `gsm.apn linksnet`, `ipv4/ipv6.route-metric 1000` (WiFi uses
   the default 600), `ipv4/ipv6.dns-priority 200` (WiFi DNS first), `autoconnect yes`, `autoconnect-retries 0`
   (retry forever).

Result:
```
default via <gateway> dev wlan0 proto dhcp src <pi-ip> metric 600
default dev ppp0 proto static scope link metric 1000
```
- Default path public IP: `<wifi-public-ip>` (the WiFi network). `curl --interface ppp0`: `<cellular-public-ip>` (cellular).
  Ping over ppp0: 3/3 replies.
- When wlan0 disconnects, NetworkManager removes its default route and traffic falls through to ppp0. When WiFi
  comes back, traffic moves back automatically. (Not tested live: SSH arrives over WiFi from another subnet,
  so dropping WiFi would cut the session.)

Usage / notes:
- Force a program onto cellular: `curl --interface ppp0 …` or bind to `ppp0`. Everything else uses WiFi when it's present.
- Status: `nmcli device status`, `mmcli -m any`, `ip route`. Manual control: `sudo nmcli con down|up kiwisim`.
- ModemManager holds ttyUSB2 and ttyUSB3, so `connect_minicom.sh` and `cell_net_test.sh` pause it and restore it
  themselves (see "How to run the scripts" at the top).
- Undo everything: `sudo nmcli con delete kiwisim; sudo systemctl disable --now ModemManager;
  sudo rm /etc/udev/rules.d/78-mm-sim7000-no-qmi.rules`.

## Problem: cellular fallback fails under load (2026-10-04, after a reboot at ~17:33)

Report: with wlan0 disconnected, `curl http://ip.me` failed even though `nmcli device` showed `ttyUSB2` connected.
It worked again once WiFi was back.

Findings:
- Routing/DNS did switch correctly (`policy: set 'kiwisim' (ppp0) as default for IPv4 routing and DNS`).
- **The USB hub browns out whenever the modem carries real traffic.** Three resets this boot: 17:34:38 (10 s after
  WiFi was disconnected), 17:47:25 (first ping on a fresh PPP link), 17:48:20 (`cell_net_test.sh` ping). The last
  two took down the **whole hub** (`214b:7260 Huasheng USB2.0 HUB`, unpowered) including the keyboard on 1-1.3,
  with `usb1-port1: disabled by hub (EMI?)`. After the third, the hub didn't re-enumerate (`attempt power cycle`),
  and USB is dead until it's replugged or the Pi reboots.
- Between resets the link passed nothing: pppd reported `Sent 12316 bytes, received 0 bytes` over 12.6 min, and
  the modem's own stack (`cell_net_test.sh`) also got no ping replies. Likely the uplink failing on voltage sag
  without a full reset.
- The Pi itself reports no undervoltage (`throttled=0x0`); the sag is on the hub/modem side.
- Before the reboot, the same tests passed (PPP, CNACT and HTTP all worked at 17:19-17:26), though pings over CNACT
  often lost the first packets, which fits marginal power.
- Conclusion: hardware power/RF, not NetworkManager/ModemManager configuration.

To fix (hardware):
1. Use a **powered** USB hub (its own supply), or connect the modem straight to the Pi's USB data port, without the hub.
2. Keep the LTE antenna away from the hub and USB cables (the kernel's "EMI?" hint; Cat-M TX is up to 23 dBm).
3. Make sure the Pi's supply is solid (official 5 V 2.5 A, short cable). The SIM7000 needs short bursts of up to ~2 A
   at its supply during TX.
Retest: `cell_net_test.sh` and a load test over ppp0 while watching `sudo dmesg -W` for `EMI?` / `USB disconnect`.

## Retest after power-supply change + SIM top-up (2026-10-04 ~17:54-18:10)

- **Power fixed:** 0 USB resets since the reboot, including under load (about 575 KB over ppp0). Throttled 0x0.
- Now roaming on **Verizon** (was AT&T). APN linksnet, same IP 100.x.x.x / public <cellular-public-ip>.
- Over ppp0 with WiFi up: ping 4/4, DNS over cellular OK, `curl http://ip.me` 200, 284 KB down / 100 KB up.
  Slow (about 3 KB/s down, 1.4 KB/s up), which is plausible for roaming Cat-M.
- **New problem: a zombie PPP session after a network-side hangup.** At ~17:58:06 the network ended the session
  (`LCP terminated by peer`, `Modem hangup`, after 3.9 min and 449 KB received). NetworkManager re-dialed straight
  away and got an IP, so it looked "activated", but the new session passed **no traffic** (62 bytes received; ping
  and DNS failed). The WiFi failover test (`nmcli device disconnect wlan0`, then plain curl/getent/ping) ran on that
  dead session and failed, although routing and DNS had switched correctly. pppd's LCP keepalive can't detect this
  (the modem answers LCP itself).
- Recovery that worked: restarting ModemManager (via `cell_net_test.sh`'s restore) gave a working session.
  A clean `nmcli con down/up` also gives a working session in the healthy state; not tested from the dead state.
- The account is fine: the modem's own stack (CNACT/HTTP) worked, and there were no SMS from the provider.
- Proposed fix: an IP-level health check (ping over ppp0 every few minutes; on repeated failure, `nmcli con up`,
  then restart ModemManager). It costs a little roaming data per check.

## Watchdog, failover verified, reproducible setup (2026-10-04 ~18:10-18:26)

The production Pi will mostly have **no WiFi**, so cellular is the main uplink and must repair itself.
- Built `cell-watchdog` (timer every 3 min plus a NetworkManager hook; details in README.md 6.3).
- Real dead links seen and fixed by watchdog step 1 (`nmcli con up kiwisim`):
  - **Silent idle death:** a session went dead within ~10 min with no log message.
  - **Dead re-dial after a ModemManager restart** (the installer's restart, re-dialed ~7 s later). A later restart
    was fine, so it's intermittent. Same pattern as the 17:58 network hangup: an abrupt end followed by a quick
    re-dial is sometimes dead, while a clean `con up` has always worked.
  - Added a hook trigger 30 s after `kiwisim` comes up (verified: fired and checked at 18:25:56).
- **WiFi-off failover test, 18:14-18:21: 14/14 `curl http://ip.me` OK over cellular** (0.8-1.1 s each), 0 USB
  resets, and WiFi restored itself.
- Reproducible setup: `README.md` (guide), `install_cellular.sh` (installer), `udev/`, `watchdog/`. The installer ran
  cleanly twice on this Pi (idempotent); it hasn't been tried on a fresh Pi yet. Fixed during testing: `sudo -v`
  asks for a password even with NOPASSWD, so the installer uses `sudo -n true` instead.
