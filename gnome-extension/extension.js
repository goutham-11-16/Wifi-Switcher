import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import St from 'gi://St';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Clutter from 'gi://Clutter';

const CONF_FILE = GLib.get_home_dir() + '/.config/klu-switch.conf';
const LOGS_BIN = '/home/goutham/.local/bin/wifi-live-logs';
const WATCHDOG_SCRIPT = '/home/goutham/Personal Files/WIfi test/KLU WIFI SWIFT/klu_wifi_watchdog.sh';
const HOTSPOT_BIN = '/home/goutham/.local/bin/klu-hotspot';

function runCmd(args, callback = null) {
    try {
        let proc = new Gio.Subprocess({
            argv: args,
            flags: callback ? Gio.SubprocessFlags.STDOUT_PIPE : Gio.SubprocessFlags.NONE
        });
        proc.init(null);
        if (callback) {
            proc.communicate_utf8_async(null, null, (obj, res) => {
                try {
                    let [ok, stdout] = obj.communicate_utf8_finish(res);
                    callback(ok, stdout);
                } catch (e) {
                    callback(false, null);
                }
            });
        }
    } catch (e) {
        if (callback) callback(false, null);
    }
}

function loadNotifConfig() {
    let conf = { master: true, speed: true, roam: true };
    if (GLib.file_test(CONF_FILE, GLib.FileTest.EXISTS)) {
        try {
            let [ok, bytes] = GLib.file_get_contents(CONF_FILE);
            if (ok) {
                let text = new TextDecoder().decode(bytes);
                for (let line of text.split('\n')) {
                    if (line.includes('NOTIFICATIONS_ENABLED=')) conf.master = !line.includes('false');
                    if (line.includes('NOTIFY_SPEED=')) conf.speed = !line.includes('false');
                    if (line.includes('NOTIFY_ROAM=')) conf.roam = !line.includes('false');
                }
            }
        } catch (e) {}
    }
    return conf;
}

function saveNotifConfig(conf) {
    let text = `NOTIFICATIONS_ENABLED="${conf.master}"\n` +
               `NOTIFY_SPEED="${conf.speed}"\n` +
               `NOTIFY_ROAM="${conf.roam}"\n`;
    try {
        GLib.file_set_contents(CONF_FILE, text);
    } catch (e) {}
}

function openLiveTerminal() {
    let cmdList = [
        ['ptyxis', '--new-window', '-T', 'KLU Wi-Fi & Hotspot Live Monitor', '--', LOGS_BIN],
        ['x-terminal-emulator', '-e', LOGS_BIN],
        ['gnome-terminal', '--', LOGS_BIN]
    ];
    for (let args of cmdList) {
        try {
            let proc = new Gio.Subprocess({ argv: args, flags: Gio.SubprocessFlags.NONE });
            proc.init(null);
            return;
        } catch (e) {}
    }
}

