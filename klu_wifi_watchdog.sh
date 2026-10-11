#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
INTERFACE="wlp0s20f3"
CONNECTION="KLU_WIFI"
TARGET_SSID="KLU_WIFI"
TEST_IP="1.1.1.1"
TEST_IP_BACKUP="8.8.8.8"
PORTAL_URL="http://172.16.103.254:8090/httpclient.html"
PORTAL_IP="172.16.103.254"

CHECK_INTERVAL=1
FAIL_LIMIT=1
MIN_SIGNAL=45
LOGIN_WAIT=2

# Speed-Aware Roaming Thresholds (Priority 1: Stability, Priority 2: Speed)
ENABLE_SPEED_ROAM=0         # 0 = Stability-First (Leave stable connection alone; no dancing). 1 = Auto-roam for speed
ENABLE_LOW_SPEED_ROAM=1     # 1 = Automatically roam to another network if speed drops below 5 Mbps
SPEED_TEST_INTERVAL=30      # Periodically re-test current AP speed every 30s
MIN_ACCEPTABLE_SPEED=5.0    # Switch to another network if throughput is < 5.0 Mbps
HIGH_SPEED_TARGET=50        # Target fast Tier-1 APs (>= 50 Mbps)
SPEED_ROAM_COOLDOWN=60      # Minimum cooldown between speed-upgrade evaluations

# Upgrade A & C: First-to-Connect Top-Tier Reclaim Configuration
ENABLE_TOP_TIER_RECLAIM=1                  # 1 = Auto-reconnect to 165+ Mbps 5GHz AP when Hotspot is off
FAVORITE_TOP_TIER_AP="58:61:63:00:ab:17"   # Proven 165+ Mbps AP on Ch 116
RECLAIM_CHECK_INTERVAL=15                  # Check every 15s if favorite 5GHz AP is visible

# Candidate Queue & Bailout Settings
MAX_CANDIDATES=2              # Try at most the top 2 candidates per cycle

# Permanent Dead AP Blacklist (Known 0.0 Mbps / packet loss / association timeout traps from speed benchmarks)
PERMANENT_DEAD_APS=(
    "58:61:63:fe:b6:7b"     # 0.0 Mbps (-84 dBm)
    "58:61:63:fe:a6:82"     # 0.0 - 0.6 Mbps (-85 dBm)
    "58:61:63:fe:9b:99"     # 0.0 - 1.4 Mbps (-78 dBm)
    "06:7b:e9:22:20:4c"     # 0.0 - 0.4 Mbps dead trap (-79 dBm)
    "06:7b:e9:20:f8:c8"     # 0.0 - 4.3 Mbps trap (-71 dBm)
    "06:7b:e9:22:44:2e"     # 0.0 Mbps (-78 dBm)
    "58:61:63:fe:a9:2b"     # 1.1 - 2.2 Mbps trap (-81 dBm)
)

if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
LOG_FILE="$SCRIPT_DIR/klu_wifi_history.log"
SPEED_LOG="$SCRIPT_DIR/klu_wifi_speeds.log"
MAX_HISTORY=8

# Colors for terminal display
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
BOLD="\033[1m"
RESET="\033[0m"

# State tracking
fail_count=0
PREV_BSSID=""
LAST_CHANGE_SUMMARY=""
LAST_CHANGE_DETAIL=""
ETHERNET_FAILOVER_ACTIVE=0
CURRENT_BSSID_SPEED="Not Tested"
CURRENT_RAW_SPEED="0.0"
CURRENT_SPEED_TIME=""
LAST_TESTED_BSSID=""
LAST_SPEED_TEST_TIME=0
LAST_SPEED_ROAM_TIME=0
LAST_KEEPALIVE_TIME=0
LAST_RECLAIM_CHECK_TIME=0
KEEPALIVE_INTERVAL=15
declare -a SWITCH_HISTORY=()
declare -A FAIL_PENALTY=()

# Upgrade I: Signal Trend Guard — track last 3 readings for proactive roaming
declare -a SIGNAL_HISTORY=()
LAST_TREND_CHECK_TIME=0
TREND_CHECK_INTERVAL=9    # Check trend every 9s (3 x 3s main loop cycles)

# Upgrade J: Non-blocking speed test state (written by bg process, read by main loop)
SPEED_TEST_TMPFILE="/tmp/klu_speedtest_$$.tmp"
SPEED_TEST_RUNNING=0

# Stability Fix: Rolling speed average over last 3 tests (anti-dancing)
declare -a SPEED_WINDOW=()        # Circular buffer of last 3 speed results
SPEED_WINDOW_SIZE=3               # Must have 3 samples before triggering roam decision
STABLE_SPEED_THRESHOLD=40         # If avg of last 3 tests >= 40 Mbps, AP is "stable" — do NOT roam away
LAST_PORTAL_LOGIN_TIME=0
PORTAL_LOGIN_COOLDOWN=300         # Upgrade H: Re-login at most once per 5 minutes

