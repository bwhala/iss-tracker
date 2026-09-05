#!/usr/bin/env bash
# Staged network recovery for the ISS tracker appliance.
#
# Motivation: on 2026-08-05 the brcmfmac Wi-Fi driver hung mid-SDIO-transfer,
# leaving NetworkManager and wpa_supplicant in permanent uninterruptible
# D-state. No userspace restart can fix that — only a driver reload or a
# reboot. The tracker displayed stale data for 47 hours until a manual power
# cycle. This watchdog automates that recovery, least-disruptive step first.
#
# Invoked by net-watchdog.timer every 2 minutes. On connectivity failure,
# escalates by outage duration:
#   first check   restart NetworkManager
#   >= 10 min     cycle the Wi-Fi radio
#   >= 20 min     reload the brcmfmac kernel module
#   >= 45 min     forced reboot (at most one per 2 h)
#
# Every recovery action runs detached via systemd-run so a D-state hang in
# one stage can never wedge this script — the next timer tick escalates
# regardless. A hung forced reboot is covered by RebootWatchdogSec (hardware
# watchdog), see 10-hardware-watchdog.conf.
#
# If the gateway is reachable but DNS fails, the problem is upstream (ISP);
# escalation stops after the NetworkManager restart — rebooting the Pi can't
# fix an upstream outage, and a reboot loop would just wear the SD card.
set -u

STATE_DIR=/run/net-watchdog          # tmpfs: cleared on reboot
PERSIST_DIR=/var/lib/net-watchdog    # survives reboots (reboot cooldown)
FAIL_TS_FILE=$STATE_DIR/first_failure_ts
STAGE_FILE=$STATE_DIR/last_stage
REBOOT_TS_FILE=$PERSIST_DIR/last_reboot_ts

CYCLE_WIFI_AFTER=600        # 10 min
RELOAD_DRIVER_AFTER=1200    # 20 min
REBOOT_AFTER=2700           # 45 min
REBOOT_COOLDOWN=7200        # min 2 h between watchdog-initiated reboots

mkdir -p "$STATE_DIR" "$PERSIST_DIR"

log() { echo "$*"; }   # stdout lands in the journal via the service unit

check_dns() {
    timeout 10 getent hosts api.wheretheiss.at >/dev/null 2>&1 && return 0
    timeout 10 getent hosts one.one.one.one >/dev/null 2>&1 && return 0
    return 1
}

gateway_reachable() {
    local gw
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw" ] && timeout 10 ping -c 1 -W 3 "$gw" >/dev/null 2>&1
}

run_detached() {
    # Run a recovery action in its own transient unit so a D-state hang
    # cannot block this script. May fail if the unit from a previous (still
    # hung) attempt exists — that is fine, escalation continues next tick.
    local name=$1; shift
    systemd-run --unit "net-watchdog-$name" --collect "$@" >/dev/null 2>&1 || true
}

if check_dns; then
    if [ -f "$FAIL_TS_FILE" ]; then
        log "Connectivity restored after $(( $(date +%s) - $(cat "$FAIL_TS_FILE") ))s"
        rm -f "$FAIL_TS_FILE" "$STAGE_FILE"
    fi
    exit 0
fi

now=$(date +%s)
if [ ! -f "$FAIL_TS_FILE" ]; then
    echo "$now" > "$FAIL_TS_FILE"
fi
outage=$(( now - $(cat "$FAIL_TS_FILE") ))
last_stage=$(cat "$STAGE_FILE" 2>/dev/null || echo 0)

if gateway_reachable; then
    # Local network fine, DNS/upstream broken: one NetworkManager restart
    # (refreshes DHCP-provided DNS servers), then wait it out.
    if [ "$last_stage" -lt 1 ]; then
        echo 1 > "$STAGE_FILE"
        log "DNS down ${outage}s, gateway reachable -> restarting NetworkManager (upstream outage suspected; no reboot escalation)"
        run_detached nm-restart systemctl restart NetworkManager
    else
        log "DNS down ${outage}s, gateway reachable -> waiting for upstream to recover"
    fi
    exit 0
fi

log "Network down for ${outage}s (gateway unreachable, stage $last_stage)"

if [ "$outage" -ge "$REBOOT_AFTER" ] && [ "$last_stage" -lt 4 ]; then
    last_reboot=$(cat "$REBOOT_TS_FILE" 2>/dev/null || echo 0)
    if [ $(( now - last_reboot )) -lt "$REBOOT_COOLDOWN" ]; then
        log "Reboot warranted but last watchdog reboot was $(( now - last_reboot ))s ago (cooldown ${REBOOT_COOLDOWN}s); waiting"
        exit 0
    fi
    echo 4 > "$STAGE_FILE"
    echo "$now" > "$REBOOT_TS_FILE"
    sync
    log "Escalation: forced reboot after ${outage}s without network"
    # -f skips the (potentially hung) stop jobs; filesystems are still synced.
    run_detached reboot systemctl reboot -f
elif [ "$outage" -ge "$RELOAD_DRIVER_AFTER" ] && [ "$last_stage" -lt 3 ]; then
    echo 3 > "$STAGE_FILE"
    log "Escalation: reloading brcmfmac Wi-Fi driver"
    run_detached driver-reload /bin/sh -c 'modprobe -r brcmfmac_wcc brcmfmac; sleep 2; modprobe brcmfmac'
elif [ "$outage" -ge "$CYCLE_WIFI_AFTER" ] && [ "$last_stage" -lt 2 ]; then
    echo 2 > "$STAGE_FILE"
    log "Escalation: cycling Wi-Fi radio"
    run_detached wifi-cycle /bin/sh -c 'nmcli radio wifi off; sleep 5; nmcli radio wifi on'
elif [ "$last_stage" -lt 1 ]; then
    echo 1 > "$STAGE_FILE"
    log "Escalation: restarting NetworkManager"
    run_detached nm-restart systemctl restart NetworkManager
fi
exit 0
