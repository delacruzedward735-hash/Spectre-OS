import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const SETTINGS_SCHEMA = 'org.spectre.desktop';
const UPDATE_SECONDS = 2;

function spawn(command) {
    try {
        GLib.spawn_command_line_async(command);
    } catch (e) {
        console.error(`[Spectre Overview] Unable to launch '${command}': ${e}`);
    }
}

function decode(bytes) {
    try {
        return new TextDecoder().decode(bytes);
    } catch (_) {
        return '';
    }
}

function readText(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? decode(bytes) : '';
    } catch (_) {
        return '';
    }
}

function clampPercent(value) {
    return Math.max(0, Math.min(100, Number.isFinite(value) ? value : 0));
}

function formatRate(bytesPerSecond) {
    const value = Math.max(0, bytesPerSecond);
    if (value >= 1024 * 1024)
        return `${(value / 1024 / 1024).toFixed(1)} MB/s`;
    if (value >= 1024)
        return `${(value / 1024).toFixed(0)} KB/s`;
    return `${value.toFixed(0)} B/s`;
}

function readCpuSample() {
    const line = readText('/proc/stat').split('\n')[0] ?? '';
    const values = line.trim().split(/\s+/).slice(1).map(Number);
    if (values.length < 4 || values.some(v => !Number.isFinite(v)))
        return null;
    const idle = values[3] + (values[4] ?? 0);
    const total = values.reduce((sum, value) => sum + value, 0);
    return {idle, total};
}

function readMemoryPercent() {
    const lines = readText('/proc/meminfo').split('\n');
    let total = 0;
    let available = 0;
    for (const line of lines) {
        if (line.startsWith('MemTotal:'))
            total = Number(line.split(/\s+/)[1]);
        else if (line.startsWith('MemAvailable:'))
            available = Number(line.split(/\s+/)[1]);
    }
    if (!total)
        return 0;
    return clampPercent(((total - available) / total) * 100);
}

function readDiskPercent() {
    try {
        const file = Gio.File.new_for_path('/');
        const info = file.query_filesystem_info('filesystem::size,filesystem::free', null);
        const size = info.get_attribute_uint64('filesystem::size');
        const free = info.get_attribute_uint64('filesystem::free');
        if (!size)
            return 0;
        return clampPercent(((size - free) / size) * 100);
    } catch (_) {
        return 0;
    }
}

function readNetworkBytes() {
    let rx = 0;
    let tx = 0;
    for (const line of readText('/proc/net/dev').split('\n').slice(2)) {
        if (!line.includes(':'))
            continue;
        const [namePart, dataPart] = line.split(':', 2);
        const name = namePart.trim();
        if (!name || name === 'lo')
            continue;
        const fields = dataPart.trim().split(/\s+/).map(Number);
        if (fields.length < 9)
            continue;
        rx += Number.isFinite(fields[0]) ? fields[0] : 0;
        tx += Number.isFinite(fields[8]) ? fields[8] : 0;
    }
    return {rx, tx};
}

function readUptime() {
    const seconds = Number(readText('/proc/uptime').split(/\s+/)[0] ?? '0');
    if (!Number.isFinite(seconds))
        return 'unknown';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return `${hours}h ${mins}m`;
}

function makeSectionHeader(iconName, title, subtitle = '') {
    const row = new St.BoxLayout({
        vertical: false,
        style_class: 'spectre-overview-section-header',
        x_expand: true,
    });
    row.add_child(new St.Icon({
        icon_name: iconName,
        icon_size: 19,
        style_class: 'spectre-overview-section-icon',
        y_align: Clutter.ActorAlign.CENTER,
    }));
    const labels = new St.BoxLayout({vertical: true, x_expand: true});
    labels.add_child(new St.Label({
        text: title,
        style_class: 'spectre-overview-section-title',
        x_align: Clutter.ActorAlign.START,
    }));
    if (subtitle) {
        labels.add_child(new St.Label({
            text: subtitle,
            style_class: 'spectre-overview-subtitle',
            x_align: Clutter.ActorAlign.START,
        }));
    }
    row.add_child(labels);
    return row;
}