// -------------------------------------------------------------
// 1. TOP BAR PANEL BUTTON (Shows live pill in top bar)
// -------------------------------------------------------------
const KLUSwitchTopBarButton = GObject.registerClass(
class KLUSwitchTopBarButton extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, 'KLU Switch');
        this._extension = extension;
        this._timeoutId = 0;
        this._isUpdating = false;

        let box = new St.BoxLayout({ style_class: 'panel-status-indicators-box' });
        this._icon = new St.Icon({
            icon_name: 'network-wireless-symbolic',
            style_class: 'system-status-icon',
        });
        this._label = new St.Label({
            text: 'KLU: OFF',
            y_align: Clutter.ActorAlign.CENTER,
            style: 'font-weight: bold; margin-left: 4px; font-size: 11px;',
        });
        box.add_child(this._icon);
        box.add_child(this._label);
        this.add_child(box);

        this._notifConfig = loadNotifConfig();
        this._buildMenu();
        this._refreshState();
        this._startPolling();
    }

    _buildMenu() {
        let headerItem = new PopupMenu.PopupMenuItem('⚡ KLU SWITCH CONTROL', { reactive: false });
        headerItem.label.set_style('font-weight: bold; color: #3584e4;');
        this.menu.addMenuItem(headerItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Master Watchdog Switch
        this._watchdogSwitch = new PopupMenu.PopupSwitchMenuItem('⚡ KLU Watchdog System', false);
        this._watchdogSwitch.connect('toggled', (item, state) => {
            if (this._isUpdating) return;
            this._toggleWatchdog(state);
        });
        this.menu.addMenuItem(this._watchdogSwitch);

        // Hotspot Switch
        this._hotspotSwitch = new PopupMenu.PopupSwitchMenuItem('🔥 High-Speed Hotspot', false);
        this._hotspotSwitch.connect('toggled', (item, state) => {
            if (this._isUpdating) return;
            this._toggleHotspot(state);
        });
        this.menu.addMenuItem(this._hotspotSwitch);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Live Terminal Button
        let termItem = new PopupMenu.PopupMenuItem('📜 Watch Live Terminal');
        termItem.connect('activate', () => {
            this.menu.close();
            openLiveTerminal();
        });
        this.menu.addMenuItem(termItem);

        // Quick Actions Submenu
        let actionsSubMenu = new PopupMenu.PopupSubMenuMenuItem('🚀 Quick Wi-Fi Actions');
        let roamItem = new PopupMenu.PopupMenuItem('⚡ Roam to Fastest AP Now');
        roamItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--roam-fastest'], () => this._refreshState());
        });
        actionsSubMenu.menu.addMenuItem(roamItem);

        let speedItem = new PopupMenu.PopupMenuItem('📈 Run Speed Benchmark Now');
        speedItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--speed-test'], () => this._refreshState());
        });
        actionsSubMenu.menu.addMenuItem(speedItem);

        let unlockItem = new PopupMenu.PopupMenuItem('🔓 Release Forced BSSID Lock');
        unlockItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--unlock'], () => this._refreshState());
        });
        actionsSubMenu.menu.addMenuItem(unlockItem);

        let reconnItem = new PopupMenu.PopupMenuItem('🔄 Reconnect Wi-Fi Interface');
        reconnItem.connect('activate', () => {
            this.menu.close();
            runCmd(['nmcli', 'device', 'reapply', 'wlp0s20f3'], () => this._refreshState());
        });
        actionsSubMenu.menu.addMenuItem(reconnItem);
        this.menu.addMenuItem(actionsSubMenu);

        // Notification Settings Submenu
        let notifSubMenu = new PopupMenu.PopupSubMenuMenuItem('🔔 Notification Settings');
        
        this._notifMasterSwitch = new PopupMenu.PopupSwitchMenuItem('Master Notifications', this._notifConfig.master);
        this._notifMasterSwitch.connect('toggled', (item, state) => {
            this._notifConfig.master = state;
            saveNotifConfig(this._notifConfig);
        });
        notifSubMenu.menu.addMenuItem(this._notifMasterSwitch);

        this._notifSpeedSwitch = new PopupMenu.PopupSwitchMenuItem('Speed Test Alerts', this._notifConfig.speed);
        this._notifSpeedSwitch.connect('toggled', (item, state) => {
            this._notifConfig.speed = state;
            saveNotifConfig(this._notifConfig);
        });
        notifSubMenu.menu.addMenuItem(this._notifSpeedSwitch);

        this._notifRoamSwitch = new PopupMenu.PopupSwitchMenuItem('AP Roam / Switch Alerts', this._notifConfig.roam);
        this._notifRoamSwitch.connect('toggled', (item, state) => {
            this._notifConfig.roam = state;
            saveNotifConfig(this._notifConfig);
        });
        notifSubMenu.menu.addMenuItem(this._notifRoamSwitch);

        this.menu.addMenuItem(notifSubMenu);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Telemetry Section
        this._apStatusItem = new PopupMenu.PopupMenuItem('📡 AP: Checking...', { reactive: false });
        this._signalStatusItem = new PopupMenu.PopupMenuItem('📶 Signal: Checking...', { reactive: false });
        this._hotspotStatusItem = new PopupMenu.PopupMenuItem('🔥 Hotspot: Checking...', { reactive: false });
        this._internetStatusItem = new PopupMenu.PopupMenuItem('🌐 Internet: Checking...', { reactive: false });

        this.menu.addMenuItem(this._apStatusItem);
        this.menu.addMenuItem(this._signalStatusItem);
        this.menu.addMenuItem(this._hotspotStatusItem);
        this.menu.addMenuItem(this._internetStatusItem);

        this.menu.connect('open-state-changed', (menu, isOpen) => {
            if (isOpen) {
                this._notifConfig = loadNotifConfig();
                this._notifMasterSwitch.setToggleState(this._notifConfig.master);
                this._notifSpeedSwitch.setToggleState(this._notifConfig.speed);
                this._notifRoamSwitch.setToggleState(this._notifConfig.roam);
                this._refreshState();
            }
        });
    }

    _toggleWatchdog(enable) {
        if (enable) {
            runCmd(['systemctl', '--user', 'restart', 'klu-watchdog.service'], () => this._refreshState());
        } else {
            runCmd(['systemctl', '--user', 'stop', 'klu-watchdog.service'], () => {
                runCmd(['pkill', '-f', 'klu_wifi_watchdog.sh'], () => {
                    runCmd(['nmcli', 'connection', 'modify', 'KLU_WIFI', '802-11-wireless.bssid', ''], () => this._refreshState());
                });
            });
        }
    }

    _toggleHotspot(enable) {
        if (enable) {
            runCmd(['pkexec', HOTSPOT_BIN, '--start'], () => {
                GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                    this._refreshState();
                    return GLib.SOURCE_REMOVE;
                });
            });
        } else {
            runCmd(['pkexec', HOTSPOT_BIN, '--stop'], () => {
                GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                    this._refreshState();
                    return GLib.SOURCE_REMOVE;
                });
            });
        }
    }

    _refreshState() {
        let script = `
        wd_active=0
        if systemctl --user is-active --quiet klu-watchdog.service 2>/dev/null || pgrep -f "klu_wifi_watchdog.sh" >/dev/null 2>&1; then
            wd_active=1
        fi

        hs_active=0
        if [ -f "/tmp/klu_hotspot.state" ] && [ -f "/tmp/klu_hotspot.pid" ] && kill -0 "$(cat /tmp/klu_hotspot.pid 2>/dev/null)" 2>/dev/null; then
            hs_active=1
        fi

        link=$(iw dev wlp0s20f3 link 2>/dev/null)
        bssid=$(echo "$link" | awk '/Connected to/{print $3}')
        sig=$(echo "$link" | awk '/signal:/{print $2}')
        ch=$(iw dev wlp0s20f3 info 2>/dev/null | awk '/channel/{print $2}')
        band="2.4GHz"
        [ -n "$ch" ] && [ "$ch" -gt 14 ] && band="5GHz"

        hs_ch=$(iw dev ap0 info 2>/dev/null | awk '/channel/{print $2}')
        hs_clients=$(iw dev ap0 station dump 2>/dev/null | awk '/Station/{c++} END{print c+0}')

        speed=$(tail -n 1 "/home/goutham/Personal Files/WIfi test/KLU WIFI SWIFT/klu_wifi_speeds.log" 2>/dev/null | grep -o 'Speed: [^ ]* Mbps' || echo "")
        gw=$(ip route show dev wlp0s20f3 2>/dev/null | awk '/default/{print $3}' | head -n 1)

        echo "$wd_active|$hs_active|$bssid|$sig|$ch|$band|$hs_ch|$hs_clients|$speed|$gw"
        `;

        runCmd(['bash', '-c', script], (ok, stdout) => {
            if (!ok || !stdout) return;
            let p = stdout.trim().split('|');
            if (p.length < 10) return;

            let wd = (p[0] === '1');
            let hs = (p[1] === '1');
            let bssid = p[2] || 'Disconnected';
            let sig = p[3] || 'N/A';
            let ch = p[4] || '?';
            let band = p[5] || '2.4GHz';
            let hsCh = p[6] || '';
            let hsClients = p[7] || '0';
            let speed = p[8] || '';
            let gw = p[9] || 'N/A';

            this._isUpdating = true;
            this._watchdogSwitch.setToggleState(wd);
            this._hotspotSwitch.setToggleState(hs);
            this._isUpdating = false;

            // Transparency: Badge is visible ONLY when watchdog is ON
            this.visible = wd;

            if (wd) {
                this._label.text = `KLU: ON (${band})`;
                this._label.set_style('font-weight: bold; margin-left: 4px; font-size: 11px; color: inherit;');
                this._icon.icon_name = 'network-wireless-signal-excellent-symbolic';
            } else {
                this._label.text = 'KLU: OFF';
                this._label.set_style('font-weight: bold; margin-left: 4px; font-size: 11px; color: inherit;');
                this._icon.icon_name = 'network-wireless-offline-symbolic';
            }

            this._apStatusItem.label.text = `📡 AP: ${bssid} (Ch ${ch} | ${band})`;
            this._signalStatusItem.label.text = `📶 Signal: ${sig} dBm ${speed ? '| ' + speed : ''}`;
            if (hs) {
                this._hotspotStatusItem.label.text = `🔥 Hotspot: ACTIVE (Ch ${hsCh || ch} | ${hsClients} client${hsClients === '1' ? '' : 's'})`;
            } else {
                this._hotspotStatusItem.label.text = '🔥 Hotspot: INACTIVE';
            }
            this._internetStatusItem.label.text = `🌐 Gateway: ${gw} | Internet: OK`;

            if (this._extension && this._extension._quickIndicator && this._extension._quickIndicator._toggle) {
                this._extension._quickIndicator._toggle.setSubStatus(wd, hs, band);
            }
        });
    }

    _startPolling() {
        if (this._timeoutId > 0) GLib.Source.remove(this._timeoutId);
        this._timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._refreshState();
            return GLib.SOURCE_CONTINUE;
        });
    }

    destroy() {
        if (this._timeoutId > 0) {
            GLib.Source.remove(this._timeoutId);
            this._timeoutId = 0;
        }
        super.destroy();
    }
});

