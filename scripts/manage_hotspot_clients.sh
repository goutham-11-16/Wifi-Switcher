#!/bin/bash
ACTION="$1"
MAC="$2"
USER_NAME="$3"

IW_BIN=$(command -v iw || echo "/usr/sbin/iw")
IP_BIN=$(command -v ip || echo "/usr/bin/ip")
TC_BIN=$(command -v tc || echo "/usr/sbin/tc")
IPTABLES_BIN=$(command -v iptables || echo "/usr/sbin/iptables")
HOSTAPD_CLI_BIN=$(command -v hostapd_cli || echo "/usr/sbin/hostapd_cli")

DENY_FILE="/home/$USER_NAME/.config/wifi-hotspot.deny"
CTRL_DIR=$(ls -d /tmp/create_ap.*/hostapd_ctrl 2>/dev/null | head -1)
IFACE=$($IP_BIN link show 2>/dev/null | grep -E "ap[0-9]+|_ap" | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')

apply_traffic_limits() {
    local USER="$1"
    local LIMITS_FILE="/home/$USER/.config/wifi-hotspot-limits.conf"
    local AP_IFACE=$($IP_BIN link show 2>/dev/null | grep -E "ap[0-9]+|_ap" | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    [ -z "$AP_IFACE" ] && return 0

    if [ ! -f "$LIMITS_FILE" ] || [ ! -s "$LIMITS_FILE" ]; then
        $TC_BIN qdisc del dev "$AP_IFACE" root 2>/dev/null || true
        return 0
    fi

    local LEASES_FILE=$(ls /tmp/create_ap.*/dnsmasq.leases 2>/dev/null | head -1)
    [ -z "$LEASES_FILE" ] && return 0

    # Initialize root HTB qdisc and unthrottled line-rate default class (10 Gbps maximum headroom)
    $TC_BIN qdisc add dev "$AP_IFACE" root handle 1: htb default 10 r2q 100 2>/dev/null || true
    $TC_BIN class replace dev "$AP_IFACE" parent 1: classid 1:10 htb rate 10000mbit ceil 10000mbit quantum 1500 2>/dev/null || true

    # Clear existing filters on root
    $TC_BIN filter del dev "$AP_IFACE" parent 1: 2>/dev/null || true

    local CLASS_ID=100
    local ACTIVE_COUNT=0
    while IFS='|' read -r mac rate || [ -n "$mac" ]; do
        mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]' | xargs)
        rate=$(echo "$rate" | xargs)
        if [ -n "$mac" ] && [ -n "$rate" ] && [ "$rate" -gt 0 ] 2>/dev/null; then
            ip=$(grep -i "$mac" "$LEASES_FILE" 2>/dev/null | awk '{print $3}' | head -1)
            if [ -n "$ip" ]; then
                CLASS_ID=$((CLASS_ID + 1))
                $TC_BIN class replace dev "$AP_IFACE" parent 1: classid "1:$CLASS_ID" htb rate "${rate}mbit" ceil "${rate}mbit" quantum 1500 2>/dev/null || true
                $TC_BIN filter replace dev "$AP_IFACE" protocol ip parent 1: prio 1 u32 match ip dst "$ip/32" flowid "1:$CLASS_ID" 2>/dev/null || true
                ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
            fi
        fi
    done < "$LIMITS_FILE"

    if [ "$ACTIVE_COUNT" -eq 0 ]; then
        $TC_BIN qdisc del dev "$AP_IFACE" root 2>/dev/null || true
    fi
}

if [ "$ACTION" = "list" ]; then
    if [ -n "$IFACE" ]; then
        MACS=$($IW_BIN dev "$IFACE" station dump 2>/dev/null | grep Station | awk '{print $2}')
        for m in $MACS; do
            if grep -q -i "$m" "$DENY_FILE" 2>/dev/null; then
                continue
            fi
            LEASE_LINE=$(cat /tmp/create_ap.*/dnsmasq.leases 2>/dev/null | grep -i "$m" | head -1)
            IP=$(echo "$LEASE_LINE" | awk '{print $3}')
            HOSTNAME=$(echo "$LEASE_LINE" | awk '{print $4}')
            if [ -z "$HOSTNAME" ] || [ "$HOSTNAME" = "*" ]; then
                HOSTNAME="Unknown Device"
            fi
            [ -z "$IP" ] && IP="Unknown IP"
            RX=$($IW_BIN dev "$IFACE" station get "$m" 2>/dev/null | awk '/rx bytes:/{print $3}')
            TX=$($IW_BIN dev "$IFACE" station get "$m" 2>/dev/null | awk '/tx bytes:/{print $3}')
            BITRATE=$($IW_BIN dev "$IFACE" station get "$m" 2>/dev/null | awk -F':\t' '/tx bitrate:/{print $2}' | awk '{print $1" "$2}')
            [ -z "$RX" ] && RX=0
            [ -z "$TX" ] && TX=0
            [ -z "$BITRATE" ] && BITRATE=""
            echo "$m|$HOSTNAME|$RX|$TX|$BITRATE|$IP"
        done
    fi
elif [ "$ACTION" = "set_limit" ]; then
    RATE="$4"
    LIMITS_FILE="/home/$USER_NAME/.config/wifi-hotspot-limits.conf"
    mkdir -p "/home/$USER_NAME/.config"
    touch "$LIMITS_FILE"
    if [ -f "$LIMITS_FILE" ]; then
        sed -i "/^$MAC|/Id" "$LIMITS_FILE"
    fi
    if [ -n "$RATE" ] && [ "$RATE" -gt 0 ] 2>/dev/null; then
        echo "$MAC|$RATE" >> "$LIMITS_FILE"
    fi
    apply_traffic_limits "$USER_NAME"
elif [ "$ACTION" = "get_limits" ]; then
    LIMITS_FILE="/home/$USER_NAME/.config/wifi-hotspot-limits.conf"
    if [ -f "$LIMITS_FILE" ]; then
        cat "$LIMITS_FILE"
    fi
elif [ "$ACTION" = "apply_limits" ]; then
    apply_traffic_limits "$USER_NAME"
elif [ "$ACTION" = "block" ]; then
    HOSTNAME="$4"
    [ -z "$HOSTNAME" ] && HOSTNAME="Unknown Device"
    mkdir -p "/home/$USER_NAME/.config"
    touch "$DENY_FILE"
    if ! grep -q -i "$MAC" "$DENY_FILE"; then
        echo "$MAC|$HOSTNAME" >> "$DENY_FILE"
    fi
    HOSTAPD_DENY="/home/$USER_NAME/.config/wifi-hotspot-hostapd.deny"
    awk -F'|' '{print $1}' "$DENY_FILE" | grep -E '^[0-9a-fA-F:]+$' > "$HOSTAPD_DENY" 2>/dev/null || true
    if [ -n "$CTRL_DIR" ]; then
        $HOSTAPD_CLI_BIN -p "$CTRL_DIR" deny_acl ADD "$MAC" >/dev/null 2>&1 || true
        $HOSTAPD_CLI_BIN -p "$CTRL_DIR" deauthenticate "$MAC" >/dev/null 2>&1 || true
        $HOSTAPD_CLI_BIN -p "$CTRL_DIR" disassociate "$MAC" >/dev/null 2>&1 || true
    fi
    $IPTABLES_BIN -C FORWARD -m mac --mac-source "$MAC" -j DROP 2>/dev/null || \
        $IPTABLES_BIN -I FORWARD -m mac --mac-source "$MAC" -j DROP 2>/dev/null || true
    $IPTABLES_BIN -C INPUT -m mac --mac-source "$MAC" -j DROP 2>/dev/null || \
        $IPTABLES_BIN -I INPUT -m mac --mac-source "$MAC" -j DROP 2>/dev/null || true

    if [ -n "$IFACE" ]; then
        $IW_BIN dev "$IFACE" station del "$MAC" 2>/dev/null || true
    fi

elif [ "$ACTION" = "unblock" ]; then
    if [ -f "$DENY_FILE" ]; then
        sed -i "/$MAC/Id" "$DENY_FILE"
    fi
    HOSTAPD_DENY="/home/$USER_NAME/.config/wifi-hotspot-hostapd.deny"
    awk -F'|' '{print $1}' "$DENY_FILE" | grep -E '^[0-9a-fA-F:]+$' > "$HOSTAPD_DENY" 2>/dev/null || true
    touch "$HOSTAPD_DENY"
    if [ -n "$CTRL_DIR" ]; then
        $HOSTAPD_CLI_BIN -p "$CTRL_DIR" deny_acl DEL "$MAC" >/dev/null 2>&1 || true
    fi

    while $IPTABLES_BIN -D INPUT -m mac --mac-source "$MAC" -j DROP 2>/dev/null; do :; done
    while $IPTABLES_BIN -D FORWARD -m mac --mac-source "$MAC" -j DROP 2>/dev/null; do :; done
elif [ "$ACTION" = "chan_switch" ]; then
    FREQ="$2"
    COUNT="${3:-5}"
    if [ -n "$CTRL_DIR" ] && [ -n "$FREQ" ]; then
        $HOSTAPD_CLI_BIN -p "$CTRL_DIR" chan_switch "$COUNT" "$FREQ" >/dev/null 2>&1 || true
    fi
elif [ "$ACTION" = "list_blocked" ]; then
    if [ -f "$DENY_FILE" ]; then
        cat "$DENY_FILE"
    fi
fi