function makeBar(extraClass = '') {
    const track = new St.Widget({style_class: 'spectre-overview-bar-track', x_expand: true});
    const fill = new St.Widget({style_class: `spectre-overview-bar-fill ${extraClass}`.trim()});
    track.add_child(fill);
    return {track, fill};
}

function setBar(bar, percent) {
    const width = bar.track.width > 0 ? bar.track.width : 78;
    bar.fill.set_position(0, 0);
    bar.fill.set_size(Math.max(3, Math.floor(width * clampPercent(percent) / 100)), 4);
}

function makeMetric(name, extraClass = '') {
    const box = new St.BoxLayout({
        vertical: true,
        style_class: 'spectre-overview-metric',
        x_expand: true,
    });
    const nameLabel = new St.Label({
        text: name,
        style_class: 'spectre-overview-metric-name',
        x_align: Clutter.ActorAlign.START,
    });
    const valueLabel = new St.Label({
        text: '0%',
        style_class: 'spectre-overview-metric-value',
        x_align: Clutter.ActorAlign.START,
    });
    const bar = makeBar(extraClass);
    box.add_child(nameLabel);
    box.add_child(valueLabel);
    box.add_child(bar.track);
    return {box, valueLabel, bar};
}

function makeActionButton(label, iconName, command, closeMenu) {
    const button = new St.Button({
        style_class: 'spectre-overview-action',
        reactive: true,
        can_focus: true,
        track_hover: true,
        x_expand: true,
    });
    const row = new St.BoxLayout({vertical: false, x_align: Clutter.ActorAlign.CENTER});
    row.add_child(new St.Icon({icon_name: iconName, icon_size: 16}));
    row.add_child(new St.Label({text: label}));
    button.set_child(row);
    button.connect('clicked', () => {
        closeMenu();
        spawn(command);
    });
    return button;
}

