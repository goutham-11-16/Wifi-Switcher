#!/bin/bash
# ==============================================================================
# KLU Standalone Hotspot Router
# Integrated High-Speed Hotspot Engine for KLU Switch
# Directory: /home/goutham/Personal Files/WIfi test/KLU WIFI SWIFT
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/klu_hotspot.conf"

# Default configuration values
SSID="Ubuntu x Dell"
PASSWORD="Goutham11"
SECURITY_MODE="wpa2"
BAND="auto"
INTERFACE="wlp0s20f3"
AP_INTERFACE="ap0"
ISOLATE_CLIENTS="false"
DNS_SERVERS="1.1.1.1,8.8.8.8"
MAX_CLIENTS="15"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

PID_FILE="/tmp/klu_hotspot.pid"
STATE_FILE="/tmp/klu_hotspot.state"
LOG_FILE="/tmp/klu_hotspot.log"

# Notification helper
send_notify() {
    local urgency="${1:-normal}"
    local title="$2"
    local body="$3"
    local target_user="${SUDO_USER:-$USER}"
    if [ "$target_user" = "root" ]; then
        target_user="goutham"
    fi
    local uid
    uid=$(id -u "$target_user" 2>/dev/null || echo "1000")
    sudo -u "$target_user" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        notify-send -u "$urgency" -i network-wireless-hotspot-symbolic "$title" "$body" 2>/dev/null || true
}

# Read-only status command (does NOT require root)
cmd_status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && ip link show "$AP_INTERFACE" >/dev/null 2>&1; then
        local ch
        ch=$(iw dev "$AP_INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
        local band="2.4GHz"
        [ -n "$ch" ] && [ "$ch" -gt 14 ] && band="5GHz"
        local clients=0
        if command -v iw >/dev/null 2>&1; then
            clients=$(iw dev "$AP_INTERFACE" station dump 2>/dev/null | grep -c "Station" || echo "0")
        fi
        echo "ACTIVE|${ch:-?}|${band}|${clients}"
        exit 0
    elif ip link show "$AP_INTERFACE" >/dev/null 2>&1; then
        local ch
        ch=$(iw dev "$AP_INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
        local band="2.4GHz"
        [ -n "$ch" ] && [ "$ch" -gt 14 ] && band="5GHz"
        echo "ACTIVE|${ch:-?}|${band}|0"
        exit 0
    else
        echo "INACTIVE|N/A|N/A|0"
        exit 0
    fi
}

cmd_clients() {
    if ! ip link show "$AP_INTERFACE" >/dev/null 2>&1; then
        echo "[]"
        exit 0
    fi
    local leases_file
    leases_file=$(ls /tmp/create_ap.*/dnsmasq.leases 2>/dev/null | head -1)
    local stations
    stations=$(iw dev "$AP_INTERFACE" station dump 2>/dev/null | awk '/Station/{print $2}')
    for m in $stations; do
        local ip="Unknown"
        local name="Unknown"
        if [ -n "$leases_file" ] && [ -f "$leases_file" ]; then
            local line
            line=$(grep -i "$m" "$leases_file" 2>/dev/null | head -1)
            [ -n "$line" ] && ip=$(echo "$line" | awk '{print $3}')
            [ -n "$line" ] && name=$(echo "$line" | awk '{print $4}')
        fi
        echo "${m}|${ip}|${name}"
    done
    exit 0
}

# Handle read-only commands without privilege elevation
case "$1" in
    --status|-s|status)
        cmd_status
        ;;
    --clients|-c|clients)
        cmd_clients
        ;;
esac

# Privilege check for start/stop
if [ "$(id -u)" -ne 0 ]; then
    if [ -t 0 ]; then
        exec sudo "$0" "$@"
    else
        exec pkexec "$0" "$@"
    fi
fi

# Stop Hotspot
cmd_stop() {
    echo "[*] Stopping KLU Hotspot..."
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE" "$STATE_FILE"
    fi

    # Only terminate standalone processes if not owned by main systemd service
    if ! systemctl is-active --quiet wifi-hotspot@*.service 2>/dev/null && ! pgrep -f "start_hotspot" >/dev/null; then
        pkill -9 -f "create_ap.*${AP_INTERFACE}" 2>/dev/null || true
        pkill -9 -f "hostapd.*${AP_INTERFACE}" 2>/dev/null || true
        iw dev "$AP_INTERFACE" del 2>/dev/null || true
        ip link delete "$AP_INTERFACE" 2>/dev/null || true
    fi

    rm -f /tmp/create_ap.*.lock /tmp/create_ap.${INTERFACE}.lock "$PID_FILE" "$STATE_FILE"

    echo "[+] KLU Hotspot stopped cleanly."
    send_notify "normal" "Hotspot Disabled" "KLU Hotspot has been stopped."
}