// -------------------------------------------------------------
// 2. QUICK SETTINGS TOGGLE (Shows in QuickSettings cluster)
// -------------------------------------------------------------
const KLUSwitchQuickToggle = GObject.registerClass(
class KLUSwitchQuickToggle extends QuickSettings.QuickMenuToggle {
    _init(extension) {
        super._init({
            title: 'KLU Switch',
            subtitle: 'Watchdog & Hotspot',
            iconName: 'network-wireless-signal-excellent-symbolic',
            toggleMode: true,
        });
        this._extension = extension;

        this.menu.setHeader('network-wireless-signal-excellent-symbolic', 'KLU Switch', 'Watchdog & Hotspot Control');

        // Watchdog Switch
        this._qsWatchdogSwitch = new PopupMenu.PopupSwitchMenuItem('⚡ KLU Watchdog System', false);
        this._qsWatchdogSwitch.connect('toggled', (item, state) => {
            if (this._isUpdating) return;
            if (this._extension && this._extension._topBarIndicator) {
                this._extension._topBarIndicator._toggleWatchdog(state);
            }
        });
        this.menu.addMenuItem(this._qsWatchdogSwitch);

        // Hotspot Switch
        this._qsHotspotSwitch = new PopupMenu.PopupSwitchMenuItem('🔥 High-Speed Hotspot', false);
        this._qsHotspotSwitch.connect('toggled', (item, state) => {
            if (this._isUpdating) return;
            if (this._extension && this._extension._topBarIndicator) {
                this._extension._topBarIndicator._toggleHotspot(state);
            }
        });
        this.menu.addMenuItem(this._qsHotspotSwitch);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Terminal item
        let termItem = new PopupMenu.PopupMenuItem('📜 Watch Live Terminal');
        termItem.connect('activate', () => {
            this.menu.close();
            openLiveTerminal();
        });
        this.menu.addMenuItem(termItem);

        // Roam Now item
        let roamItem = new PopupMenu.PopupMenuItem('⚡ Roam to Fastest AP Now');
        roamItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--roam-fastest']);
        });
        this.menu.addMenuItem(roamItem);

        // Speed Test item
        let speedItem = new PopupMenu.PopupMenuItem('📈 Run Speed Benchmark Now');
        speedItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--speed-test']);
        });
        this.menu.addMenuItem(speedItem);

        // Release Lock item
        let unlockItem = new PopupMenu.PopupMenuItem('🔓 Release Forced BSSID Lock');
        unlockItem.connect('activate', () => {
            this.menu.close();
            runCmd(['bash', WATCHDOG_SCRIPT, '--unlock']);
        });
        this.menu.addMenuItem(unlockItem);

        this.connect('clicked', () => {
            if (this._extension && this._extension._topBarIndicator) {
                this._extension._topBarIndicator._toggleWatchdog(this.checked);
            }
        });
    }

    setSubStatus(wd, hs, band) {
        this._isUpdating = true;
        this.checked = wd;
        this._qsWatchdogSwitch.setToggleState(wd);
        this._qsHotspotSwitch.setToggleState(hs);
        this._isUpdating = false;
        if (wd && hs) {
            this.subtitle = `Watchdog ON (${band}) | Hotspot ACTIVE`;
        } else if (wd) {
            this.subtitle = `Watchdog ON (${band})`;
        } else if (hs) {
            this.subtitle = 'Hotspot ACTIVE | Watchdog OFF';
        } else {
            this.subtitle = 'Watchdog & Hotspot OFF';
        }
    }
});

const KLUSwitchQuickIndicator = GObject.registerClass(
class KLUSwitchQuickIndicator extends QuickSettings.SystemIndicator {
    _init(extension) {
        super._init();
        this._toggle = new KLUSwitchQuickToggle(extension);
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        super.destroy();
    }
});

// -------------------------------------------------------------
// EXTENSION ENTRYPOINT
// -------------------------------------------------------------
export default class KLUSwitchExtension extends Extension {
    enable() {
        // 1. Add to Top Bar Panel safely
        let role = 'klu-wifi-swift';
        if (Main.panel.statusArea[role]) {
            try { Main.panel.statusArea[role].destroy(); } catch(e) {}
        }
        this._topBarIndicator = new KLUSwitchTopBarButton(this);
        Main.panel.addToStatusArea(role, this._topBarIndicator, 1, 'right');

        // 2. Add to Quick Settings Menu
        this._quickIndicator = new KLUSwitchQuickIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._quickIndicator);
    }

    disable() {
        if (this._topBarIndicator) {
            this._topBarIndicator.destroy();
            this._topBarIndicator = null;
        }
        if (this._quickIndicator) {
            this._quickIndicator.destroy();
            this._quickIndicator = null;
        }
    }
}
