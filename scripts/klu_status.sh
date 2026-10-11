#!/usr/bin/env bash
set -u

wd_active=0
if systemctl --user is-active --quiet klu-watchdog.service 2>/dev/null; then
    wd_active=1
elif [ -f "/tmp/klu_watchdog.pid" ]; then
    pid=$(cat "/tmp/klu_watchdog.pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        if echo "$cmd" | grep -q "klu_wifi_watchdog.sh"; then
            wd_active=1
        fi
    fi
fi

hs_active=0
if [ -f "/tmp/klu_hotspot.state" ] && [ -f "/tmp/klu_hotspot.pid" ]; then
    hpid=$(cat "/tmp/klu_hotspot.pid" 2>/dev/null || echo "")
    if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
        hs_active=1
    fi
fi

link=$(iw dev wlp0s20f3 link 2>/dev/null || true)
bssid=$(echo "$link" | awk '/Connected to/{print $3}')
sig=$(echo "$link" | awk '/signal:/{print $2}')
ch=$(iw dev wlp0s20f3 info 2>/dev/null | awk '/channel/{print $2}')
band="2.4GHz"
if [ -n "$ch" ] && [ "$ch" -gt 14 ] 2>/dev/null; then
    band="5GHz"
fi

hs_ch=$(iw dev ap0 info 2>/dev/null | awk '/channel/{print $2}')
hs_clients=$(iw dev ap0 station dump 2>/dev/null | awk '/Station/{c++} END{print c+0}')

speed=$(tail -n 1 "/home/goutham/Personal Files/WIfi test/KLU WIFI SWIFT/klu_wifi_speeds.log" 2>/dev/null | grep -o 'Speed: [^ ]* Mbps' || echo "")
gw=$(ip route show dev wlp0s20f3 2>/dev/null | awk '/default/{print $3}' | head -n 1)

echo "$wd_active|$hs_active|${bssid:-Disconnected}|${sig:-N/A}|${ch:-?}|$band|${hs_ch:-}|${hs_clients:-0}|$speed|${gw:-N/A}"