# Safety Trap: Preserve active Wi-Fi connection with zero interruption on exit
cleanup() {
    rm -f "/tmp/klu_watchdog.pid"
    echo -e "\n${GREEN}Watchdog stopped. Active Wi-Fi connection preserved with zero interruption.${RESET}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Prioritize KLU_WIFI, enforce fast DNS, and optimize DHCP unicast re-binding (Upgrade B)
nmcli connection modify "$CONNECTION" connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null 2>&1
nmcli connection modify "$CONNECTION" ipv4.dns "1.1.1.1 8.8.8.8 172.16.103.254" >/dev/null 2>&1
nmcli connection modify "$CONNECTION" ipv4.dhcp-timeout 5 ipv4.dhcp-send-hostname yes >/dev/null 2>&1

# Load previous switch history from log file if it exists
if [ -f "$LOG_FILE" ]; then
    while IFS= read -r line; do
        if [[ "$line" =~ CHANGED: ]]; then
            SWITCH_HISTORY+=("$line")
        fi
    done < <(grep "CHANGED:" "$LOG_FILE" 2>/dev/null | tail -n "$MAX_HISTORY")
fi

# ==========================================
# HELPER FUNCTIONS
# ==========================================

# Smart Notification Helper with Per-Feature Settings
send_notify() {
    local type="$1"   # "speed", "roam", "general"
    local urgency="$2"
    local title="$3"
    local body="$4"

    local conf_file="/home/${SUDO_USER:-$USER}/.config/klu-switch.conf"
    [ ! -f "$conf_file" ] && conf_file="/home/goutham/.config/klu-switch.conf"
    local NOTIFICATIONS_ENABLED="true"
    local NOTIFY_SPEED="true"
    local NOTIFY_ROAM="true"

    if [ -f "$conf_file" ]; then
        source "$conf_file" 2>/dev/null || true
    fi

    [ "$NOTIFICATIONS_ENABLED" = "false" ] && return 0
    if [ "$type" = "speed" ] && [ "$NOTIFY_SPEED" = "false" ]; then
        return 0
    fi
    if [ "$type" = "roam" ] && [ "$NOTIFY_ROAM" = "false" ]; then
        return 0
    fi

    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u "$urgency" "$title" "$body" 2>/dev/null &
    fi
}


get_current_bssid() {
    iw dev "$INTERFACE" link 2>/dev/null |
        awk '/Connected to/ {print $3}'
}

get_signal() {
    iw dev "$INTERFACE" link 2>/dev/null |
        awk '/signal:/ {print $2}'
}

get_gateway() {
    ip route show dev "$INTERFACE" 2>/dev/null | awk '/default/ {print $3}' | head -n 1
}

# Returns 0 if IP responds to ping on the specific WiFi interface
ping_check() {
    ping -c 1 -W 0.5 -I "$INTERFACE" "$1" >/dev/null 2>&1
}

# Checks real internet connectivity on the Wi-Fi interface in milliseconds
# Fast generate_204 check (typically 30-100ms) with sub-second fallback
internet_ok() {
    # 1. Primary check: Ultra-fast HTTP 204 check (no TLS handshake overhead)
    local code_204
    code_204=$(curl -4 -s -m 0.8 --connect-timeout 0.5 -o /dev/null -w "%{http_code}" --interface "$INTERFACE" http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)
    if [ "$code_204" = "204" ] || [ "$code_204" = "200" ]; then
        return 0
    fi

    # 2. Secondary check: Fast HTTPS check (-k permits Sophos SSL CA)
    local http_code
    http_code=$(curl -4 -s -k -m 0.8 --connect-timeout 0.5 -o /dev/null -w "%{http_code}" --interface "$INTERFACE" https://www.google.com 2>/dev/null)
    if [ "$http_code" = "200" ]; then
        return 0
    fi

    # 3. Fallback: Ultra-fast 0.5s ping check
    if ping_check "$TEST_IP" || ping_check "$TEST_IP_BACKUP"; then
        return 0
    fi

    return 1
}

gateway_ok() {
    local gw
    gw=$(get_gateway)
    [ -n "$gw" ] && ping_check "$gw"
}

# Ultra-Fast Captive Portal Check (20-30ms response time)
portal_reachable() {
    local pcode
    pcode=$(curl -4 -s -m 0.5 --connect-timeout 0.4 -o /dev/null -w "%{http_code}" --interface "$INTERFACE" "$PORTAL_URL" 2>/dev/null)
    if [ "$pcode" = "200" ] || [ "$pcode" = "302" ]; then
        return 0
    fi
    ping -c 1 -W 0.5 -I "$INTERFACE" "$PORTAL_IP" >/dev/null 2>&1
}

# Sticky BSSID Anchor: locks active BSSID on profile to prevent NetworkManager autonomous background scanning
lock_current_bssid() {
    local target="$1"
    [ -z "$target" ] && return
    if is_hotspot_active; then
        local chan
        chan=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
        if ([ "$chan" -ge 52 ] && [ "$chan" -le 64 ]) || ([ "$chan" -ge 100 ] && [ "$chan" -le 144 ]); then
            return 0
        fi
    fi
    local cur_locked
    cur_locked=$(nmcli -t -f 802-11-wireless.bssid connection show "$CONNECTION" 2>/dev/null | cut -d: -f2-)
    if [ "${cur_locked,,}" != "${target,,}" ]; then
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "$target" >/dev/null 2>&1
    fi
}

unlock_bssid() {
    local cur_locked
    cur_locked=$(nmcli -t -f 802-11-wireless.bssid connection show "$CONNECTION" 2>/dev/null | cut -d: -f2-)
    if [ -n "$cur_locked" ]; then
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "" >/dev/null 2>&1
    fi
}

# Translates between 5GHz (00:) and 2.4GHz (fe:) twin BSSIDs on identical physical APs
get_twin_bssid() {
    local bssid="${1,,}"
    if [[ "$bssid" =~ ^58:61:63:00: ]]; then
        echo "58:61:63:fe:${bssid#58:61:63:00:}"
    elif [[ "$bssid" =~ ^58:61:63:fe: ]]; then
        echo "58:61:63:00:${bssid#58:61:63:fe:}"
    fi
}

# Keep-Alive & Upgrade D: Keeps Cyberoam NAT session & campus gateway ARP table active
keep_alive_portal() {
    local now
    now=$(date +%s)
    if [ $((now - LAST_KEEPALIVE_TIME)) -ge "$KEEPALIVE_INTERVAL" ]; then
        LAST_KEEPALIVE_TIME="$now"
        # Upgrade D: Gateway ARP Keep-Warm (refreshes router CAM/ARP hardware table entry)
        local gw
        gw=$(get_gateway)
        if [ -n "$gw" ]; then
            if command -v arping >/dev/null 2>&1; then
                arping -c 1 -w 1 -I "$INTERFACE" "$gw" >/dev/null 2>&1 &
            else
                ping -c 1 -W 1 -I "$INTERFACE" "$gw" >/dev/null 2>&1 &
            fi
        fi

        # Upgrade G: Firewall Session Keep-alive — resets Sophos/Cyberoam idle TCP timer
        # Without this, after ~4 min idle the firewall silently expires your session
        curl -4 -s -m 2 -o /dev/null --interface "$INTERFACE" "$PORTAL_URL" 2>/dev/null &
        curl -4 -s -m 2 -o /dev/null --interface "$INTERFACE" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null &
    fi
}

# Upgrade H: Auto Portal Re-login — submits saved credentials when session expires
# Detects the redirect pattern: internet_ok fails but portal is reachable (= firewall wall)
auto_login_portal() {
    local now
    now=$(date +%s)
    [ $((now - LAST_PORTAL_LOGIN_TIME)) -lt "$PORTAL_LOGIN_COOLDOWN" ] && return 0

    # Only attempt if portal is up but internet is blocked (= session expired, needs re-login)
    if portal_reachable && ! internet_ok; then
        echo -e "${YELLOW}>> [AUTO-LOGIN] Portal reachable but internet blocked. Session may have expired. Attempting re-login...${RESET}"
        # Submit login form using curl POST (Sophos/Cyberoam httpclient format)
        local login_result
        login_result=$(curl -4 -s -k -m 5 -o /dev/null -w "%{http_code}" \
            --interface "$INTERFACE" \
            -X POST "$PORTAL_URL" \
            -d 'mode=191&username=&password=&a=1&producttype=0' \
            2>/dev/null)
        LAST_PORTAL_LOGIN_TIME="$now"
        if internet_ok; then
            echo -e "${GREEN}>> [AUTO-LOGIN] Re-login succeeded! Internet restored.${RESET}"
            local timestamp
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$timestamp] AUTO_LOGIN: Portal session refreshed successfully." >> "$LOG_FILE"
            return 0
        else
            echo -e "${CYAN}>> [AUTO-LOGIN] Re-login attempted (HTTP $login_result). Will retry if needed.${RESET}"
        fi
    fi
    return 1
}

# Upgrade E: DNS Pre-warm — pre-resolve key hostnames before a BSSID switch
# Prevents the 1-3s DNS cold-start delay after every AP change
dns_prewarm() {
    # Fire-and-forget: pre-populate system DNS cache before switching
    ( dig +short +timeout=1 +tries=1 @1.1.1.1 www.google.com >/dev/null 2>&1 ) &
    ( dig +short +timeout=1 +tries=1 @8.8.8.8 connectivitycheck.gstatic.com >/dev/null 2>&1 ) &
}

# --- Wi-Fi Speed Testing & Benchmarking ---

# Upgrade J: Non-blocking background speed test
# Writes result to SPEED_TEST_TMPFILE; main loop reads it without blocking
run_speed_test_bg() {
    local bssid="$1"
    [ -z "$bssid" ] && bssid=$(get_current_bssid)
    [ -z "$bssid" ] && return 1
    [ "$SPEED_TEST_RUNNING" -eq 1 ] && return 0   # Already running; don't double-start

    SPEED_TEST_RUNNING=1
    local tmpfile="$SPEED_TEST_TMPFILE"
    local interface="$INTERFACE"
    local speed_log="$SPEED_LOG"
    local log_file="$LOG_FILE"
    local sig
    sig=$(get_signal)
    local cur_ch
    cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
    local band="2.4GHz"
    [ -n "$cur_ch" ] && [ "$cur_ch" -gt 14 ] && band="5GHz"

    echo -e "${CYAN}>>> [SPEED TEST BG] Starting background speed test on $bssid (Ch ${cur_ch:-?})...${RESET}"

    (
        local bytes_per_sec
        bytes_per_sec=$(curl -4 -s -k -m 5 --interface "$interface" -w "%{speed_download}" -o /dev/null \
            "https://speed.cloudflare.com/__down?bytes=5000000" 2>/dev/null)
        if [ -z "$bytes_per_sec" ] || [ "${bytes_per_sec%%.*}" -eq 0 ] 2>/dev/null; then
            bytes_per_sec=$(curl -4 -s -k -m 4 --interface "$interface" -w "%{speed_download}" -o /dev/null \
                "https://speed.cloudflare.com/__down?bytes=2500000" 2>/dev/null)
        fi

        local mbps="0.0"
        if [ -n "$bytes_per_sec" ] && [ "${bytes_per_sec%%.*}" -gt 0 ] 2>/dev/null; then
            mbps=$(awk -v b="$bytes_per_sec" 'BEGIN { printf "%.1f", (b * 8) / 1000000 }')
        fi

        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local time_short
        time_short=$(date '+%H:%M:%S')

        # Write result to temp file (main loop polls this)
        echo "mbps=$mbps bssid=${bssid,,} time=$time_short ch=${cur_ch:-?} band=$band sig=${sig:-N/A}" > "$tmpfile"

        echo "[$timestamp] BSSID: ${bssid,,} | Speed: ${mbps} Mbps | Signal: ${sig:-N/A} dBm | Chan: ${cur_ch:-?} | Band: $band" >> "$speed_log"
        echo "[$timestamp] SPEED_BENCHMARK: ${bssid,,} -> ${mbps} Mbps (${sig:-N/A} dBm | Ch ${cur_ch:-?})" >> "$log_file"

        if command -v notify-send >/dev/null 2>&1; then
            send_notify "speed" "low" "KLU Speed Test" "BSSID: $bssid | ${mbps} Mbps (${sig:-N/A} dBm)"
        fi
    ) &
    # Store bg PID so we can detect when it finishes
    SPEED_TEST_PID=$!
}

# Low-Speed Circuit Breaker: Automatically seek another network if speed drops below 5 Mbps
handle_low_speed() {
    local bssid="$1"
    local mbps="$2"
    [ -z "$bssid" ] && bssid=$(get_current_bssid)
    [ -z "$bssid" ] && return 0
    [ "${ENABLE_LOW_SPEED_ROAM:-1}" -ne 1 ] && return 0

    local is_choked
    is_choked=$(awk -v m="$mbps" -v lim="$MIN_ACCEPTABLE_SPEED" 'BEGIN { print (m < lim) ? 1 : 0 }')
    if [ "$is_choked" -eq 1 ]; then
        echo
        echo -e "${RED}>>> [SLOW NETWORK ALERT] Throughput ${mbps} Mbps is below minimum threshold (${MIN_ACCEPTABLE_SPEED} Mbps)!${RESET}"
        echo -e "${YELLOW}>>> AP $bssid is congested/choked. Automatically roaming to another network...${RESET}"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] LOW_SPEED: $bssid reported ${mbps} Mbps (< ${MIN_ACCEPTABLE_SPEED} Mbps). Roaming triggered." >> "$LOG_FILE"
        add_to_blacklist "$bssid"
        unlock_bssid
        recover_connection
        return 0
    fi
    return 1
}

