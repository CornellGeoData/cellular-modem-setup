# SIM7000G cellular on a Raspberry Pi: setup from scratch

This guide sets up a fresh Pi so that its Waveshare SIM7000G HAT is an ordinary **NetworkManager cellular
connection** that every program can use, with a watchdog that keeps it working. On the reference Pi, cellular is
the main uplink and WiFi is only used during development; when WiFi is present it takes priority.

Reference system (2026-10-04): Raspberry Pi Zero 2 WH, Raspberry Pi OS / Debian 13 "trixie" (arm64),
NetworkManager 1.52, ModemManager 1.24, pppd 2.5.2, modem `SIM7000G R1529` (USB `1e0e:9001`), KiwiSIM (APN `linksnet`),
roaming on AT&T / Verizon LTE Cat-M1.

The full debugging history behind these choices is in `cell_network_session.md`.

---

## 1. Hardware

1. **SIM**: insert the KiwiSIM in the HAT (contacts down, notch as marked on the board). No PIN.
2. **Antenna**: screw the LTE antenna onto the HAT's **main/LTE** connector (not GNSS). Keep it away from the
   USB hub and cables (see the power note below).
3. **USB**: connect the HAT's micro-USB to the Pi's USB **data** port. On a Pi Zero that means the inner micro-USB
   port, usually through an OTG adapter or hub.
4. **Power: this matters.** The modem draws short current bursts of up to ~2 A while it transmits. On a
   weak supply, or behind an **unpowered** USB hub, the hub browns out whenever real traffic flows. The kernel
   then logs `usb … disabled by hub (EMI?)` and `USB disconnect`, takes the modem (and anything else on the hub)
   off USB, and the hub may not come back until the Pi reboots. Use a solid supply (official 5 V / 2.5 A or
   better, short cable). Use a **powered** hub if you need a hub at all.
   Check after setup with `sudo dmesg | grep -E "EMI|USB disconnect"`: it should print nothing.

## 2. Base OS

- Raspberry Pi OS Bookworm or later (uses NetworkManager by default). Check: `systemctl is-active NetworkManager`
  prints `active`.
- A normal user with sudo (the default first user has passwordless sudo, which the scripts and watchdog use).
- SSH access, and (for development) WiFi configured in NetworkManager.

## 3. Install

From the laptop, inside this folder, copy it to the Pi and run the installer (replace `<user>` and `<pi-ip>`):

```bash
rsync -a --exclude old --exclude .git ./ <user>@<pi-ip>:~/cellular_setup/
ssh -t <user>@<pi-ip> '~/cellular_setup/install_cellular.sh'
```

`install_cellular.sh` is safe to re-run. It has been run (twice, exit 0) on the already-configured reference Pi,
but not yet on a truly fresh Pi. It:

| Step | What | Why |
|---|---|---|
| packages | `modemmanager ppp minicom usbutils psmisc curl` | ModemManager drives the modem; pppd carries the data; the rest are used by the scripts |
| group | adds the user to `dialout` | the helper scripts open `/dev/ttyUSB*` |
| udev rule | `/etc/udev/rules.d/78-mm-sim7000-no-qmi.rules` | see 6.1; without it the modem resets every 5-11 s |
| ModemManager | `systemctl enable` + restart | NetworkManager manages cellular modems only through ModemManager |
| NM connection | `kiwisim`: type gsm, APN `linksnet`, autoconnect, retries forever, route metric 1000, DNS priority 200 | lower priority than WiFi (metric 600); with no WiFi it's the only route |
| watchdog | `/usr/local/sbin/cell-watchdog`, `cell-watchdog.service` + `.timer`, NM hook `/etc/NetworkManager/dispatcher.d/90-cell-watchdog` | see 6.3; repairs a connection that says "activated" but passes no traffic |
| scripts | copies `connect_minicom.sh`, `cell_net_test.sh` to `~` | bring-up and testing |

Override settings with environment variables, e.g. `APN=plus ~/cellular_setup/install_cellular.sh`.
If the user was just added to `dialout`, log out and back in (or reboot) before running the scripts.

## 4. First-time modem and SIM bring-up

Only needed for a new modem or a new SIM (the modem keeps these settings across power cycles):

```bash
ssh -t <user>@<pi-ip> '~/connect_minicom.sh'
```

