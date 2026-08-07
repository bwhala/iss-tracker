#!/usr/bin/env bash
# Install the system-level resilience pieces. Run with sudo from deploy/:
#   sudo ./install-system.sh
#
# Installs:
#   - net-watchdog: staged network recovery (timer + script)
#   - hardware watchdog: reboot on full kernel hang, backstop hung reboots
#   - Wi-Fi power save off: reduces brcmfmac SDIO hang likelihood
#
# Re-run after editing any of these files; the net-watchdog script is copied
# (not symlinked) so root never executes a user-writable file.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

install -m 755 net-watchdog.sh /usr/local/sbin/net-watchdog.sh
install -m 644 net-watchdog.service net-watchdog.timer /etc/systemd/system/
install -d /etc/systemd/system.conf.d
install -m 644 10-hardware-watchdog.conf /etc/systemd/system.conf.d/
install -d /etc/NetworkManager/conf.d
install -m 644 wifi-powersave-off.conf /etc/NetworkManager/conf.d/

systemctl daemon-reload
systemctl enable --now net-watchdog.timer

# Apply Wi-Fi power save off immediately without bouncing the connection;
# the NetworkManager drop-in covers future connects and boots.
iw dev wlan0 set power_save off 2>/dev/null || true

# PID 1 only reads RuntimeWatchdogSec on (re-)execution
systemctl daemon-reexec

echo
echo "Installed. Verify with:"
echo "  systemctl show --property RuntimeWatchdogUSec"
echo "  systemctl list-timers net-watchdog.timer"
echo "  iw dev wlan0 get power_save"