# Read result of completed background speed test and update state variables
collect_speed_test_result() {
    [ "$SPEED_TEST_RUNNING" -eq 0 ] && return 1
    # Check if background process has finished
    if ! kill -0 "$SPEED_TEST_PID" 2>/dev/null; then
        SPEED_TEST_RUNNING=0
        if [ -f "$SPEED_TEST_TMPFILE" ]; then
            local result
            result=$(cat "$SPEED_TEST_TMPFILE" 2>/dev/null)
            [ -z "$result" ] && return 1
            local mbps bssid time_short
            mbps=$(echo "$result" | grep -o 'mbps=[^ ]*' | cut -d= -f2)
            bssid=$(echo "$result" | grep -o 'bssid=[^ ]*' | cut -d= -f2)
            time_short=$(echo "$result" | grep -o 'time=[^ ]*' | cut -d= -f2)
            [ -z "$mbps" ] && return 1

            CURRENT_BSSID_SPEED="${mbps} Mbps"
            CURRENT_RAW_SPEED="$mbps"
            CURRENT_SPEED_TIME="$time_short"
            LAST_TESTED_BSSID="$bssid"
            LAST_SPEED_TEST_TIME=$(date +%s)

            # Stability Fix: Update rolling speed window (last 3 samples)
            SPEED_WINDOW+=("$mbps")
            if [ "${#SPEED_WINDOW[@]}" -gt "$SPEED_WINDOW_SIZE" ]; then
                SPEED_WINDOW=("${SPEED_WINDOW[@]:1}")
            fi

            rm -f "$SPEED_TEST_TMPFILE"
            echo -e "${GREEN}>>> [SPEED RESULT] $bssid: ${BOLD}${mbps} Mbps${RESET}${GREEN} @ ${time_short}${RESET}"

            # Auto-roam if speed < 5 Mbps
            handle_low_speed "$bssid" "$mbps"
            return 0
        fi
    fi
    return 1  # Still running
}

# Legacy blocking speed test (used during initial AP evaluation only, not in main loop)
run_speed_test() {
    local bssid="$1"
    [ -z "$bssid" ] && bssid=$(get_current_bssid)
    [ -z "$bssid" ] && return 1

    local sig
    sig=$(get_signal)
    local cur_ch
    cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
    local band="2.4GHz"
    [ -n "$cur_ch" ] && [ "$cur_ch" -gt 14 ] && band="5GHz"

    echo
    echo -e "${CYAN}>>> [SPEED TEST] Testing download throughput on $bssid (Ch ${cur_ch:-?}, ${sig:-N/A} dBm)...${RESET}"

    local bytes_per_sec
    bytes_per_sec=$(curl -4 -s -k -m 5 --interface "$INTERFACE" -w "%{speed_download}" -o /dev/null "https://speed.cloudflare.com/__down?bytes=5000000" 2>/dev/null)
    if [ -z "$bytes_per_sec" ] || [ "${bytes_per_sec%%.*}" -eq 0 ] 2>/dev/null; then
        bytes_per_sec=$(curl -4 -s -k -m 4 --interface "$INTERFACE" -w "%{speed_download}" -o /dev/null "https://speed.cloudflare.com/__down?bytes=2500000" 2>/dev/null)
    fi

    local mbps="0.0"
    if [ -n "$bytes_per_sec" ] && [ "${bytes_per_sec%%.*}" -gt 0 ] 2>/dev/null; then
        mbps=$(awk -v b="$bytes_per_sec" 'BEGIN { printf "%.1f", (b * 8) / 1000000 }')
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local time_short
    time_short=$(date '+%H:%M:%S')

    CURRENT_BSSID_SPEED="${mbps} Mbps"
    CURRENT_RAW_SPEED="$mbps"
    CURRENT_SPEED_TIME="$time_short"
    LAST_TESTED_BSSID="$bssid"
    LAST_SPEED_TEST_TIME=$(date +%s)

    # Update rolling speed window
    SPEED_WINDOW+=("$mbps")
    if [ "${#SPEED_WINDOW[@]}" -gt "$SPEED_WINDOW_SIZE" ]; then
        SPEED_WINDOW=("${SPEED_WINDOW[@]:1}")
    fi

    echo "[$timestamp] BSSID: ${bssid,,} | Speed: ${mbps} Mbps | Signal: ${sig:-N/A} dBm | Chan: ${cur_ch:-?} | Band: $band" >> "$SPEED_LOG"
    echo "[$timestamp] SPEED_BENCHMARK: ${bssid,,} -> ${mbps} Mbps (${sig:-N/A} dBm | Ch ${cur_ch:-?})" >> "$LOG_FILE"
    echo -e "${GREEN}>>> [SPEED TEST RESULT] BSSID $bssid: ${BOLD}${mbps} Mbps${RESET}${GREEN} (${sig:-N/A} dBm)${RESET}"

    # Auto-roam if speed < 5 Mbps
    handle_low_speed "$bssid" "$mbps"

    send_notify "speed" "normal" "KLU Wi-Fi Speed Test" "BSSID: $bssid\nSpeed: ${mbps} Mbps\nSignal: ${sig:-N/A} dBm"
}