It checks the SIM and signal and makes sure the US LTE-M bands (2, 4, 12, 13) are enabled. It sets LTE-only and
Cat-M (`AT+CNMP=38`, `AT+CMNB=1`; it falls back to NB-IoT if Cat-M doesn't register), waits for registration and
tests data with the modem's own stack. It pauses ModemManager during the run and restores it afterwards.

**SIM activation / top-up:** activate and top up the KiwiSIM in KiwiSIM's top-up portal. An inactive or empty
SIM can still register and even get an IP address while passing no traffic: pings get no replies, and pppd
reports `received 0 bytes`. Roaming must be allowed (the NM connection allows it by default).

## 5. Verify

```bash
ssh <user>@<pi-ip>
nmcli device status                 # ttyUSB2  gsm  connected  kiwisim
mmcli -m any | grep -E "state|registration|operator name"     # connected / roaming / AT&T or Verizon
ip route | grep default             # "default dev ppp0 ... metric 1000" (plus wlan0 metric 600 if WiFi is up)
curl -s --interface ppp0 http://ip.me      # prints the cellular public IP
ping -c 4 -I ppp0 8.8.8.8           # first reply may be lost while the Cat-M radio wakes up; that's normal
systemctl list-timers cell-watchdog.timer
journalctl -u cell-watchdog         # empty while healthy; recovery actions are logged here
sudo dmesg | grep -E "EMI|USB disconnect"  # should print nothing (see the power note)
```

**WiFi-off failover test** (development only). Disconnecting WiFi drops an SSH session that came in over WiFi,
so run the test as a job on the Pi that restores WiFi by itself:

```bash
cat > /tmp/failover.sh <<'EOF'
#!/bin/bash
exec > /tmp/failover.log 2>&1
trap 'nmcli device connect wlan0 || { sleep 10; nmcli device connect wlan0; }' EXIT
nmcli device disconnect wlan0; sleep 5
ip route | grep default
for i in $(seq 1 10); do echo "$(date +%T) $(curl -s -m 30 -w ' http=%{http_code}' http://ip.me)"; sleep 30; done
EOF
chmod +x /tmp/failover.sh && sudo systemd-run --unit=failover --collect /tmp/failover.sh
# reconnect after ~6 min and read /tmp/failover.log
```

## 6. How it works (and why)

### 6.1 ModemManager must not touch the QMI interface (udev rule)

The SIM7000G exposes ttyUSB0 (QCDM/diag), ttyUSB1 (GPS NMEA), ttyUSB2 (AT), ttyUSB3 (AT), ttyUSB4 (audio) and a
QMI interface (`cdc-wdm0` / `wwan0`, USB interface 05). **As soon as ModemManager opens the QMI interface, the
modem drops off USB.** The kernel logs `qmi_wwan … nonzero urb status received: -71`, then `USB disconnect`,
and this repeats every 5-11 s for as long as ModemManager runs. The udev rule:

- sets `ID_MM_PORT_IGNORE=1` on interface 05, so ModemManager drives the modem over AT and uses **PPP** for data;
- sets `ID_MM_PORT_TYPE_AT_PPP=1` on interface 03 (ttyUSB3), so PPP is dialed there and ttyUSB2 stays a pure control
  port. When PPP was dialed on ttyUSB2, an interrupted dial left that port stuck in data mode; ModemManager then
  timed out and dropped the modem. To recover by hand: send `+++` with 1 s of silence either side, then `ATH`.

Check that it took effect: `mmcli -m any` lists `cdc-wdm0 (ignored)`, `wwan0 (ignored)`, `ttyUSB2 (at)`, `ttyUSB3 (at)`.

### 6.2 NetworkManager connection `kiwisim`

- `gsm.apn linksnet`; no username or password.
- `ipv4.route-metric 1000`: WiFi's default route is 600, so WiFi wins whenever it's connected. With no WiFi,
  `ppp0` is the only default route. DNS priority 200 keeps WiFi's DNS servers first; over cellular, pppd
  supplies 8.8.8.8 / 8.8.4.4.
- `autoconnect yes`, `autoconnect-retries 0` (forever).
- IPv6 isn't offered over PPP here (`IPV6CP: timeout` in the log); that's harmless.

### 6.3 cell-watchdog

There's a failure that NetworkManager can't see: **the connection shows `activated`, but no traffic flows.**
Seen on the reference Pi:

1. The network hung up the PPP session (`LCP terminated by peer`). NetworkManager re-dialed within seconds and
   got an IP, but the new session passed nothing.
2. An idle session went dead silently within ~10 minutes, with no message at all.
3. After a ModemManager restart, the session re-dialed ~7 s later was dead. A later ModemManager restart gave a
   working session, so it's intermittent.

The pattern: sessions re-dialed seconds after the previous one ended **abruptly** are sometimes dead. A clean
`nmcli con up kiwisim` (which properly tears down the old session first) has fixed every case so far.

pppd's LCP keepalive can't detect this, because the modem answers LCP itself. The watchdog
(`/usr/local/sbin/cell-watchdog`) runs every 3 min (`cell-watchdog.timer`, counted from the end of the previous
run, so runs never overlap):

- If `ppp0` has received ≥2000 bytes since the last run, the link is working and nothing is sent.
- Otherwise it sends up to 4 single pings over `ppp0` (8.8.8.8 / 1.1.1.1), stopping at the first reply.
- If the link is dead, it escalates:
  1. `nmcli con up kiwisim` (re-dial)
  2. restart ModemManager
  3. `mmcli -m any --reset` (modem reboot)

  Steps 2 and 3 run at most once every 30 min, so a coverage gap doesn't cause endless modem resets.
- It does nothing while ModemManager is stopped, so it never fights the helper scripts.
- The NM hook `90-cell-watchdog` also triggers a check:
  - **30 s after `kiwisim` comes up**, so a dead re-dial (case 3) is fixed within about a minute instead of
    waiting for the next timer run. Re-activations by the watchdog itself are skipped (marker file
    `/run/cell-watchdog/recovering`), so it can't loop.
  - right away when wlan0 goes down.
- Data cost on an idle link: about one ping (~170 bytes with replies) per run, roughly 2-3 MB a month.
- Logs: `journalctl -u cell-watchdog`.
- Turn it off: `sudo systemctl disable --now cell-watchdog.timer`.

Tested 2026-10-04 on the reference Pi:
- It detected real dead links twice (case 2 and case 3) and recovered both with step 1 (about 35 s each).
- The up-hook fired 30 s after a re-dial; that session was healthy, so it left it alone.
- In a 7-minute WiFi-off test (default routing only), 14 of 14 `curl http://ip.me` requests succeeded over
  cellular, with 0 USB resets.
- Steps 2/3 and the 30-min backoff haven't been exercised: so far step 1 has always worked.

### 6.4 Helper scripts and ModemManager

ModemManager holds ttyUSB2/ttyUSB3, so `connect_minicom.sh` and `cell_net_test.sh` **pause ModemManager**
(`sudo -n systemctl stop`) and restore it from an exit trap. The trap runs on normal exit, errors, Ctrl-C and
SSH hangups. On restore they close the modem's internal data context (`AT+CNACT=0`), start ModemManager and wait
for `kiwisim` to reconnect. Cellular is down for the run plus about 10-15 s. Only `kill -9` or a power cut skips
the restore; if that happens, run `sudo systemctl start ModemManager` or reboot.

```bash
~/connect_minicom.sh --check     # read-only modem status
~/connect_minicom.sh --minicom   # manual AT commands (quit: Ctrl-A, then X); never run bare minicom on ttyUSB2
~/connect_minicom.sh             # full bring-up (section 4)
~/cell_net_test.sh [http://url]  # test data using the modem's own IP stack (independent of PPP)
```

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Modem appears and vanishes every 5-11 s; `-71` errors on `qmi_wwan` | The udev rule is missing or not applied. Check `mmcli -m any` shows `cdc-wdm0 (ignored)`; re-run the installer |
| `disabled by hub (EMI?)` / `USB disconnect` when traffic starts; hub missing from `lsusb` | Power / RF, see section 1 step 4. Reboot to recover the hub |
| `kiwisim` activated, IP assigned, but no traffic; pppd `received 0 bytes` | Usually the dead-session case: the watchdog fixes it within ~1-3 min (`journalctl -u cell-watchdog`), or fix it by hand with `sudo nmcli con up kiwisim`. If it never recovers: SIM not activated / topped up (section 4) |
| Watchdog log keeps showing "step 1" every few minutes | Link dies right after each re-dial: check the SIM balance / plan, coverage (`mmcli -m any`), and `~/cell_net_test.sh` |
| `nmcli device status` has no `gsm` device | `systemctl status ModemManager`; `mmcli -L`; `lsusb \| grep 1e0e` |
| Script says "ModemManager is running … pausing it needs sudo" | The user lacks passwordless sudo; stop ModemManager manually around the script |
| No registration | Run `~/connect_minicom.sh --check`: CSQ 99 → antenna/coverage; CEREG 3 (denied) → SIM/plan |
| Slow transfers (a few KB/s) | Normal-ish for roaming Cat-M |

## 8. Uninstall

```bash
sudo systemctl disable --now cell-watchdog.timer
sudo rm /usr/local/sbin/cell-watchdog /etc/systemd/system/cell-watchdog.{service,timer} \
        /etc/NetworkManager/dispatcher.d/90-cell-watchdog
sudo nmcli con delete kiwisim
sudo systemctl disable --now ModemManager
sudo rm /etc/udev/rules.d/78-mm-sim7000-no-qmi.rules && sudo udevadm control --reload
sudo systemctl daemon-reload
```

## 9. Files in this folder

| File | Purpose |
|---|---|
| `README.md` | this guide |
| `install_cellular.sh` | installer (section 3) |
| `udev/78-mm-sim7000-no-qmi.rules` | ModemManager port rules (6.1) |
| `watchdog/cell-watchdog` | health check script → `/usr/local/sbin/` |
| `watchdog/cell-watchdog.service`, `.timer` | systemd units → `/etc/systemd/system/` |
| `watchdog/90-cell-watchdog` | NetworkManager WiFi-down hook → `/etc/NetworkManager/dispatcher.d/` |
| `connect_minicom.sh` | modem bring-up / status / minicom (6.4) |
| `cell_net_test.sh` | modem-stack data test (6.4) |
| `cell_network_session.md` | full debugging log and evidence |
| `LICENSE` | MIT license |