# Start Hotspot
cmd_start() {
    echo "[*] Starting KLU Standalone Hotspot..."

    if systemctl is-active --quiet wifi-hotspot@*.service 2>/dev/null || pgrep -f "start_hotspot" >/dev/null; then
        echo "[!] Primary wifi-hotspot service is already active or starting on the system."
        send_notify "normal" "Hotspot Already Active" "Main Wi-Fi Hotspot is currently active."
        exit 0
    fi

    # Single-instance: Terminate any previous standalone hotspot cleanly
    cmd_stop >/dev/null 2>&1
    sleep 0.5

    # Detect active Wi-Fi channel on managed interface
    local cur_ch
    cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
    if [ -z "$cur_ch" ]; then
        echo "[-] Error: Wi-Fi interface $INTERFACE is not connected to any network."
        send_notify "critical" "Hotspot Error" "Wi-Fi is not connected. Connect to Wi-Fi first."
        exit 1
    fi

    # DFS Detection & Auto-Roam
    # DFS channels (52-64, 100-144) cannot operate in AP mode on station cards without Radar Detection.
    if ([ "$cur_ch" -ge 52 ] && [ "$cur_ch" -le 64 ]) || ([ "$cur_ch" -ge 100 ] && [ "$cur_ch" -le 144 ]); then
        echo "[!] Current Wi-Fi is on DFS Channel $cur_ch (AP mode prohibited)."
        echo "[*] Proactively roaming Wi-Fi to best non-DFS AP for uninterrupted hotspot..."
        local target_bssid
        target_bssid=$(nmcli -t -f BSSID,CHAN,SIGNAL,SSID dev wifi list ifname "$INTERFACE" 2>/dev/null | sed 's/\\//g' | awk -F: '
            $10 == "KLU_WIFI" || $0 ~ /KLU_WIFI/ {
                b=$1":"$2":"$3":"$4":"$5":"$6; c=$8; s=$9;
                if ((c >= 52 && c <= 64) || (c >= 100 && c <= 144)) next;
                score = s;
                if (c >= 36) score += 15;
                if (score > max) { max = score; best = b; }
            } END { print best }
        ')
        if [ -n "$target_bssid" ]; then
            local con
            con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="$INTERFACE" '$2==dev{print $1; exit}')
            [ -z "$con" ] && con="KLU_WIFI"
            nmcli connection modify "$con" 802-11-wireless.bssid "$target_bssid" 2>/dev/null || true
            nmcli -w 4 connection up "$con" 2>/dev/null || true
            sleep 1.5
            cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
        fi
    fi

    # Build create_ap argument list
    local ARGS=()
    local band_tag="2.4GHz"

    if [ "$cur_ch" -ge 36 ] 2>/dev/null; then
        band_tag="5GHz"
        ARGS+=(
            --ieee80211ac
            -c "$cur_ch"
            --freq-band 5
            --ht_capab '[HT40+][SHORT-GI-20][SHORT-GI-40][RX-STBC1][LDPC]'
            --vht_capab '[SHORT-GI-80][MAX-A-MPDU-LEN-EXP7][RXLDPC][RX-STBC-1][TX-STBC-2BY1]'
            --vht-chwidth 80
        )
    else
        band_tag="2.4GHz"
        ARGS+=(
            --ieee80211n
            -c "$cur_ch"
            --freq-band 2.4
            --ht_capab '[SHORT-GI-20][RX-STBC1][LDPC]'
        )
    fi

    # Add common options
    [ -n "$DNS_SERVERS" ] && ARGS+=(--dhcp-dns "$DNS_SERVERS")
    [ "$ISOLATE_CLIENTS" = "true" ] && ARGS+=(--isolate-clients)
    ARGS+=(-w 2)

    # Wi-Fi uplink, internet interface, SSID, Password
    ARGS+=("$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD")

    echo "[*] Launching: create_ap ${ARGS[*]}"
    rm -f /tmp/create_ap.*.lock "$LOG_FILE"

    /usr/bin/create_ap "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
    local cpid=$!
    echo "$cpid" > "$PID_FILE"

    # Wait and verify AP is ready
    local ready=0
    for i in $(seq 1 12); do
        sleep 0.5
        if ip link show "$AP_INTERFACE" >/dev/null 2>&1 && (pgrep -f "hostapd.*${AP_INTERFACE}" >/dev/null 2>&1 || grep -q "AP-ENABLED" "$LOG_FILE" 2>/dev/null); then
            ready=1
            break
        fi
        if ! kill -0 "$cpid" 2>/dev/null; then
            break
        fi
    done

    if [ "$ready" -eq 1 ]; then
        ip link set dev "$AP_INTERFACE" txqueuelen 5000 2>/dev/null || true
        echo "ACTIVE|${cur_ch}|${band_tag}|0" > "$STATE_FILE"
        echo "[+] KLU Hotspot is ACTIVE on Channel $cur_ch ($band_tag) with SSID '$SSID'."
        send_notify "normal" "Hotspot Active" "KLU Hotspot is live on Ch $cur_ch ($band_tag)!"
        exit 0
    else
        echo "[-] Error: Failed to start KLU Hotspot. Check $LOG_FILE"
        cat "$LOG_FILE" 2>/dev/null | tail -n 10
        cmd_stop >/dev/null 2>&1
        send_notify "critical" "Hotspot Failed" "Hotspot failed to start. View /tmp/klu_hotspot.log for details."
        exit 1
    fi
}

case "$1" in
    --start|-u|start)
        cmd_start
        ;;
    --stop|-d|stop)
        cmd_stop
        ;;
    --restart|restart)
        cmd_stop
        sleep 1
        cmd_start
        ;;
    *)
        echo "Usage: $0 {--start|--stop|--restart|--status|--clients}"
        exit 1
        ;;
esac
