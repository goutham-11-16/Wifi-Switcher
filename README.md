# KLU WiFi Switcher

A Wi-Fi hotspot manager and auto-roaming watchdog for Ubuntu/Linux (GNOME).

## Components

| Directory | Purpose |
|---|---|
| `scripts/` | System-level scripts (`start_hotspot`, `hotspot_post_start`, `manage_hotspot_clients`) |
| `systemd/` | Systemd service unit for `wifi-hotspot@.service` |
| `gnome-extension/` | GNOME Shell extension (`klu-switch@goutham.github.com`) for quick toggle |
| `polkit/` | Polkit rules for passwordless hotspot management |

### Root Files
- **`klu_wifi_watchdog.sh`** — Core watchdog: auto-roaming, band monitoring, channel switching
- **`klu_hotspot.sh`** — Hotspot lifecycle manager
- **`klu_hotspot.conf`** — Hotspot configuration (SSID, password, interface, etc.)

## Installation

### 1. Copy scripts
```bash
sudo cp scripts/start_hotspot.sh /usr/local/bin/start_hotspot
sudo cp scripts/hotspot_post_start.sh /usr/local/bin/hotspot_post_start.sh
sudo cp scripts/manage_hotspot_clients.sh /usr/local/bin/manage_hotspot_clients
sudo chmod +x /usr/local/bin/start_hotspot /usr/local/bin/hotspot_post_start.sh /usr/local/bin/manage_hotspot_clients
```

### 2. Install systemd service
```bash
sudo cp systemd/wifi-hotspot@.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 3. Install polkit rules
```bash
sudo cp polkit/99-wifi-hotspot.rules /etc/polkit-1/rules.d/
sudo systemctl restart polkit
```

### 4. Install GNOME extension
```bash
mkdir -p ~/.local/share/gnome-shell/extensions/klu-switch@goutham.github.com
cp gnome-extension/* ~/.local/share/gnome-shell/extensions/klu-switch@goutham.github.com/
```

### 5. Start the hotspot
```bash
sudo systemctl start wifi-hotspot@$(whoami).service
sudo systemctl enable wifi-hotspot@$(whoami).service
```

## Dependencies
- `create_ap` (linux-wifi-hotspot)
- `hostapd`
- `iptables` / `tc` (traffic control)
- GNOME Shell 45+

## License
MIT
