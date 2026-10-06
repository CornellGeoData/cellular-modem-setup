#!/usr/bin/env bash
# install_cellular.sh - set up a Raspberry Pi (Raspberry Pi OS / Debian 13 "trixie", NetworkManager) so the
# Waveshare SIM7000G HAT is a NetworkManager cellular connection, with a health-check watchdog.
# Safe to re-run: every step checks or overwrites its own files.
#
# Usage (on the Pi, as the normal user, from this folder):   ./install_cellular.sh
# Settings can be overridden: APN=plus ./install_cellular.sh
# Full guide: README.md

set -euo pipefail

APN="${APN:-linksnet}"            # KiwiSIM APN (fallback: plus)
CON="${CON:-kiwisim}"             # NetworkManager connection name (the scripts and watchdog expect kiwisim)
ROUTE_METRIC="${ROUTE_METRIC:-1000}"   # WiFi's default is 600, so WiFi wins whenever it's connected
HERE=$(cd "$(dirname "$0")" && pwd)

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as the normal user (it uses sudo itself), not as root."
sudo -n true 2>/dev/null || sudo true || die "This needs sudo."   # (sudo -v asks for a password even with NOPASSWD)
for f in udev/78-mm-sim7000-no-qmi.rules watchdog/cell-watchdog watchdog/cell-watchdog.service \
         watchdog/cell-watchdog.timer watchdog/90-cell-watchdog connect_minicom.sh cell_net_test.sh; do
    [[ -f $HERE/$f ]] || die "Missing $f next to this script. Copy the whole cellular_setup folder to the Pi."
done
systemctl is-active --quiet NetworkManager || die "NetworkManager isn't running. This setup needs NetworkManager
  (the default on Raspberry Pi OS Bookworm and later)."

step "Installing packages"
sudo apt-get update -qq
sudo apt-get install -y modemmanager ppp minicom usbutils psmisc curl

step "Adding $USER to the dialout group (serial port access for the scripts)"
if [[ " $(id -nG "$USER") " == *" dialout "* ]]; then
    echo "already a member"
else
    sudo usermod -aG dialout "$USER"
    echo "added; log out and back in (or reboot) before running the scripts"
fi

step "Installing the udev rule (hide QMI from ModemManager, PPP on ttyUSB3)"
sudo install -m 644 -o root -g root "$HERE/udev/78-mm-sim7000-no-qmi.rules" /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=usbmisc --subsystem-match=net --subsystem-match=tty
sudo udevadm settle

step "Enabling ModemManager"
sudo systemctl unmask ModemManager 2>/dev/null || true
sudo systemctl enable ModemManager
sudo systemctl restart ModemManager   # restart so it re-reads the udev properties

step "Creating/updating the NetworkManager connection '$CON' (APN $APN, route metric $ROUTE_METRIC)"
settings=(gsm.apn "$APN" connection.autoconnect yes connection.autoconnect-retries 0
          ipv4.route-metric "$ROUTE_METRIC" ipv6.route-metric "$ROUTE_METRIC"
          ipv4.dns-priority 200 ipv6.dns-priority 200)
if nmcli -g connection.id con show "$CON" >/dev/null 2>&1; then
    sudo nmcli con mod "$CON" "${settings[@]}"
else
    sudo nmcli con add type gsm ifname '*' con-name "$CON" "${settings[@]}"
fi

step "Installing the cell-watchdog (health check + NetworkManager WiFi-down hook)"
sudo install -m 755 -o root -g root "$HERE/watchdog/cell-watchdog" /usr/local/sbin/cell-watchdog
sudo install -m 644 -o root -g root "$HERE/watchdog/cell-watchdog.service" "$HERE/watchdog/cell-watchdog.timer" \
    /etc/systemd/system/
sudo install -m 755 -o root -g root "$HERE/watchdog/90-cell-watchdog" /etc/NetworkManager/dispatcher.d/
sudo systemctl daemon-reload
sudo systemctl enable --now cell-watchdog.timer
sudo systemctl enable NetworkManager-dispatcher.service 2>/dev/null || true

step "Copying the helper scripts to $HOME"
install -m 755 "$HERE/connect_minicom.sh" "$HERE/cell_net_test.sh" "$HOME/"

step "Status"
echo "ModemManager: $(systemctl is-active ModemManager)/$(systemctl is-enabled ModemManager)"
echo "Watchdog timer: $(systemctl is-active cell-watchdog.timer)"
if lsusb | grep -q 'ID 1e0e:'; then
    echo "Modem on USB: yes"
else
    echo "Modem on USB: NO (check the HAT's USB cable and power; see README.md)"
fi
mmcli -L 2>/dev/null | sed 's/^/  /' || true
nmcli device status | sed 's/^/  /'
cat <<EOF

Done. Next steps (README.md has the details):
  - New modem or SIM: run  ~/connect_minicom.sh  once (sets LTE-M mode / bands, registers, activates the SIM).
  - Check:  nmcli device status;  curl --interface ppp0 http://ip.me;  journalctl -u cell-watchdog
EOF
