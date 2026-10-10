#!/bin/bash
USER_NAME="$1"
[ -z "$USER_NAME" ] && USER_NAME="goutham"

# Wait up to 5 seconds for ap0 to be created
for i in $(seq 1 10); do
    if ip link show ap0 >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# Set txqueuelen for high throughput
/usr/bin/ip link set dev ap0 txqueuelen 5000 2>/dev/null || true

# Apply client bandwidth limits
/usr/local/bin/manage_hotspot_clients apply_limits "" "$USER_NAME" 2>/dev/null || true

# Hook hostapd client connect events for access control
CTRL=$(ls -d /tmp/create_ap.*/hostapd_ctrl 2>/dev/null | head -1)
if [ -n "$CTRL" ] && [ -d "$CTRL" ]; then
    hostapd_cli -p "$CTRL" -B -a /usr/local/bin/hostapd_action.sh >/dev/null 2>&1 || true
fi

exit 0