display_speed_rankings() {
    [ ! -f "$SPEED_LOG" ] && return 0
    [ ! -s "$SPEED_LOG" ] && return 0

    local rankings
    rankings=$(python3 -c '
import sys, re
scores = {}
try:
    with open(sys.argv[1], "r") as f:
        for line in f:
            m = re.search(r"BSSID:\s*([0-9a-fA-F:]+)\s*\|\s*Speed:\s*([\d\.]+)\s*Mbps\s*\|\s*Signal:\s*([^\|]+)\s*\|\s*Chan:\s*([^\s\|]+)", line)
            if m:
                bssid, spd, sig, chan = m.groups()
                b = bssid.lower()
                s = float(spd)
                if b not in scores or s > scores[b][0]:
                    scores[b] = (s, sig.strip(), chan.strip())
    medals = ["🥇", "🥈", "🥉", "4️⃣", "5️⃣"]
    i = 0
    for b, (spd, sig, chan) in sorted(scores.items(), key=lambda x: x[1][0], reverse=True)[:5]:
        medal = medals[i] if i < len(medals) else "•"
        print(f"  {medal} {b} : {spd:.1f} Mbps (Signal: {sig} | Ch {chan})")
        i += 1
except Exception:
    pass
' "$SPEED_LOG" 2>/dev/null)

    if [ -n "$rankings" ]; then
        echo -e "${CYAN}----------------------------------------------------${RESET}"
        echo -e "${BOLD}🏆 KLU SPEED RANKINGS (Highest Throughput First):${RESET}"
        echo -e "$rankings"
    fi
}

# --- Speed-Aware Proactive Roaming (Stability Priority) ---
find_fastest_visible_candidate() {
    local hs_on=0
    is_hotspot_active && hs_on=1

    python3 -c '
import sys, subprocess, re

speed_log = sys.argv[1]
interface = sys.argv[2]
target_ssid = sys.argv[3]
min_sig = int(sys.argv[4])
hs_on = int(sys.argv[5])
high_speed_target = float(sys.argv[6])

best_speeds = {}
try:
    with open(speed_log, "r") as f:
        for line in f:
            m = re.search(r"BSSID:\s*([0-9a-fA-F:]+)\s*\|\s*Speed:\s*([\d\.]+)\s*Mbps", line)
            if m:
                b = m.group(1).lower()
                s = float(m.group(2))
                if b not in best_speeds or s > best_speeds[b]:
                    best_speeds[b] = s
except Exception:
    pass

try:
    res = subprocess.run(["nmcli", "-t", "-f", "BSSID,SSID,CHAN,SIGNAL", "device", "wifi", "list", "ifname", interface],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    candidates = []
    for line in res.stdout.strip().split("\n"):
        parts = line.replace("\\", "").split(":")
        if len(parts) >= 9:
            bssid = ":".join(parts[0:6]).lower()
            ssid = parts[6]
            chan = int(parts[7]) if parts[7].isdigit() else 0
            signal = int(parts[8]) if parts[8].isdigit() else 0
            if ssid == target_ssid and signal >= min_sig:
                if hs_on == 1 and ((52 <= chan <= 64) or (100 <= chan <= 144)):
                    continue
                spd = best_speeds.get(bssid, 0.0)
                if spd >= high_speed_target:
                    candidates.append((spd, signal, bssid))
    if candidates:
        candidates.sort(key=lambda x: (x[0], x[1]), reverse=True)
        print(candidates[0][2])
except Exception:
    pass
' "$SPEED_LOG" "$INTERFACE" "$TARGET_SSID" "$MIN_SIGNAL" "$hs_on" "$HIGH_SPEED_TARGET" 2>/dev/null
}

upgrade_to_fast_bssid() {
    local target="$1"
    local anchor="$2"

    echo
    echo -e "${CYAN}>>> [SPEED UPGRADE] Initiating fast switch to Tier-1 AP: $target (Anchor: ${anchor:-None})${RESET}"

    nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "$target" >/dev/null 2>&1
    if ! nmcli -w 4 connection up "$CONNECTION" >/dev/null 2>&1; then
        echo -e "${RED}Upgrade failed to associate. Reverting to anchor $anchor...${RESET}"
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "$anchor" >/dev/null 2>&1
        nmcli -w 4 connection up "$CONNECTION" >/dev/null 2>&1 || true
        add_to_blacklist "$target"
        return 1
    fi

    if internet_ok; then
        local sig
        sig=$(get_signal)
        echo -e "${GREEN}>>> SUCCESS: Speed upgrade verified! Connected to $target ($sig dBm)${RESET}"
        record_switch "$anchor" "$target" "Speed-Upgrade" "${sig:-N/A}"
        PREV_BSSID="$target"
        LAST_TESTED_BSSID=""
        adapt_hotspot_to_wifi "$target"
        return 0
    else
        echo -e "${RED}>>> Target $target did not pass internet test. Reverting to anchor $anchor...${RESET}"
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "$anchor" >/dev/null 2>&1
        nmcli -w 4 connection up "$CONNECTION" >/dev/null 2>&1 || true
        add_to_blacklist "$target"
        return 1
    fi
}

# Stability Fix: Compute rolling average speed from SPEED_WINDOW
get_rolling_avg_speed() {
    local n=${#SPEED_WINDOW[@]}
    [ "$n" -eq 0 ] && echo "0.0" && return
    awk -v arr="${SPEED_WINDOW[*]}" 'BEGIN {
        n = split(arr, a, " ")
        s = 0
        for(i=1;i<=n;i++) s += a[i]
        printf "%.1f", (n > 0 ? s/n : 0)
    }'
}

check_speed_upgrade() {
    # Stability-First Rule: Leave stable working connection alone; don't hunt high speed / no dancing
    [ "$ENABLE_SPEED_ROAM" -ne 1 ] && return 0

    local now
    now=$(date +%s)
    [ $((now - LAST_SPEED_ROAM_TIME)) -lt "$SPEED_ROAM_COOLDOWN" ] && return 0

    local current_bssid
    current_bssid=$(get_current_bssid)
    [ -z "$current_bssid" ] && return 0

    # Stability Fix: Only roam if we have at least SPEED_WINDOW_SIZE samples
    # Prevents 1-2 bad speed test spikes from triggering a roam (the "dancing" bug)
    local n_samples=${#SPEED_WINDOW[@]}
    if [ "$n_samples" -lt "$SPEED_WINDOW_SIZE" ]; then
        echo -e "${CYAN}>> [STABILITY] Only ${n_samples}/${SPEED_WINDOW_SIZE} speed samples — waiting for full window before roam decision.${RESET}"
        return 0
    fi

    local avg_speed
    avg_speed=$(get_rolling_avg_speed)

    # Stability Fix: If rolling avg >= STABLE_SPEED_THRESHOLD, this AP is STABLE. Do NOT roam.
    local is_stable
    is_stable=$(awk -v avg="$avg_speed" -v threshold="$STABLE_SPEED_THRESHOLD" 'BEGIN {
        print (avg >= threshold) ? 1 : 0
    }')
    if [ "$is_stable" -eq 1 ]; then
        echo -e "${GREEN}>> [STABILITY LOCK] Rolling avg ${avg_speed} Mbps >= ${STABLE_SPEED_THRESHOLD} Mbps. AP is stable — NOT roaming.${RESET}"
        return 0
    fi

    # Only roam if rolling avg is below threshold (persistently slow, not a spike)
    local is_slow
    is_slow=$(awk -v avg="$avg_speed" -v limit="$MIN_ACCEPTABLE_SPEED" 'BEGIN {
        if (avg > 0.0 && avg < limit) print 1; else print 0
    }')
    [ "$is_slow" -ne 1 ] && return 0

    local target_ap
    target_ap=$(find_fastest_visible_candidate)
    if [ -n "$target_ap" ] && [ "${target_ap,,}" != "${current_bssid,,}" ]; then
        if ! is_blacklisted "$target_ap"; then
            echo -e "${YELLOW}>> [SPEED UPGRADE] Rolling avg ${avg_speed} Mbps < ${MIN_ACCEPTABLE_SPEED} Mbps for ${n_samples} samples.${RESET}"
            echo -e "${GREEN}>> Proven Tier-1 AP visible: $target_ap. Roaming for higher throughput...${RESET}"
            LAST_SPEED_ROAM_TIME="$now"
            SPEED_WINDOW=()   # Reset window after roam
            upgrade_to_fast_bssid "$target_ap" "$current_bssid"
        fi
    fi
}

# Upgrade I: Signal Trend Guard — detect a deteriorating signal BEFORE it causes a drop
# Tracks last 3 signal readings; if all 3 are declining AND below -75 dBm, proactively roam
check_signal_trend() {
    local now
    now=$(date +%s)
    [ $((now - LAST_TREND_CHECK_TIME)) -lt "$TREND_CHECK_INTERVAL" ] && return 0
    LAST_TREND_CHECK_TIME="$now"

    local sig
    sig=$(get_signal)
    [ -z "$sig" ] && return 0

    # Append to history (keep last 3)
    SIGNAL_HISTORY+=("$sig")
    if [ "${#SIGNAL_HISTORY[@]}" -gt 3 ]; then
        SIGNAL_HISTORY=("${SIGNAL_HISTORY[@]:1}")
    fi

    [ "${#SIGNAL_HISTORY[@]}" -lt 3 ] && return 0

    local s1=${SIGNAL_HISTORY[0]}
    local s2=${SIGNAL_HISTORY[1]}
    local s3=${SIGNAL_HISTORY[2]}

    # Check: all 3 readings below -75 dBm AND strictly declining (s1 > s2 > s3)
    local trend_bad
    trend_bad=$(awk -v s1="$s1" -v s2="$s2" -v s3="$s3" 'BEGIN {
        # Signal is negative; "declining" means getting more negative (lower)
        print (s1 > s2 && s2 > s3 && s3 < -75) ? 1 : 0
    }')

    if [ "$trend_bad" -eq 1 ]; then
        echo -e "${YELLOW}>> [TREND GUARD] Signal declining: ${s1} -> ${s2} -> ${s3} dBm. Proactively roaming before drop!${RESET}"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] TREND_GUARD: Signal ${s1}->${s2}->${s3} dBm — proactive roam triggered." >> "$LOG_FILE"
        SIGNAL_HISTORY=()
        unlock_bssid
        recover_connection
    fi
}

# Upgrade A: Targeted Top-Tier Beacon Watcher (First-in-Line Reclaim)
# When the favorite 165+ Mbps AP ($FAVORITE_TOP_TIER_AP) finishes rebooting, claims Client Slot #1 immediately!
check_top_tier_reclaim() {
    [ "${ENABLE_TOP_TIER_RECLAIM:-0}" -ne 1 ] && return 0
    # Do not reclaim if hotspot is currently active on single card (DFS safety)
    is_hotspot_active && return 0

    local now
    now=$(date +%s)
    [ $((now - LAST_RECLAIM_CHECK_TIME)) -lt "$RECLAIM_CHECK_INTERVAL" ] && return 0
    LAST_RECLAIM_CHECK_TIME="$now"

    local cur_bssid
    cur_bssid=$(get_current_bssid)
    [ -z "$cur_bssid" ] && return 0
    # Only reclaim if we are currently NOT on the favorite top-tier AP
    [ "${cur_bssid,,}" = "${FAVORITE_TOP_TIER_AP,,}" ] && return 0

    # Fast targeted check: see if FAVORITE_TOP_TIER_AP has booted back up and is visible
    local visible_sig
    visible_sig=$(nmcli -t -f BSSID,SIGNAL device wifi list ifname "$INTERFACE" 2>/dev/null | sed 's/\\//g' | awk -F: -v target="${FAVORITE_TOP_TIER_AP,,}" '
        tolower($1 ":" $2 ":" $3 ":" $4 ":" $5 ":" $6) == target { print $7; exit }
    ')

    if [ -n "$visible_sig" ] && [ "$visible_sig" -ge "$MIN_SIGNAL" ] 2>/dev/null; then
        echo
        echo -e "${GREEN}>> [FIRST-TO-CONNECT] Top-Tier 5GHz AP ($FAVORITE_TOP_TIER_AP) is back online (${visible_sig}% signal)!${RESET}"
        echo -e "${CYAN}>> Claiming Client Slot #1 before other devices notice reboot...${RESET}"
        switch_to_bssid "$FAVORITE_TOP_TIER_AP"
    fi
}

# --- Ethernet Failover & Priority Management ---
get_active_ethernet() {
    # Returns "DEVICE|CONNECTION" for any active wired ethernet
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null |
        awk -F: '$2 == "ethernet" && $3 == "connected" && $4 != "" && $4 != "--" {print $1 "|" $4; exit}'
}

ensure_wifi_primary() {
    # Keeps Wi-Fi metric at 50 and Ethernet in standby (1000)
    local eth_info
    eth_info=$(get_active_ethernet)

    if [ -n "$eth_info" ]; then
        local eth_dev="${eth_info%|*}"
        local eth_con="${eth_info#*|}"

        local eth_metric
        eth_metric=$(nmcli -t -f ipv4.route-metric connection show "$eth_con" 2>/dev/null | cut -d: -f2)
        if [ "$eth_metric" != "1000" ]; then
            nmcli connection modify "$eth_con" ipv4.route-metric 1000 >/dev/null 2>&1
            nmcli device reapply "$eth_dev" >/dev/null 2>&1
        fi
    fi

    local wifi_metric
    wifi_metric=$(nmcli -t -f ipv4.route-metric connection show "$CONNECTION" 2>/dev/null | cut -d: -f2)
    if [ "$wifi_metric" != "50" ]; then
        nmcli connection modify "$CONNECTION" ipv4.route-metric 50 >/dev/null 2>&1
    fi
}

switch_to_ethernet() {
    local eth_info
    eth_info=$(get_active_ethernet)
    [ -z "$eth_info" ] && return 1

    local eth_dev="${eth_info%|*}"
    local eth_con="${eth_info#*|}"

    echo -e "${YELLOW}>>> [FAILOVER] Wi-Fi offline. Elevating Ethernet ($eth_dev) to Primary Route...${RESET}"
    nmcli connection modify "$eth_con" ipv4.route-metric 20 >/dev/null 2>&1
    nmcli device reapply "$eth_dev" >/dev/null 2>&1

    nmcli connection modify "$CONNECTION" ipv4.route-metric 1000 >/dev/null 2>&1
    nmcli device reapply "$INTERFACE" >/dev/null 2>&1

    ETHERNET_FAILOVER_ACTIVE=1

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] FAILOVER: Wi-Fi down -> Switched route to Ethernet ($eth_con / $eth_dev)" >> "$LOG_FILE"

    send_notify "general" "critical" "Wi-Fi Down -> Switched to Ethernet" "Traffic routed to $eth_con ($eth_dev) while Wi-Fi recovers."
    return 0
}

restore_to_wifi() {
    local eth_info
    eth_info=$(get_active_ethernet)

    echo -e "${GREEN}>>> [FALLBACK] Wi-Fi restored! Returning traffic to Wi-Fi ($CONNECTION)...${RESET}"
    nmcli connection modify "$CONNECTION" ipv4.route-metric 50 >/dev/null 2>&1
    nmcli device reapply "$INTERFACE" >/dev/null 2>&1

    if [ -n "$eth_info" ]; then
        local eth_dev="${eth_info%|*}"
        local eth_con="${eth_info#*|}"
        nmcli connection modify "$eth_con" ipv4.route-metric 1000 >/dev/null 2>&1
        nmcli device reapply "$eth_dev" >/dev/null 2>&1
    fi

    ETHERNET_FAILOVER_ACTIVE=0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] FALLBACK: Wi-Fi restored -> Switched route back to Wi-Fi ($CONNECTION)" >> "$LOG_FILE"

    send_notify "general" "normal" "Wi-Fi Restored" "Internet restored on $CONNECTION. Switched back from Ethernet."
}

# --- Hotspot Synchronization Helpers ---
chan_to_freq() {
    local ch="$1"
    if [ "$ch" -le 14 ]; then
        if [ "$ch" -eq 14 ]; then
            echo 2484
        else
            echo $(( 2407 + ch * 5 ))
        fi
    else
        echo $(( 5000 + ch * 5 ))
    fi
}

is_hotspot_active() {
    ip link show ap0 >/dev/null 2>&1 || [ -f "/tmp/klu_hotspot.state" ]
}


get_hotspot_channel() {
    iw dev ap0 info 2>/dev/null | awk '/channel/{print $2}'
}

sync_hotspot_channel() {
    local target_bssid="$1"
    if ! is_hotspot_active; then
        return 0
    fi

    # Read current or target Wi-Fi channel
    local target_chan
    target_chan=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
    if [ -z "$target_chan" ] && [ -n "$target_bssid" ]; then
        target_chan=$(nmcli -t -f BSSID,CHAN device wifi list ifname "$INTERFACE" 2>/dev/null |
            sed 's/\\//g' | awk -F: -v b="$target_bssid" '$1":"$2":"$3":"$4":"$5":"$6 == b {print $7; exit}')
    fi

    [ -z "$target_chan" ] && return 0

    local ap_chan
    ap_chan=$(get_hotspot_channel)
    [ -z "$ap_chan" ] && return 0

    if [ "$target_chan" != "$ap_chan" ]; then
        # Safety: Hostapd cannot switch between 2.4GHz and 5GHz on the fly via CSA.
        # Only switch channel if both are in the same band!
        if ([ "$target_chan" -le 14 ] && [ "$ap_chan" -gt 14 ]) || ([ "$target_chan" -gt 14 ] && [ "$ap_chan" -le 14 ]); then
            echo -e "${RED}>> Hotspot Sync: Cannot switch cross-band ($ap_chan to $target_chan) via CSA!${RESET}"
            return 1
        fi

        local freq
        freq=$(chan_to_freq "$target_chan")
        local ctrl_dir
        ctrl_dir=$(ls -d /tmp/create_ap.*/hostapd_ctrl 2>/dev/null | head -1)

        echo -e "${YELLOW}>> Hotspot Sync: Announcing channel switch ($ap_chan -> $target_chan / ${freq}MHz via CSA)...${RESET}"
        if sudo -n /usr/local/bin/manage_hotspot_clients chan_switch "$freq" 5 >/dev/null 2>&1; then
            sleep 1
            return 0
        elif [ -n "$ctrl_dir" ] && command -v hostapd_cli >/dev/null 2>&1; then
            hostapd_cli -p "$ctrl_dir" chan_switch 5 "$freq" >/dev/null 2>&1 || true
            sleep 1
        fi
    fi
}

# Adapts Hotspot to match Wi-Fi band & channel (Option B: Hotspot follows Wi-Fi)
adapt_hotspot_to_wifi() {
    local target_bssid="$1"
    if ! is_hotspot_active; then
        return 0
    fi

    # Read current Wi-Fi channel
    local cur_ch
    cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
    if [ -z "$cur_ch" ] && [ -n "$target_bssid" ]; then
        cur_ch=$(nmcli -t -f BSSID,CHAN device wifi list ifname "$INTERFACE" 2>/dev/null |
            sed 's/\\//g' | awk -F: -v b="$target_bssid" '$1":"$2":"$3":"$4":"$5":"$6 == b {print $7; exit}')
    fi
    [ -z "$cur_ch" ] && return 0

    local ap_ch
    ap_ch=$(get_hotspot_channel)
    [ -z "$ap_ch" ] && return 0

    local is_cur_5g=0; [ "$cur_ch" -gt 14 ] && is_cur_5g=1
    local is_ap_5g=0;  [ "$ap_ch" -gt 14 ] && is_ap_5g=1

    # Case 1: Same band -> seamless Channel Switch Announcement (CSA) without disconnect
    if [ "$is_cur_5g" -eq "$is_ap_5g" ]; then
        if [ "$cur_ch" != "$ap_ch" ]; then
            sync_hotspot_channel "$target_bssid"
        fi
        return 0
    fi

    # Case 2: Cross-band switch (2.4GHz <-> 5GHz) -> Option B band adapt & restart
    local new_band_label="2.4GHz"
    local conf_band="bg"
    if [ "$is_cur_5g" -eq 1 ]; then
        new_band_label="5GHz"
        conf_band="a"
    fi

    echo -e "${YELLOW}>> Hotspot Sync: Cross-band jump detected ($([ "$is_ap_5g" -eq 1 ] && echo "5G" || echo "2.4G") -> ${new_band_label} on Ch $cur_ch).${RESET}"
    echo -e "${YELLOW}>> Restarting Hotspot to match Wi-Fi band (clients will reconnect in ~3s)...${RESET}"

    if systemctl is-active --quiet wifi-hotspot@*.service 2>/dev/null; then
        systemctl restart wifi-hotspot@goutham.service >/dev/null 2>&1 &
    else
        local klu_hs_script="${SCRIPT_DIR}/klu_hotspot.sh"
        if [ -x "$klu_hs_script" ] && [ -f "/tmp/klu_hotspot.state" ]; then
            "$klu_hs_script" --restart >/dev/null 2>&1 &
        fi
    fi

    send_notify "general" "normal" "Hotspot Switched to $new_band_label" "Hotspot restarted on Ch $cur_ch to match Wi-Fi band."
}

is_permanent_dead() {
    local bssid="${1,,}"
    for dead in "${PERMANENT_DEAD_APS[@]}"; do
        if [ "$bssid" = "${dead,,}" ]; then
            return 0
        fi
    done
    return 1
}

is_blacklisted() {
    is_permanent_dead "$1"
}

is_top_tier_ap() {
    local bssid="${1,,}"
    [ ! -f "$SPEED_LOG" ] && return 1

    local is_top
    is_top=$(python3 -c '
import sys, re
target = sys.argv[1].lower()
log_file = sys.argv[2]
cutoff = float(sys.argv[3])
found = False
try:
    with open(log_file, "r") as f:
        for line in f:
            m = re.search(r"BSSID:\s*([0-9a-fA-F:]+)\s*\|\s*Speed:\s*([\d\.]+)\s*Mbps", line)
            if m:
                b = m.group(1).lower()
                s = float(m.group(2))
                if b == target and s >= cutoff:
                    found = True
                    break
except Exception:
    pass
print(1 if found else 0)
' "$bssid" "$SPEED_LOG" "$HIGH_SPEED_TARGET" 2>/dev/null)

    [ "$is_top" = "1" ] && return 0
    return 1
}

# Queue Logic: demotes failed AP to the back of the retry queue instead of 25s timeout blackout
demote_candidate() {
    local bssid="${1,,}"
    local p="${FAIL_PENALTY[$bssid]:-0}"
    FAIL_PENALTY["$bssid"]=$((p + 1))
    echo -e "${YELLOW}>> [QUEUE ROTATION] Demoted $bssid to back of queue (Attempt #$((p + 1))).${RESET}"
}

add_to_blacklist() {
    demote_candidate "$1"
}

reset_queue_penalties() {
    FAIL_PENALTY=()
}

record_switch() {
    local old_bssid="${1:-Disconnected}"
    local new_bssid="${2:-Unknown}"
    local reason="${3:-Auto-Roamed}"
    local signal="${4:-N/A}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local time_short
    time_short=$(date '+%H:%M:%S')

    local log_entry="[$timestamp] CHANGED: $old_bssid -> $new_bssid | Signal: ${signal}dBm | Reason: $reason"
    local display_entry="[$time_short] $old_bssid -> $new_bssid ($reason | ${signal}dBm)"

    # Append to persistent log file
    echo "$log_entry" >> "$LOG_FILE"

    # Add to in-memory display history
    SWITCH_HISTORY+=("$display_entry")
    if [ "${#SWITCH_HISTORY[@]}" -gt "$MAX_HISTORY" ]; then
        SWITCH_HISTORY=("${SWITCH_HISTORY[@]:1}")
    fi

    LAST_CHANGE_SUMMARY="[$time_short] $old_bssid -> $new_bssid"
    LAST_CHANGE_DETAIL="Reason: $reason | Signal: ${signal} dBm"

    # Desktop notification
    send_notify "roam" "normal" "KLU WiFi AP Changed" "From: $old_bssid\nTo:   $new_bssid\nSignal: ${signal} dBm\nReason: $reason"
}

show_status() {
    local bssid
    local signal
    local is_online=0
    local gw
    gw=$(get_gateway)

    # Guard: ensure the adapter is strictly connected to KLU_WIFI and not another profile (e.g. Spidyyy)
    local current_con
    current_con=$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | head -n 1 | cut -d: -f2)
    if [ -n "$current_con" ] && [[ ! "$current_con" =~ ^KLU_WIFI ]] && [ "$current_con" != "--" ]; then
        echo -e "${RED}ALERT: Device jumped to non-KLU network: '$current_con'!${RESET}"
        echo -e "${YELLOW}Disconnecting and forcing back to $CONNECTION...${RESET}"
        nmcli connection down "$current_con" >/dev/null 2>&1
        nmcli connection up "$CONNECTION" >/dev/null 2>&1
        sleep 2
    fi

    bssid=$(get_current_bssid)
    signal=$(get_signal)

    # Detect any BSSID change (automatic roaming or explicit switch)
    if [ -n "$bssid" ]; then
        if [ -z "$PREV_BSSID" ]; then
            PREV_BSSID="$bssid"
        elif [ "${bssid,,}" != "${PREV_BSSID,,}" ]; then
            record_switch "$PREV_BSSID" "$bssid" "AP-Roam" "${signal:-N/A}"
            PREV_BSSID="$bssid"
            adapt_hotspot_to_wifi "$bssid"
        fi
    fi

    local hs_status="${CYAN}Inactive${RESET}"
    if is_hotspot_active; then
        local ap_ch
        ap_ch=$(get_hotspot_channel)
        local cur_ch
        cur_ch=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2}')
        local hs_mode_tag="2.4GHz"
        [ -n "$ap_ch" ] && [ "$ap_ch" -gt 14 ] && hs_mode_tag="5GHz"
        hs_status="${GREEN}Active${RESET} (ap0 on Ch ${ap_ch:-?} [${hs_mode_tag}]) [Auto-Follow Wi-Fi]"

        # Check frequency/channel alignment between Wi-Fi and Hotspot
        if [ -n "$ap_ch" ] && [ -n "$cur_ch" ] && [[ "$ap_ch" =~ ^[0-9]+$ ]] && [[ "$cur_ch" =~ ^[0-9]+$ ]]; then
            # Check DFS collision first: Hotspot AP mode cannot operate on radar frequencies
            if ([ "$cur_ch" -ge 52 ] && [ "$cur_ch" -le 64 ]) || ([ "$cur_ch" -ge 100 ] && [ "$cur_ch" -le 144 ]); then
                echo -e "${RED}ALERT: Wi-Fi on DFS Ch $cur_ch! Hotspot cannot run on radar channels.${RESET}"
                echo -e "${YELLOW}Recovering Wi-Fi to a non-DFS channel...${RESET}"
                recover_connection
                return 1
            fi

            local is_cur_5g=0; [ "$cur_ch" -gt 14 ] && is_cur_5g=1
            local is_ap_5g=0;  [ "$ap_ch" -gt 14 ] && is_ap_5g=1

            if [ "$is_cur_5g" -ne "$is_ap_5g" ]; then
                adapt_hotspot_to_wifi "$bssid"
            elif [ "$ap_ch" != "$cur_ch" ]; then
                sync_hotspot_channel "$bssid"
            fi
        fi
    fi

    # Ethernet & Active Route Status
    local eth_info
    eth_info=$(get_active_ethernet)
    local eth_status="${CYAN}Unplugged / No Cable${RESET}"
    local route_status="${GREEN}Wi-Fi Primary (Metric 50)${RESET}"

    if [ -n "$eth_info" ]; then
        local eth_dev="${eth_info%|*}"
        local eth_con="${eth_info#*|}"
        if [ "$ETHERNET_FAILOVER_ACTIVE" -eq 1 ]; then
            eth_status="${YELLOW}Connected ($eth_con / $eth_dev) [ACTIVE FAILOVER]${RESET}"
            route_status="${RED}Ethernet Active (Wi-Fi Failed)${RESET}"
        else
            eth_status="${GREEN}Connected ($eth_con / $eth_dev) [Standby Backup]${RESET}"
            route_status="${GREEN}Wi-Fi Primary (Metric 50)${RESET}"
        fi
    else
        if [ "$ETHERNET_FAILOVER_ACTIVE" -eq 1 ]; then
            ETHERNET_FAILOVER_ACTIVE=0
        fi
    fi

    echo -e "${CYAN}====================================================${RESET}"
    echo -e "             ${BOLD}KLU WIFI WATCHDOG & ROAM MONITOR${RESET}"
    echo -e "${CYAN}====================================================${RESET}"
    echo -e "${BOLD}Current Time :${RESET} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}Profile Locked:${RESET} ${GREEN}${CONNECTION}${RESET} (Foreign networks blocked)"
    echo -e "${BOLD}Active BSSID :${RESET} ${GREEN}${bssid:-Disconnected}${RESET}"
    echo -e "${BOLD}Signal Level :${RESET} ${signal:-N/A} dBm"
    local speed_display="${CYAN}Pending test...${RESET}"
    if [ -n "$bssid" ] && [ "${bssid,,}" = "${LAST_TESTED_BSSID,,}" ] && [ "$CURRENT_BSSID_SPEED" != "Not Tested" ]; then
        speed_display="${GREEN}${CURRENT_BSSID_SPEED}${RESET} (Tested at ${CURRENT_SPEED_TIME})"
    fi
    echo -e "${BOLD}Speed (Test) :${RESET} $speed_display"
    echo -e "${BOLD}Gateway IP   :${RESET} ${gw:-None}"
    echo -e "${BOLD}Hotspot State:${RESET} $hs_status"
    echo -e "${BOLD}Ethernet     :${RESET} $eth_status"
    echo -e "${BOLD}Traffic Route:${RESET} $route_status"

    if internet_ok; then
        echo -e "${BOLD}Internet     :${RESET} ${GREEN}OK${RESET}"
        is_online=1
        [ -n "$bssid" ] && lock_current_bssid "$bssid"
        keep_alive_portal
        # Periodic Speed Test: test newly connected AP immediately, and re-test every 30 seconds
        local now
        now=$(date +%s)
        if [ -n "$bssid" ]; then
            if [ "${bssid,,}" != "${LAST_TESTED_BSSID,,}" ] || [ $((now - LAST_SPEED_TEST_TIME)) -ge "$SPEED_TEST_INTERVAL" ]; then
                run_speed_test "$bssid"
            fi
        fi
    else
        echo -e "${BOLD}Internet     :${RESET} ${RED}FAILED${RESET}"
        is_online=0
    fi

    echo -e "${BOLD}Fail Streak  :${RESET} $fail_count / $FAIL_LIMIT"

    # Display candidate queue demotions if any
    local q_count=0
    local q_text=""
    for q_bssid in "${!FAIL_PENALTY[@]}"; do
        local fails="${FAIL_PENALTY[$q_bssid]}"
        if [ "$fails" -gt 0 ]; then
            ((q_count++))
            q_text+="    • ${q_bssid} (${fails} failed attempts | back of queue)\n"
        fi
    done

    if [ "$q_count" -gt 0 ]; then
        echo -e "${CYAN}----------------------------------------------------${RESET}"
        echo -e "${BOLD}CANDIDATE QUEUE (Demoted / Active Retry):${RESET}"
        echo -en "$q_text"
    fi

    echo -e "${CYAN}----------------------------------------------------${RESET}"
    echo -e "${BOLD}LATEST BSSID CHANGE:${RESET}"
    if [ -n "$LAST_CHANGE_SUMMARY" ]; then
        echo -e "  ${YELLOW}$LAST_CHANGE_SUMMARY${RESET}"
        echo -e "  $LAST_CHANGE_DETAIL"
    else
        echo -e "  ${YELLOW}No changes yet this session.${RESET}"
        echo -e "  Initial AP: ${bssid:-None}"
    fi

    echo -e "${CYAN}----------------------------------------------------${RESET}"
    echo -e "${BOLD}RECENT BSSID TRANSITIONS (Newest First):${RESET}"
    if [ "${#SWITCH_HISTORY[@]}" -eq 0 ]; then
        echo -e "  (No BSSID transitions recorded yet)"
    else
        for (( i=${#SWITCH_HISTORY[@]}-1; i>=0; i-- )); do
            echo -e "  ${CYAN}•${RESET} ${SWITCH_HISTORY[i]}"
        done
    fi

    echo -e "${CYAN}----------------------------------------------------${RESET}"
    display_speed_rankings
    echo -e "${CYAN}----------------------------------------------------${RESET}"
    echo -e "${BOLD}📜 LIVE LOG ACTIVITY (Last 3 entries):${RESET}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 3 "$LOG_FILE" | while IFS= read -r line; do
            echo -e "  ${CYAN}»${RESET} $line"
        done
    else
        echo -e "  (No log entries yet)"
    fi
    echo -e "${CYAN}----------------------------------------------------${RESET}"
    echo -e "Logs: ${SCRIPT_DIR}/klu_wifi_history.log | ${SPEED_LOG}"
    echo -e "${CYAN}====================================================${RESET}"

    return $((1 - is_online))
}

# Scans strictly KLU_WIFI APs and excludes any blacklisted BSSIDs
find_candidates() {
    local hs_on=0
    if is_hotspot_active; then
        hs_on=1
    fi

    local raw_candidates
    raw_candidates=$(nmcli -t -f BSSID,SSID,CHAN,SIGNAL device wifi list ifname "$INTERFACE" 2>/dev/null |
        sed 's/\\//g' |
        awk -F: -v target="$TARGET_SSID" -v min="$MIN_SIGNAL" -v hs="$hs_on" '
        $7 == target {
            bssid=$1 ":" $2 ":" $3 ":" $4 ":" $5 ":" $6
            chan=$8
            signal=$9
            # When hotspot is active on single card:
            if (hs == 1) {
                # Never pick DFS channels (52-64, 100-144) to avoid crashing AP
                if ((chan >= 52 && chan <= 64) || (chan >= 100 && chan <= 144))
                    next
            }
            if (signal >= min) {
                # Upgrade 2: 5 GHz and 00: twin bonus (+30 score points)
                # Decisively prioritizes 100-170 Mbps 5GHz bands over crowded 2.4GHz bands
                score = signal
                if (chan > 14 || tolower(bssid) ~ /^58:61:63:00/) {
                    score += 30
                }
                print score, signal, bssid
            }
        }')

    # Process candidates through Queue with Failure Demotion (No 25s timeout blackout)
    local scored_list=()
    while read -r score signal bssid; do
        [ -z "$bssid" ] && continue
        if is_permanent_dead "$bssid"; then
            continue
        fi
        local penalty="${FAIL_PENALTY[${bssid,,}]:-0}"
        local adj_score=$((score - (penalty * 20)))
        scored_list+=("${adj_score}|${signal}|${bssid}")
    done <<< "$raw_candidates"

    [ "${#scored_list[@]}" -eq 0 ] && return 0

    local sorted_queue
    sorted_queue=$(printf '%s\n' "${scored_list[@]}" | sort -t'|' -k1,1rn)

    local count=0
    while IFS='|' read -r adj_score signal bssid; do
        [ -z "$bssid" ] && continue
        echo "$signal $bssid"
        ((count++))
        [ "$count" -ge "$MAX_CANDIDATES" ] && break
    done <<< "$sorted_queue"
}

switch_to_bssid() {
    local target="$1"
    local current

    current=$(get_current_bssid)

    if [ "${current,,}" = "${target,,}" ]; then
        return 1
    fi

    echo
    echo -e "${YELLOW}>>> [INSTANT SWITCH] Switching to KLU AP: $target (Previous: ${current:-None})${RESET}"

    # Upgrade E: DNS Pre-warm before switch (non-blocking in background)
    dns_prewarm

    # Re-associate directly with the target BSSID under KLU_WIFI
    nmcli connection modify "$CONNECTION" 802-11-wireless.bssid "$target"

    if ! nmcli -w 4 connection up "$CONNECTION" >/dev/null 2>&1; then
        echo -e "${RED}Connection failed to $target.${RESET}"
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid ""
        add_to_blacklist "$target"
        return 1
    fi

    local new_bssid
    new_bssid=$(get_current_bssid)
    echo "Connected BSSID: ${new_bssid:-$target}"

    # Millisecond verification: check internet_ok immediately up to 3 times (0.2s pause)
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        if internet_ok; then
            local sig
            sig=$(get_signal)
            echo -e "${GREEN}>>> SUCCESS: Internet online on ${new_bssid:-$target} (${sig:-N/A} dBm)${RESET}"
            record_switch "$current" "${new_bssid:-$target}" "Instant Recovery" "${sig:-N/A}"
            PREV_BSSID="${new_bssid:-$target}"
            SPEED_WINDOW=()
            adapt_hotspot_to_wifi "${new_bssid:-$target}"
            reset_queue_penalties
            return 0
        fi
        sleep 0.2
        ((attempt++))
    done

    # Fast 25ms portal check: if router dropped LAN/gateway path, fast-bailout
    if ! portal_reachable; then
        echo -e "${RED}>>> FAILED: Portal unreachable on $target. Fast-bailing out...${RESET}"
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid ""
        add_to_blacklist "$target"
        return 1
    fi

    # Final check
    if internet_ok; then
        local sig
        sig=$(get_signal)
        echo -e "${GREEN}>>> SUCCESS: Internet online on ${new_bssid:-$target} (${sig:-N/A} dBm)${RESET}"
        record_switch "$current" "${new_bssid:-$target}" "Instant Recovery" "${sig:-N/A}"
        PREV_BSSID="${new_bssid:-$target}"
        SPEED_WINDOW=()
        adapt_hotspot_to_wifi "${new_bssid:-$target}"
        reset_queue_penalties
        return 0
    fi

    echo -e "${RED}>>> FAILED: $target has no working Internet.${RESET}"
    add_to_blacklist "$target"
    return 1
}

recover_connection() {
    local initial_bssid
    initial_bssid=$(get_current_bssid)

    echo
    echo -e "${YELLOW}====================================================${RESET}"
    echo -e "${YELLOW}           INSTANT CONNECTION RECOVERY${RESET}"
    echo -e "${YELLOW}====================================================${RESET}"

    # Upgrade C: Hot-Standby Twin AP Shield (Fastest: switch in milliseconds to sister 5GHz/2.4GHz radio)
    if [ -n "$initial_bssid" ]; then
        local twin
        twin=$(get_twin_bssid "$initial_bssid")
        if [ -n "$twin" ] && ! is_permanent_dead "$twin"; then
            echo -e "${YELLOW}>> [TWIN SHIELD] AP dropped on $initial_bssid. Stepping instantly to twin AP ($twin)...${RESET}"
            demote_candidate "$initial_bssid"
            if switch_to_bssid "$twin"; then
                echo -e "${GREEN}>> Successfully protected connection on twin $twin!${RESET}"
                return 0
            fi
        fi
    fi

    # Non-blocking scan refresh in background
    (nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1) &

    local candidates
    candidates=$(find_candidates)

    if [ -z "$candidates" ]; then
        echo -e "${RED}No suitable non-blacklisted KLU_WIFI APs found.${RESET}"
        echo -e "${YELLOW}Bailing out quickly. Allowing auto-roam...${RESET}"
        nmcli connection modify "$CONNECTION" 802-11-wireless.bssid ""
        nmcli connection up "$CONNECTION" >/dev/null 2>&1 &
        return 1
    fi

    # Try top candidates in sequence with millisecond fast-bailout
    while read -r signal bssid; do
        [ -z "$bssid" ] && continue
        echo -e "  • Candidate: $bssid (Signal: $signal%)"
        if switch_to_bssid "$bssid"; then
            echo -e "${GREEN}>>> Using AP: $bssid (Internet Restored in Milliseconds)${RESET}"
            return 0
        fi
    done <<< "$candidates"

    echo
    echo -e "${RED}Top candidates failed. Fast-bailout to auto-roaming...${RESET}"
    nmcli connection modify "$CONNECTION" 802-11-wireless.bssid ""
    nmcli connection up "$CONNECTION" >/dev/null 2>&1 &

    local reset_bssid
    reset_bssid=$(get_current_bssid)
    if [ -n "$reset_bssid" ] && [ "${reset_bssid,,}" != "${initial_bssid,,}" ]; then
        record_switch "$initial_bssid" "$reset_bssid" "Auto-Fallback" "$(get_signal)"
        PREV_BSSID="$reset_bssid"
        adapt_hotspot_to_wifi "$reset_bssid"
    fi

    sleep 1
    return 1
}

# One-Shot CLI Modes (for Quick Settings Extension actions)
if [ "$1" = "--roam-fastest" ] || [ "$1" = "--roam" ]; then
    echo "Scanning for fastest KLU_WIFI AP..."
    recover_connection
    exit $?
fi

if [ "$1" = "--speed-test" ]; then
    echo "Running live throughput test..."
    cur=$(get_current_bssid)
    run_speed_test "$cur"
    exit 0
fi

if [ "$1" = "--unlock" ]; then
    echo "Releasing BSSID lock..."
    unlock_bssid
    echo "BSSID lock removed. NetworkManager can auto-roam freely."
    exit 0
fi

echo $$ > "/tmp/klu_watchdog.pid"
clear
echo "Starting KLU_WIFI watchdog & BSSID monitor..."
echo "Interval: ${CHECK_INTERVAL}s | Fail Limit: ${FAIL_LIMIT} | Max APs Tested: ${MAX_CANDIDATES}"
echo "Logging transitions to: $LOG_FILE"
sleep 1

while true; do
    clear

    # Upgrade J: Collect any completed background speed test result (non-blocking)
    collect_speed_test_result

    if show_status; then
        # Wi-Fi is healthy and online
        if [ "$ETHERNET_FAILOVER_ACTIVE" -eq 1 ]; then
            restore_to_wifi
        else
            ensure_wifi_primary
        fi
        fail_count=0

        # Keep-alive: refresh gateway ARP + firewall session + generate_204 probe
        keep_alive_portal

        # Upgrade J: Trigger background speed test on interval (non-blocking — main loop continues)
        now_main=$(date +%s)
        if [ $((now_main - LAST_SPEED_TEST_TIME)) -ge "$SPEED_TEST_INTERVAL" ] && [ "$SPEED_TEST_RUNNING" -eq 0 ]; then
            run_speed_test_bg "$(get_current_bssid)"
        fi

        # Speed-Aware Upgrade Check (disabled when ENABLE_SPEED_ROAM=0 to preserve stable connection)
        check_speed_upgrade

        # Upgrade I: Signal Trend Guard — proactive roam before signal-induced drop
        check_signal_trend

        # Upgrade A: Targeted Top-Tier Beacon Watcher (Disabled when ENABLE_TOP_TIER_RECLAIM=0 to preserve stable connection)
        if [ "${ENABLE_TOP_TIER_RECLAIM:-0}" -eq 1 ]; then
            check_top_tier_reclaim
        fi
    else
        ((fail_count++))
        echo
        echo -e "${RED}>> [INSTANT FAILOVER] Internet drop detected! Testing captive portal (${PORTAL_IP})...${RESET}"

        # Instant 1-Strike Portal Check (25ms):
        if ! portal_reachable; then
            echo -e "${RED}>> [CRITICAL] Captive portal is DEAD/UNREACHABLE on this AP! Instant network switch!${RESET}"
        else
            echo -e "${YELLOW}>> Captive portal reachable. Attempting fast AP recovery...${RESET}"
        fi

        unlock_bssid
        # Kill any pending background speed test so it doesn't interfere with recovery
        if [ "$SPEED_TEST_RUNNING" -eq 1 ]; then
            kill "$SPEED_TEST_PID" 2>/dev/null
            SPEED_TEST_RUNNING=0
            rm -f "$SPEED_TEST_TMPFILE"
        fi

        eth_info=$(get_active_ethernet)
        if [ -n "$eth_info" ] && [ "$ETHERNET_FAILOVER_ACTIVE" -eq 0 ]; then
            switch_to_ethernet
        fi

        if recover_connection; then
            if [ "$ETHERNET_FAILOVER_ACTIVE" -eq 1 ]; then
                restore_to_wifi
            fi
            fail_count=0
        else
            echo -e "${YELLOW}Recovery attempt finished. Watchdog will re-test in ${CHECK_INTERVAL}s.${RESET}"
            fail_count=1
        fi
    fi

    sleep "$CHECK_INTERVAL"
done