export default class SpectreHudExtension extends Extension {
    enable() {
        this._settings = new Gio.Settings({schema_id: SETTINGS_SCHEMA});
        this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._signals = [];
        this._overviewVisible = false;
        this._previousCpu = readCpuSample();
        this._previousNetwork = readNetworkBytes();
        this._previousTime = GLib.get_monotonic_time();

        // The panel popover is the critical monitoring surface. Desktop cards
        // are optional and must never be able to put the whole extension into
        // ERROR state if Shell changes a layout detail.
        this._safeStep('panel indicators', () => this._buildIndicators());
        if (this._toggle)
            this._safeStep('monitor menu', () => this._buildMenu());
        this._safeStep('desktop cards', () => this._buildDesktopHud());
        this._safeStep('settings sync', () => this._syncSettings());
        this._safeStep('session sync', () => this._syncSessionMode());
        this._safeStep('appearance sync', () => this._syncTheme());

        this._safeStep('appearance signal', () => {
            this._signals.push([
                this._interfaceSettings,
                this._interfaceSettings.connect('changed::color-scheme', () =>
                    this._safeStep('appearance refresh', () => this._syncTheme())),
            ]);
        });
        this._safeStep('settings signal', () => {
            this._signals.push([
                this._settings,
                this._settings.connect('changed', () =>
                    this._safeStep('settings refresh', () => this._syncSettings())),
            ]);
        });
        this._safeStep('session-mode signal', () => {
            this._signals.push([
                Main.sessionMode,
                Main.sessionMode.connect('updated', () =>
                    this._safeStep('session refresh', () => this._syncSessionMode())),
            ]);
        });
        this._safeStep('monitor signal', () => {
            this._signals.push([
                Main.layoutManager,
                Main.layoutManager.connect('monitors-changed', () =>
                    this._safeStep('desktop card reposition', () => this._positionDesktopHud())),
            ]);
        });
        this._safeStep('overview showing signal', () => {
            this._signals.push([
                Main.overview,
                Main.overview.connect('showing', () => {
                    this._overviewVisible = true;
                    this._syncDesktopHudVisibility();
                }),
            ]);
        });
        this._safeStep('overview hidden signal', () => {
            this._signals.push([
                Main.overview,
                Main.overview.connect('hidden', () => {
                    this._overviewVisible = false;
                    this._syncDesktopHudVisibility();
                }),
            ]);
        });
        if (this._toggle?.menu) {
            this._safeStep('menu refresh signal', () => {
                this._signals.push([
                    this._toggle.menu,
                    this._toggle.menu.connect('open-state-changed', (_menu, isOpen) => {
                        if (isOpen)
                            this._safeUpdateMetrics();
                    }),
                ]);
            });
        }

        this._timerId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            UPDATE_SECONDS,
            () => {
                this._safeUpdateMetrics();
                return GLib.SOURCE_CONTINUE;
            }
        );
        this._safeUpdateMetrics();
    }

    _safeStep(label, callback) {
        try {
            return callback();
        } catch (e) {
            console.error(`[Spectre Insight] ${label} failed without disabling monitoring: ${e}`);
            return null;
        }
    }

    _isUserDesktop() {
        return Main.sessionMode.currentMode === 'user' && !(Main.sessionMode.isLocked ?? false);
    }

    _buildIndicators() {
        this._toggle = new PanelMenu.Button(0.0, 'Spectre Insight');
        this._toggle.add_style_class_name('spectre-overview-toggle');
        this._toggle.menu.actor.add_style_class_name('spectre-insight-popup');
        this._toggle.add_child(new St.Icon({
            icon_name: 'utilities-system-monitor-symbolic',
            icon_size: 17,
            y_align: Clutter.ActorAlign.CENTER,
        }));

        // Keep one monitoring entry point. The heartbeat opens Spectre Insight;
        // the adjacent gear launches GNOME Settings. Both live directly before
        // GNOME Quick Settings (network / sound / power).
        Main.panel.addToStatusArea(`${this.uuid}-toggle`, this._toggle, 99, 'right');

        this._settingsButton = new PanelMenu.Button(0.0, 'Settings', true);
        this._settingsButton.add_style_class_name('spectre-settings-toggle');
        this._settingsButton.add_child(new St.Icon({
            icon_name: 'preferences-system-symbolic',
            icon_size: 17,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._settingsButton.connect('button-press-event', () => {
            spawn('gnome-control-center');
            return Clutter.EVENT_STOP;
        });
        Main.panel.addToStatusArea(`${this.uuid}-settings`, this._settingsButton, 99, 'right');

        this._moveBesideQuickSettings();
    }

    _moveBesideQuickSettings() {
        try {
            const box = Main.panel._rightBox;
            const quick = Main.panel.statusArea.quickSettings;
            if (!box || !quick)
                return;
            const quickActor = quick.container ?? quick;
            const placeBeforeQuickSettings = actor => {
                if (!actor)
                    return;
                const children = box.get_children();
                const quickIndex = children.indexOf(quickActor);
                if (quickIndex >= 0)
                    box.set_child_at_index(actor, quickIndex);
            };

            placeBeforeQuickSettings(this._toggle.container ?? this._toggle);
            placeBeforeQuickSettings(this._settingsButton.container ?? this._settingsButton);
        } catch (e) {
            console.debug(`[Spectre Insight] Panel placement fallback: ${e}`);
        }
    }

    _buildMenu() {
        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
            style_class: 'spectre-overview-menu-item',
        });
        this._panel = new St.BoxLayout({
            vertical: true,
            style_class: 'spectre-overview-panel',
            x_expand: true,
        });

        const hero = new St.BoxLayout({
            vertical: false,
            style_class: 'spectre-overview-hero',
            x_expand: true,
        });
        hero.add_child(new St.Icon({
            icon_name: 'utilities-system-monitor-symbolic',
            icon_size: 23,
            style_class: 'spectre-overview-hero-icon',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        const heroText = new St.BoxLayout({vertical: true, x_expand: true});
        heroText.add_child(new St.Label({
            text: 'Spectre Insight',
            style_class: 'spectre-overview-title',
            x_align: Clutter.ActorAlign.START,
        }));
        heroText.add_child(new St.Label({
            text: 'Live system status and performance',
            style_class: 'spectre-overview-subtitle',
            x_align: Clutter.ActorAlign.START,
        }));
        hero.add_child(heroText);
        this._panel.add_child(hero);

        this._networkCard = new St.BoxLayout({vertical: true, style_class: 'spectre-overview-card'});
        this._networkCard.add_child(makeSectionHeader(
            'network-workgroup-symbolic',
            'Network Activity',
            GLib.get_host_name() ?? 'spectre'
        ));

        const onlineRow = new St.BoxLayout({vertical: false, x_expand: true});
        this._networkState = new St.Label({
            text: '● ONLINE',
            style_class: 'spectre-overview-online',
            x_align: Clutter.ActorAlign.START,
            x_expand: true,
        });
        this._uptime = new St.Label({
            text: 'Uptime 0m',
            style_class: 'spectre-overview-detail',
            x_align: Clutter.ActorAlign.END,
        });
        onlineRow.add_child(this._networkState);
        onlineRow.add_child(this._uptime);
        this._networkCard.add_child(onlineRow);
        this._networkCard.add_child(new St.Widget({style_class: 'spectre-overview-separator'}));

        const rateRow = new St.BoxLayout({vertical: false, x_expand: true});
        this._download = new St.Label({
            text: '↓ 0 B/s',
            style_class: 'spectre-overview-rate spectre-overview-down',
            x_expand: true,
            x_align: Clutter.ActorAlign.START,
        });
        this._upload = new St.Label({
            text: '↑ 0 B/s',
            style_class: 'spectre-overview-rate spectre-overview-up',
            x_align: Clutter.ActorAlign.END,
        });
        rateRow.add_child(this._download);
        rateRow.add_child(this._upload);
        this._networkCard.add_child(rateRow);

        this._systemCard = new St.BoxLayout({vertical: true, style_class: 'spectre-overview-card'});
        this._systemCard.add_child(makeSectionHeader(
            'utilities-system-monitor-symbolic',
            'System Monitor',
            'Live resource usage'
        ));
        const metrics = new St.BoxLayout({vertical: false, style_class: 'spectre-overview-metric-row'});
        this._cpu = makeMetric('CPU');
        this._ram = makeMetric('RAM', 'ram');
        this._disk = makeMetric('DISK', 'disk');
        metrics.add_child(this._cpu.box);
        metrics.add_child(this._ram.box);
        metrics.add_child(this._disk.box);
        this._systemCard.add_child(metrics);

        this._identityCard = new St.BoxLayout({vertical: true, style_class: 'spectre-overview-card'});
        this._identityCard.add_child(makeSectionHeader(
            'security-high-symbolic',
            'Spectre OS',
            GLib.get_os_info('PRETTY_NAME') ?? 'Spectre OS'
        ));
        this._identityCard.add_child(new St.Label({
            text: 'Secure • Fast • Yours',
            style_class: 'spectre-overview-identity-line',
            x_align: Clutter.ActorAlign.START,
        }));

        this._panel.add_child(this._networkCard);
        this._panel.add_child(this._systemCard);
        this._panel.add_child(this._identityCard);

        const actions = new St.BoxLayout({vertical: false, style_class: 'spectre-overview-actions', x_expand: true});
        const closeMenu = () => this._toggle.menu.close();
        actions.add_child(makeActionButton('Network', 'network-workgroup-symbolic', 'gnome-control-center network', closeMenu));
        actions.add_child(makeActionButton('Monitor', 'utilities-system-monitor-symbolic', 'gnome-system-monitor', closeMenu));
        actions.add_child(makeActionButton('Spectre Center', 'preferences-system-symbolic', 'spectre-center', closeMenu));
        this._panel.add_child(actions);

        item.add_child(this._panel);
        this._toggle.menu.addMenuItem(item);

        this._toggle.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._desktopCardsSwitch = new PopupMenu.PopupSwitchMenuItem(
            'Show desktop cards',
            this._settings.get_boolean('show-hud')
        );
        this._desktopCardsSwitch.connect('toggled', (_item, enabled) => {
            if (!this._syncingSettings && this._settings)
                this._settings.set_boolean('show-hud', enabled);
        });
        this._toggle.menu.addMenuItem(this._desktopCardsSwitch);
    }

    _buildDesktopHud() {
        // Do not attach widgets to GNOME Shell's private _backgroundGroup.
        // Register the actor as normal shell chrome instead, then show it only
        // on an empty user workspace. Windows never need to compete with it.
        this._desktopHud = new St.BoxLayout({
            vertical: true,
            reactive: false,
            can_focus: false,
            visible: false,
            style_class: 'spectre-desktop-hud',
        });

        this._desktopNetworkCard = new St.BoxLayout({
            vertical: true,
            style_class: 'spectre-overview-card spectre-desktop-card',
        });
        this._desktopNetworkCard.add_child(makeSectionHeader(
            'network-workgroup-symbolic',
            'Network Activity',
            GLib.get_host_name() ?? 'spectre'
        ));
        const statusRow = new St.BoxLayout({vertical: false, x_expand: true});
        this._desktopNetworkState = new St.Label({
            text: '● ONLINE',
            style_class: 'spectre-overview-online',
            x_align: Clutter.ActorAlign.START,
            x_expand: true,
        });
        this._desktopUptime = new St.Label({
            text: 'Uptime 0m',
            style_class: 'spectre-overview-detail',
            x_align: Clutter.ActorAlign.END,
        });
        statusRow.add_child(this._desktopNetworkState);
        statusRow.add_child(this._desktopUptime);
        this._desktopNetworkCard.add_child(statusRow);
        this._desktopNetworkCard.add_child(new St.Widget({style_class: 'spectre-overview-separator'}));

        const desktopRateRow = new St.BoxLayout({vertical: false, x_expand: true});
        this._desktopDownload = new St.Label({
            text: '↓ 0 B/s',
            style_class: 'spectre-overview-rate spectre-overview-down',
            x_expand: true,
            x_align: Clutter.ActorAlign.START,
        });
        this._desktopUpload = new St.Label({
            text: '↑ 0 B/s',
            style_class: 'spectre-overview-rate spectre-overview-up',
            x_align: Clutter.ActorAlign.END,
        });
        desktopRateRow.add_child(this._desktopDownload);
        desktopRateRow.add_child(this._desktopUpload);
        this._desktopNetworkCard.add_child(desktopRateRow);

        this._desktopSystemCard = new St.BoxLayout({
            vertical: true,
            style_class: 'spectre-overview-card spectre-desktop-card',
        });
        this._desktopSystemCard.add_child(makeSectionHeader(
            'utilities-system-monitor-symbolic',
            'System Monitor',
            'Live resource usage'
        ));
        const desktopMetrics = new St.BoxLayout({
            vertical: false,
            style_class: 'spectre-overview-metric-row',
        });
        this._desktopCpu = makeMetric('CPU');
        this._desktopRam = makeMetric('RAM', 'ram');
        this._desktopDisk = makeMetric('DISK', 'disk');
        desktopMetrics.add_child(this._desktopCpu.box);
        desktopMetrics.add_child(this._desktopRam.box);
        desktopMetrics.add_child(this._desktopDisk.box);
        this._desktopSystemCard.add_child(desktopMetrics);

        this._desktopHud.add_child(this._desktopNetworkCard);
        this._desktopHud.add_child(this._desktopSystemCard);
        Main.layoutManager.addChrome(this._desktopHud, {
            affectsStruts: false,
            trackFullscreen: false,
        });
        this._desktopHudRegistered = true;
        this._positionDesktopHud();
    }

    _positionDesktopHud() {
        if (!this._desktopHud)
            return;
        const monitor = Main.layoutManager.primaryMonitor;
        if (!monitor)
            return;
        const width = Math.min(370, Math.max(300, monitor.width - 64));
        this._desktopHud.set_width(width);
        this._desktopHud.set_position(
            monitor.x + monitor.width - width - 24,
            monitor.y + 66
        );
    }

    _currentWorkspaceHasWindow() {
        try {
            const active = global.workspace_manager.get_active_workspace();
            return global.get_window_actors().some(actor => {
                const window = actor.meta_window;
                if (!window || !actor.visible)
                    return false;
                if (window.skip_taskbar)
                    return false;
                return window.get_workspace() === active;
            });
        } catch (e) {
            console.debug(`[Spectre Insight] Window visibility fallback: ${e}`);
            return true;
        }
    }

    _syncDesktopHudVisibility() {
        if (!this._desktopHud)
            return;
        const requested = this._settings?.get_boolean('show-hud') ?? true;
        const emptyDesktop = !this._currentWorkspaceHasWindow();
        this._desktopHud.visible = requested && this._isUserDesktop() &&
            !this._overviewVisible && emptyDesktop;
    }

    _syncTheme() {
        let light = false;
        try {
            light = this._interfaceSettings?.get_string('color-scheme') !== 'prefer-dark';
        } catch (_e) {
            light = false;
        }
        for (const actor of [
            // The custom right-panel buttons also need an appearance class;
            // previously only the open Insight menu and desktop cards changed.
            this._toggle,
            this._settingsButton,
            this._toggle?.menu?.actor,
            this._panel,
            this._networkCard,
            this._systemCard,
            this._identityCard,
            this._desktopHud,
            this._desktopNetworkCard,
            this._desktopSystemCard,
        ].filter(Boolean)) {
            if (light)
                actor.add_style_class_name('spectre-light');
            else
                actor.remove_style_class_name('spectre-light');
        }
    }

    _syncSettings() {
        if (!this._settings)
            return;
        const compact = this._settings.get_boolean('hud-compact');
        for (const card of [
            this._networkCard,
            this._systemCard,
            this._identityCard,
            this._desktopNetworkCard,
            this._desktopSystemCard,
        ].filter(Boolean)) {
            if (compact)
                card.add_style_class_name('compact');
            else
                card.remove_style_class_name('compact');
        }
        this._networkCard.visible = this._settings.get_boolean('show-network-card');
        this._systemCard.visible = this._settings.get_boolean('show-system-card');
        if (this._desktopNetworkCard)
            this._desktopNetworkCard.visible = this._settings.get_boolean('show-network-card');
        if (this._desktopSystemCard)
            this._desktopSystemCard.visible = this._settings.get_boolean('show-system-card');

        const showDesktopCards = this._settings.get_boolean('show-hud');
        if (this._desktopCardsSwitch && this._desktopCardsSwitch.state !== showDesktopCards) {
            this._syncingSettings = true;
            this._desktopCardsSwitch.setToggleState(showDesktopCards);
            this._syncingSettings = false;
        }

        this._toggle.visible = this._isUserDesktop();
        if (this._settingsButton)
            this._settingsButton.visible = this._isUserDesktop();
        this._syncDesktopHudVisibility();
    }

    _syncSessionMode() {
        if (!this._toggle)
            return;
        const visible = this._isUserDesktop();
        this._toggle.visible = visible;
        if (this._settingsButton)
            this._settingsButton.visible = visible;
        this._syncDesktopHudVisibility();
        if (!visible)
            this._toggle.menu.close();
    }

    _safeUpdateMetrics() {
        try {
            this._positionDesktopHud();
            this._updateMetrics();
            this._syncDesktopHudVisibility();
        } catch (e) {
            console.error(`[Spectre Insight] Metric refresh failed; keeping timer alive: ${e}`);
        }
    }

    _updateMetrics() {
        if (!this._cpu)
            return;

        const nowCpu = readCpuSample();
        let cpuPercent = 0;
        if (nowCpu && this._previousCpu) {
            const idleDelta = nowCpu.idle - this._previousCpu.idle;
            const totalDelta = nowCpu.total - this._previousCpu.total;
            if (totalDelta > 0)
                cpuPercent = clampPercent((1 - idleDelta / totalDelta) * 100);
        }
        this._previousCpu = nowCpu;

        const ramPercent = readMemoryPercent();
        const diskPercent = readDiskPercent();
        const updateMetric = (metric, percent) => {
            if (!metric)
                return;
            metric.valueLabel.text = `${percent.toFixed(0)}%`;
            setBar(metric.bar, percent);
        };
        updateMetric(this._cpu, cpuPercent);
        updateMetric(this._ram, ramPercent);
        updateMetric(this._disk, diskPercent);
        updateMetric(this._desktopCpu, cpuPercent);
        updateMetric(this._desktopRam, ramPercent);
        updateMetric(this._desktopDisk, diskPercent);

        const nowNetwork = readNetworkBytes();
        const nowTime = GLib.get_monotonic_time();
        const elapsed = Math.max((nowTime - this._previousTime) / 1000000, 0.1);
        const rxRate = Math.max(0, nowNetwork.rx - this._previousNetwork.rx) / elapsed;
        const txRate = Math.max(0, nowNetwork.tx - this._previousNetwork.tx) / elapsed;
        this._previousNetwork = nowNetwork;
        this._previousTime = nowTime;
        this._download.text = `↓ ${formatRate(rxRate)}`;
        this._upload.text = `↑ ${formatRate(txRate)}`;
        this._uptime.text = `Uptime ${readUptime()}`;
        if (this._desktopDownload)
            this._desktopDownload.text = `↓ ${formatRate(rxRate)}`;
        if (this._desktopUpload)
            this._desktopUpload.text = `↑ ${formatRate(txRate)}`;
        if (this._desktopUptime)
            this._desktopUptime.text = `Uptime ${readUptime()}`;

        const online = Gio.NetworkMonitor.get_default().get_network_available();
        this._networkState.text = online ? '● ONLINE' : '● OFFLINE';
        this._networkState.style_class = online ? 'spectre-overview-online' : 'spectre-overview-offline';
        if (this._desktopNetworkState) {
            this._desktopNetworkState.text = online ? '● ONLINE' : '● OFFLINE';
            this._desktopNetworkState.style_class = online
                ? 'spectre-overview-online'
                : 'spectre-overview-offline';
        }
    }

    disable() {
        if (this._timerId) {
            GLib.Source.remove(this._timerId);
            this._timerId = 0;
        }
        for (const [object, id] of this._signals ?? []) {
            try {
                object.disconnect(id);
            } catch (_) {
                // Ignore teardown races during GNOME Shell shutdown.
            }
        }
        this._signals = [];
        if (this._desktopHudRegistered && this._desktopHud) {
            try {
                Main.layoutManager.removeChrome(this._desktopHud);
            } catch (_) {
                // Actor teardown is safe even if layout manager already removed it.
            }
            this._desktopHudRegistered = false;
        }
        this._desktopHud?.destroy();
        this._settingsButton?.destroy();
        this._toggle?.destroy();
        this._settings = null;
        this._interfaceSettings = null;
        this._desktopHud = null;
        this._desktopNetworkCard = null;
        this._desktopSystemCard = null;
        this._desktopCardsSwitch = null;
        this._settingsButton = null;
        this._toggle = null;
        this._panel = null;
    }
}
