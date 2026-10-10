#!/bin/bash

USER_NAME="$1"
if [ -z "$USER_NAME" ]; then
    echo "Error: Username parameter is required."
    exit 1
fi

CONFIG_FILE="/home/$USER_NAME/.config/wifi-hotspot.conf"

# Default fallback values
SSID="hotspot"
USE_PASSWORD="true"
PASSWORD="none"
MAX_CLIENTS="10"
BAND="bg"
DNS_PROFILE="system"
SECURITY_MODE="wpa2"
ISOLATE_CLIENTS="false"
IDLE_TIMEOUT="0"
INHIBIT_SLEEP="false"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Locate core tools dynamically
IW_BIN=$(command -v iw || echo "/usr/sbin/iw")
IP_BIN=$(command -v ip || echo "/usr/bin/ip")
NMCLI_BIN=$(command -v nmcli || echo "/usr/bin/nmcli")
SYSCTL_BIN=$(command -v sysctl || echo "/usr/sbin/sysctl")
IPTABLES_BIN=$(command -v iptables || echo "/usr/sbin/iptables")
SYSTEMCTL_BIN=$(command -v systemctl || echo "/usr/bin/systemctl")
CREATE_AP_BIN=$(command -v create_ap || echo "/usr/bin/create_ap")

supports_ap() {
    local dev="$1"
    local phy
    phy=$($IW_BIN dev "$dev" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    [ -z "$phy" ] && return 1
    $IW_BIN phy "$phy" info 2>/dev/null | grep -A 10 "Supported interface modes" | grep -qw "AP"
}

# 1. Detect all available Wi-Fi interfaces
mapfile -t WIFI_INTERFACES < <($IW_BIN dev 2>/dev/null | awk '$1=="Interface"{print $2}' | grep -v '_ap$' | grep -v '^ap[0-9]')

if [ ${#WIFI_INTERFACES[@]} -eq 0 ]; then
    echo "Error: No Wi-Fi interface found."
    exit 1
fi

# 2. Detect if any Wi-Fi interface is actively connected to an external network
IS_WIFI_CONNECTED=0
ACTIVE_WIFI_IFACE=""
for w in "${WIFI_INTERFACES[@]}"; do
    if $IW_BIN dev "$w" link 2>/dev/null | grep -q "^Connected to" || \
       ($NMCLI_BIN -t -f DEVICE,STATE dev 2>/dev/null | grep -E "^$w:connected" >/dev/null 2>&1); then
        IS_WIFI_CONNECTED=1
        ACTIVE_WIFI_IFACE="$w"
        break
    fi
done

# Detect default internet interface and route
DEFAULT_ROUTE=$($IP_BIN route show default 2>/dev/null | head -n 1)
DEFAULT_IFACE=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')

# Strict Rule: Exactly ONE hotspot can run at any time across the entire system
pkill -9 -x "create_ap" 2>/dev/null || true
pkill -9 -f "^/usr/bin/create_ap " 2>/dev/null || true
pkill -9 -f "hostapd.*ap0" 2>/dev/null || true
if [ "$IS_WIFI_CONNECTED" -eq 0 ]; then
    for w in "${WIFI_INTERFACES[@]}"; do
        $CREATE_AP_BIN --stop "$w" 2>/dev/null || true
        $IW_BIN dev "${w}_ap" del 2>/dev/null || true
    done
fi
$IW_BIN dev ap0 del 2>/dev/null || true
$IW_BIN dev ap1 del 2>/dev/null || true

# 3. Stop conflicting standalone dnsmasq service (if present)
$SYSTEMCTL_BIN stop dnsmasq 2>/dev/null || true

# 4. Universal Firewall Handling across distributions
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    ufw allow in on ap0 2>/dev/null || true
    ufw route allow in on ap0 2>/dev/null || true
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qw "running"; then
    firewall-cmd --zone=trusted --add-interface=ap0 2>/dev/null || true
fi

# 5. Kernel-level network performance and gigabit IP forwarding tuning
$SYSCTL_BIN -w net.ipv4.ip_forward=1 2>/dev/null || true
$SYSCTL_BIN -w net.core.netdev_max_backlog=10000 2>/dev/null || true
$SYSCTL_BIN -w net.core.rmem_max=16777216 2>/dev/null || true
$SYSCTL_BIN -w net.core.wmem_max=16777216 2>/dev/null || true
$SYSCTL_BIN -w net.core.rmem_default=262144 2>/dev/null || true
$SYSCTL_BIN -w net.core.wmem_default=262144 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_wmem="4096 65536 16777216" 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_sack=1 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
$SYSCTL_BIN -w net.ipv4.ip_no_pmtu_disc=0 2>/dev/null || true

# TCP MSS Clamping to eliminate PMTU packet fragmentation and unlock maximum throughput
$IPTABLES_BIN -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    $IPTABLES_BIN -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
$IPTABLES_BIN -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    $IPTABLES_BIN -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# 6. Setup Max Clients and Deny MAC File in environment
if [ "$MAX_CLIENTS" -ne "0" ] 2>/dev/null; then
    export MAX_NUM_STA="$MAX_CLIENTS"
else
    unset MAX_NUM_STA
fi

UI_DENY_FILE="/home/$USER_NAME/.config/wifi-hotspot.deny"
touch "$UI_DENY_FILE"
export DENY_MAC_FILE="/home/$USER_NAME/.config/wifi-hotspot-hostapd.deny"
awk -F'|' '{print $1}' "$UI_DENY_FILE" | grep -E '^[0-9a-fA-F:]+$' > "$DENY_MAC_FILE" 2>/dev/null || true
touch "$DENY_MAC_FILE"

# Apply iptables DROP rules for all previously blocked MACs
while IFS= read -r blocked_mac; do
    if [ -n "$blocked_mac" ]; then
        $IPTABLES_BIN -C FORWARD -m mac --mac-source "$blocked_mac" -j DROP 2>/dev/null || \
            $IPTABLES_BIN -I FORWARD -m mac --mac-source "$blocked_mac" -j DROP 2>/dev/null || true
    fi
done < "$DENY_MAC_FILE"

# 7. Regulatory Domain Management
CURRENT_REG=$($IW_BIN reg get 2>/dev/null | awk '/country/{print $2}' | tr -d ':' | head -n 1)
if [ "$CURRENT_REG" = "00" ] || [ -z "$CURRENT_REG" ]; then
    LOCALE_COUNTRY=$(locale | grep -m1 LC_NAME | cut -d_ -f2 | cut -d. -f1 | cut -d@ -f1)
    [ -z "$LOCALE_COUNTRY" ] && LOCALE_COUNTRY=$(locale | grep -m1 LANG | cut -d_ -f2 | cut -d. -f1 | cut -d@ -f1)
    if [ ${#LOCALE_COUNTRY} -eq 2 ]; then
        $IW_BIN reg set "$LOCALE_COUNTRY" 2>/dev/null || true
    else
        $IW_BIN reg set IN 2>/dev/null || true
    fi
fi

CMD_ARGS=(--ieee80211n)
MODE_LABEL="2.4G"

# Hardware-accelerated High-Throughput capabilities
HT_CAPAB_OPTS='[HT40+][SHORT-GI-20][SHORT-GI-40][RX-STBC1][LDPC]'
VHT_CAPAB_OPTS='[SHORT-GI-80][MAX-A-MPDU-LEN-EXP7][RXLDPC][RX-STBC-1][TX-STBC-2BY1]'

# Check if Wi-Fi hardware supports IEEE 802.11ax (HE) AP mode
HAS_AX=0
if [ ${#WIFI_INTERFACES[@]} -gt 0 ]; then
    PHY_NAME=$($IW_BIN dev "${WIFI_INTERFACES[0]}" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    if [ -n "$PHY_NAME" ] && $IW_BIN phy "$PHY_NAME" info 2>/dev/null | grep -A 5 "HE Iftypes" | grep -qw "AP"; then
        HAS_AX=1
    fi
fi

if [ "$IS_WIFI_CONNECTED" -eq 1 ]; then
    # =========================================================================
    # SCENARIO B: Connected to Wi-Fi (Wi-Fi Repeater / Hotspot while on Wi-Fi)
    # Also seamlessly handles VPN active over Wi-Fi (tun*, wg*, tap*)!
    # CRITICAL: DO NOT DISCONNECT WI-FI!
    # =========================================================================
    INTERNET_IFACE="$DEFAULT_IFACE"
    [ -z "$INTERNET_IFACE" ] && INTERNET_IFACE="$ACTIVE_WIFI_IFACE"
    
    WIFI_IFACE=""
    if [ ${#WIFI_INTERFACES[@]} -ge 2 ]; then
        # Subcase B1: Check if an inactive Wi-Fi adapter physically supports AP mode
        for w in "${WIFI_INTERFACES[@]}"; do
            if [ "$w" != "$ACTIVE_WIFI_IFACE" ] && supports_ap "$w"; then
                WIFI_IFACE="$w"
                break
            fi
        done
    fi

    if [ -n "$WIFI_IFACE" ]; then
        # Dedicated secondary adapter available for AP
        ALLOWED_5G_CHAN=""
        PHY_NAME=$($IW_BIN dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
        if [ -n "$PHY_NAME" ]; then
            ALLOWED_5G_CHAN=$($IW_BIN phy "$PHY_NAME" info 2>/dev/null | grep -E "5[0-9]{3}\.0 MHz" | grep -v "no IR" | grep -v "disabled" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p' | head -n 1 || true)
        fi
        if [ "$BAND" = "a" ] && [ -n "$ALLOWED_5G_CHAN" ]; then
            CMD_ARGS+=(--ieee80211ac -c "$ALLOWED_5G_CHAN" --freq-band 5 --ht_capab "$HT_CAPAB_OPTS" --vht_capab "$VHT_CAPAB_OPTS" --vht-chwidth 80)
            [ "$HAS_AX" -eq 1 ] && CMD_ARGS+=(--ieee80211ax)
            MODE_LABEL="5G"
        else
            CMD_ARGS+=(-c 6 --freq-band 2.4 --ht_capab "$HT_CAPAB_OPTS")
            MODE_LABEL="2.4G"
        fi
    else
        # Subcase B2: Single physical adapter or only active adapter supports AP (STA + AP concurrent mode)
        WIFI_IFACE="$ACTIVE_WIFI_IFACE"
        
        # Read the channel the Wi-Fi card is currently connected to
        CURRENT_CHAN=$($IW_BIN dev "$WIFI_IFACE" info 2>/dev/null | awk '/channel/{print $2}')
        if [ -z "$CURRENT_CHAN" ]; then
            CURRENT_CHAN=$($NMCLI_BIN -t -f active,chan dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2 | head -n 1)
        fi
        [ -z "$CURRENT_CHAN" ] && CURRENT_CHAN=6

        # Check if the active connection is on a DFS channel (52-64, 100-144)
        # Note: 2.4GHz channels (1-14) and 5GHz low/high bands (36-48, 149-165) are NEVER DFS
        IS_DFS=0
        if [ "$CURRENT_CHAN" -ge 52 ] && [ "$CURRENT_CHAN" -le 64 ] 2>/dev/null; then
            IS_DFS=1
        elif [ "$CURRENT_CHAN" -ge 100 ] && [ "$CURRENT_CHAN" -le 144 ] 2>/dev/null; then
            IS_DFS=1
        fi

        ACTIVE_SSID=$($NMCLI_BIN -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2}' | head -n 1)
        [ -z "$ACTIVE_SSID" ] && ACTIVE_SSID=$($IW_BIN dev "$WIFI_IFACE" link 2>/dev/null | awk '/SSID:/{print $2}')

        # If connected on a DFS channel (which cannot host an AP), OR if user requested 2.4G ($BAND == "bg") while connected on 5G:
        # Check if a compatible non-DFS AP exists for the current network
        NEED_SWITCH=0
        [ "$IS_DFS" -eq 1 ] && NEED_SWITCH=1
        if [ "$BAND" = "bg" ] && [ "$CURRENT_CHAN" -ge 36 ] 2>/dev/null; then
            NEED_SWITCH=1
        fi

        if [ "$NEED_SWITCH" -eq 1 ] && [ -n "$ACTIVE_SSID" ]; then
            echo "[!] Active channel $CURRENT_CHAN is incompatible (DFS=$IS_DFS, requested band=$BAND)."
            echo "[+] Searching for compatible BSSID for network '$ACTIVE_SSID'..."
            TARGET_BSSID_INFO=$(python3 -c "
import subprocess, sys
ssid = sys.argv[1]
band_pref = sys.argv[2]
try:
    out = subprocess.check_output(['nmcli', '-t', '-f', 'SSID,BSSID,CHAN,SIGNAL', 'dev', 'wifi', 'list'], text=True)
    best_bssid = ''
    best_sig = -1
    best_chan = 0
    fallback_bssid = ''
    fallback_sig = -1
    fallback_chan = 0
    for line in out.splitlines():
        tokens = line.replace(r'\:', '__COLON__').split(':')
        if len(tokens) >= 4:
            s = tokens[0]
            b = tokens[1].replace('__COLON__', ':')
            c = int(tokens[2]) if tokens[2].isdigit() else 0
            sig = int(tokens[3]) if tokens[3].isdigit() else 0
            if s == ssid and c > 0:
                # Exclude DFS channels: 52-64, 100-144
                if (52 <= c <= 64) or (100 <= c <= 144):
                    continue
                # Any non-DFS is a valid fallback
                if sig > fallback_sig:
                    fallback_sig = sig
                    fallback_bssid = b
                    fallback_chan = c
                # Check preferred band
                if band_pref == 'bg' and c > 14:
                    continue
                if band_pref == 'a' and c <= 14:
                    continue
                if sig > best_sig:
                    best_sig = sig
                    best_bssid = b
                    best_chan = c
    if best_bssid:
        print(f'{best_bssid}|{best_chan}')
    elif fallback_bssid:
        print(f'{fallback_bssid}|{fallback_chan}')
except Exception:
    pass
" "$ACTIVE_SSID" "$BAND" 2>/dev/null)

            if [ -n "$TARGET_BSSID_INFO" ]; then
                TARGET_BSSID=$(echo "$TARGET_BSSID_INFO" | cut -d'|' -f1)
                TARGET_CHAN=$(echo "$TARGET_BSSID_INFO" | cut -d'|' -f2)
                echo "[+] Roaming Wi-Fi connection to compatible BSSID ($TARGET_BSSID on channel $TARGET_CHAN)..."
                ACTIVE_CON=$($NMCLI_BIN -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="$WIFI_IFACE" '$2==dev{print $1; exit}')
                if [ -n "$ACTIVE_CON" ]; then
                    $NMCLI_BIN connection modify "$ACTIVE_CON" 802-11-wireless.bssid "$TARGET_BSSID" 2>/dev/null || true
                    $NMCLI_BIN connection up "$ACTIVE_CON" 2>/dev/null || true
                else
                    $NMCLI_BIN dev wifi connect "$ACTIVE_SSID" bssid "$TARGET_BSSID" 2>/dev/null || \
                        $NMCLI_BIN dev wifi connect "$TARGET_BSSID" 2>/dev/null || true
                fi
                sleep 2
                NEW_CHAN=$($IW_BIN dev "$WIFI_IFACE" info 2>/dev/null | awk '/channel/{print $2}')
                [ -n "$NEW_CHAN" ] && CURRENT_CHAN="$NEW_CHAN"
                echo "[+] Wi-Fi associated with channel $CURRENT_CHAN."
            else
                echo "[-] No alternative compatible BSSID found for '$ACTIVE_SSID'."
            fi
        fi

        # Re-check DFS status after potential switch
        IS_DFS=0
        if [ "$CURRENT_CHAN" -ge 52 ] && [ "$CURRENT_CHAN" -le 64 ] 2>/dev/null; then
            IS_DFS=1
        elif [ "$CURRENT_CHAN" -ge 100 ] && [ "$CURRENT_CHAN" -le 144 ] 2>/dev/null; then
            IS_DFS=1
        fi

        if [ "$IS_DFS" -eq 1 ]; then
            echo "[-] Error: Interface remains on DFS channel $CURRENT_CHAN. AP mode is unsupported on DFS frequencies."
            if [ -n "$USER_NAME" ]; then
                USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
                if [ -n "$USER_ID" ]; then
                    sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" notify-send -u critical -i network-wireless-hotspot-symbolic "Wi-Fi Hotspot Error" "Cannot start hotspot on DFS channel ($CURRENT_CHAN). Please connect to a 2.4GHz or non-DFS 5GHz Wi-Fi network." 2>/dev/null || true
                fi
            fi
            exit 1
        fi

        # Match channel and band to current Wi-Fi connection
        if [ "$CURRENT_CHAN" -ge 36 ] 2>/dev/null; then
            CMD_ARGS+=(--ieee80211ac -c "$CURRENT_CHAN" --freq-band 5 --ht_capab "$HT_CAPAB_OPTS" --vht_capab "$VHT_CAPAB_OPTS" --vht-chwidth 80)
            [ "$HAS_AX" -eq 1 ] && CMD_ARGS+=(--ieee80211ax)
            MODE_LABEL="Repeater 5G"
        else
            CMD_ARGS+=(-c "$CURRENT_CHAN" --freq-band 2.4 --ht_capab '[SHORT-GI-20][RX-STBC1][LDPC]')
            MODE_LABEL="Repeater 2.4G"
        fi
    fi

elif [ -n "$DEFAULT_IFACE" ]; then
    # =========================================================================
    # SCENARIO A: Ethernet / USB Tethering / Cellular / Standalone VPN (LAN active)
    # =========================================================================
    WIFI_IFACE="${WIFI_INTERFACES[0]}"
    INTERNET_IFACE="$DEFAULT_IFACE"
    
    # Wi-Fi radio is not connected to external network, ensure interface is clean
    $NMCLI_BIN dev disconnect "$WIFI_IFACE" 2>/dev/null || true
    sleep 0.5
    
    if [ "$BAND" = "a" ]; then
        # Check if 5GHz transmission is permitted (free of "no IR")
        ALLOWED_5G_CHAN=""
        if [ -n "$PHY_NAME" ]; then
            ALLOWED_5G_CHAN=$($IW_BIN phy "$PHY_NAME" info 2>/dev/null | grep -E "5[0-9]{3}\.0 MHz" | grep -v "no IR" | grep -v "disabled" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p' | head -n 1 || true)
        fi
        if [ -n "$ALLOWED_5G_CHAN" ]; then
            CMD_ARGS+=(--ieee80211ac -c "$ALLOWED_5G_CHAN" --freq-band 5 --ht_capab "$HT_CAPAB_OPTS" --vht_capab "$VHT_CAPAB_OPTS" --vht-chwidth 80)
            [ "$HAS_AX" -eq 1 ] && CMD_ARGS+=(--ieee80211ax)
            MODE_LABEL="5G"
        else
            echo "[!] Notice: 5GHz Initiate-Radiation (IR) is restricted on this wireless adapter without active Wi-Fi association."
            echo "[!] Gracefully starting hotspot on high-speed 2.4GHz (Channel 6)..."
            CMD_ARGS+=(-c 6 --freq-band 2.4 --ht_capab "$HT_CAPAB_OPTS")
            MODE_LABEL="2.4G (5G NO-IR fallback)"
        fi
    else
        CMD_ARGS+=(-c 6 --freq-band 2.4 --ht_capab "$HT_CAPAB_OPTS")
        MODE_LABEL="2.4G"
    fi

else
    # =========================================================================
    # SCENARIO C: Offline mode (No internet route / Local Network)
    # =========================================================================
    WIFI_IFACE="${WIFI_INTERFACES[0]}"
    INTERNET_IFACE="$WIFI_IFACE"
    
    if [ "$BAND" = "a" ]; then
        ALLOWED_5G_CHAN=""
        if [ -n "$PHY_NAME" ]; then
            ALLOWED_5G_CHAN=$($IW_BIN phy "$PHY_NAME" info 2>/dev/null | grep -E "5[0-9]{3}\.0 MHz" | grep -v "no IR" | grep -v "disabled" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p' | head -n 1 || true)
        fi
        if [ -n "$ALLOWED_5G_CHAN" ]; then
            CMD_ARGS+=(--ieee80211ac -c "$ALLOWED_5G_CHAN" --freq-band 5 --ht_capab "$HT_CAPAB_OPTS" --vht_capab "$VHT_CAPAB_OPTS" --vht-chwidth 80)
            [ "$HAS_AX" -eq 1 ] && CMD_ARGS+=(--ieee80211ax)
            MODE_LABEL="5G"
        else
            echo "[!] Notice: 5GHz Initiate-Radiation (IR) is restricted on this wireless adapter."
            echo "[!] Gracefully starting hotspot on high-speed 2.4GHz (Channel 6)..."
            CMD_ARGS+=(-c 6 --freq-band 2.4 --ht_capab "$HT_CAPAB_OPTS")
            MODE_LABEL="2.4G (5G NO-IR fallback)"
        fi
    else
        CMD_ARGS+=(-c 6 --freq-band 2.4 --ht_capab "$HT_CAPAB_OPTS")
        MODE_LABEL="2.4G"
    fi
fi

# Store active mode label for GNOME Shell UI
echo "$MODE_LABEL" > /tmp/wifi-hotspot-active-mode 2>/dev/null || true

# Configure upstream DNS servers based on profile
DNS_SERVERS=""
case "$DNS_PROFILE" in
    adguard)
        DNS_SERVERS="94.140.14.14,94.140.15.15"
        ;;
    quad9)
        DNS_SERVERS="9.9.9.9,149.112.112.112"
        ;;
    google)
        DNS_SERVERS="8.8.8.8,8.8.4.4"
        ;;
    cloudflare)
        DNS_SERVERS="1.1.1.1,8.8.8.8"
        ;;
    system|disabled|none|*)
        DNS_SERVERS=""
        ;;
esac

if [ -n "$DNS_SERVERS" ]; then
    CMD_ARGS+=(--dhcp-dns "$DNS_SERVERS")
fi

# Security Mode Handling
if [ "$USE_PASSWORD" = "true" ]; then
    if [ "$SECURITY_MODE" = "wpa3" ] || [ "$SECURITY_MODE" = "wpa3-only" ]; then
        CMD_ARGS+=(-w 3-only)
    elif [ "$SECURITY_MODE" = "wpa3-mixed" ]; then
        CMD_ARGS+=(-w 3)
    else
        CMD_ARGS+=(-w 2)
    fi
fi

# Optional Client Isolation
if [ "$ISOLATE_CLIENTS" = "true" ]; then
    CMD_ARGS+=(--isolate-clients)
fi

CMD_ARGS+=("$WIFI_IFACE" "$INTERNET_IFACE" "$SSID")

if [ "$USE_PASSWORD" = "true" ] && [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
    CMD_ARGS+=("$PASSWORD")
fi

# Clean up any leftover virtual interface before launch
$IW_BIN dev ap0 del 2>/dev/null || true

# Execute create_ap with resilient auto-fallback
$CREATE_AP_BIN "${CMD_ARGS[@]}"
EXIT_CODE=$?

# If create_ap exited with error and 5GHz was attempted, automatically recover on 2.4GHz!
WAS_5G=0
if [[ " ${CMD_ARGS[*]} " == *" --freq-band 5 "* ]]; then
    WAS_5G=1
fi

if [ $EXIT_CODE -ne 0 ] && [ "$WAS_5G" -eq 1 ]; then
    echo "[!] 5GHz startup returned exit code $EXIT_CODE. Automatically recovering on 2.4GHz..."
    echo "2.4G (Auto-Fallback)" > /tmp/wifi-hotspot-active-mode 2>/dev/null || true
    $IW_BIN dev ap0 del 2>/dev/null || true
    sleep 1

    FALLBACK_CHAN=6
    if [ "$IS_WIFI_CONNECTED" -eq 1 ] && [ -n "$ACTIVE_SSID" ]; then
        TARGET_2G_BSSID=$(python3 -c "
import subprocess, sys
ssid = sys.argv[1]
try:
    out = subprocess.check_output(['nmcli', '-t', '-f', 'SSID,BSSID,CHAN,SIGNAL', 'dev', 'wifi', 'list'], text=True)
    best_bssid, best_sig, best_c = '', -1, 6
    for line in out.splitlines():
        tokens = line.replace(r'\:', '__COLON__').split(':')
        if len(tokens) >= 4 and tokens[0] == ssid:
            c, sig = int(tokens[2]) if tokens[2].isdigit() else 0, int(tokens[3]) if tokens[3].isdigit() else 0
            if 1 <= c <= 14 and sig > best_sig:
                best_sig, best_bssid, best_c = sig, tokens[1].replace('__COLON__', ':'), c
    if best_bssid:
        print(f'{best_bssid}|{best_c}')
except Exception:
    pass
" "$ACTIVE_SSID" 2>/dev/null)
        if [ -n "$TARGET_2G_BSSID" ]; then
            BSSID_2G=$(echo "$TARGET_2G_BSSID" | cut -d'|' -f1)
            FALLBACK_CHAN=$(echo "$TARGET_2G_BSSID" | cut -d'|' -f2)
            $NMCLI_BIN dev wifi connect "$BSSID_2G" 2>/dev/null || true
            sleep 2
        fi
    fi

    FALLBACK_ARGS=(--ieee80211n -c "$FALLBACK_CHAN" --freq-band 2.4 --ht_capab '[SHORT-GI-20][RX-STBC1][LDPC]')
    [ -n "$DNS_SERVERS" ] && FALLBACK_ARGS+=(--dhcp-dns "$DNS_SERVERS")
    if [ "$USE_PASSWORD" = "true" ]; then
        if [ "$SECURITY_MODE" = "wpa3" ] || [ "$SECURITY_MODE" = "wpa3-only" ]; then
            FALLBACK_ARGS+=(-w 3-only)
        elif [ "$SECURITY_MODE" = "wpa3-mixed" ]; then
            FALLBACK_ARGS+=(-w 3)
        else
            FALLBACK_ARGS+=(-w 2)
        fi
    fi
    [ "$ISOLATE_CLIENTS" = "true" ] && FALLBACK_ARGS+=(--isolate-clients)
    FALLBACK_ARGS+=("$WIFI_IFACE" "$INTERNET_IFACE" "$SSID")
    if [ "$USE_PASSWORD" = "true" ] && [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        FALLBACK_ARGS+=("$PASSWORD")
    fi
    exec $CREATE_AP_BIN "${FALLBACK_ARGS[@]}"
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo "[-] Error: create_ap failed with exit code $EXIT_CODE" >&2
    if [ -n "$USER_NAME" ]; then
        USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
        if [ -n "$USER_ID" ]; then
            sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" notify-send -u critical -i network-wireless-hotspot-symbolic "Wi-Fi Hotspot Error" "Hotspot failed to start. Check systemctl status wifi-hotspot@$USER_NAME.service" 2>/dev/null || true
        fi
    fi
fi

exit $EXIT_CODE
