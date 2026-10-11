import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';
import Shell from 'gi://Shell';

import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as AppDisplay from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const SETTINGS_SCHEMA = 'org.spectre.desktop';

function spawn(command) {
    try {
        GLib.spawn_command_line_async(command);
    } catch (e) {
        console.error(`[Spectre Panel] Unable to launch '${command}': ${e}`);
    }
}

function addLauncher(menu, label, command, iconName = null) {
    const item = iconName
        ? new PopupMenu.PopupImageMenuItem(label, iconName)
        : new PopupMenu.PopupMenuItem(label);
    item.connect('activate', () => spawn(command));
    menu.addMenuItem(item);
    return item;
}

function makeQuickButton(label, iconName, command, closeMenu) {
    const button = new St.Button({
        style_class: 'spectre-quick-button',
        reactive: true,
        can_focus: true,
        track_hover: true,
        x_expand: true,
    });

    const box = new St.BoxLayout({
        vertical: true,
        style_class: 'spectre-quick-button-box',
        x_align: Clutter.ActorAlign.CENTER,
    });

    box.add_child(new St.Icon({
        icon_name: iconName,
        icon_size: 22,
        style_class: 'spectre-quick-icon',
        x_align: Clutter.ActorAlign.CENTER,
    }));

    box.add_child(new St.Label({
        text: label,
        style_class: 'spectre-quick-label',
        x_align: Clutter.ActorAlign.CENTER,
    }));

    button.set_child(box);
    button.connect('clicked', () => {
        closeMenu();
        spawn(command);
    });

    return button;
}

export default class SpectrePanelExtension extends Extension {
    enable() {
        this._indicators = [];
        this._workspaceButtons = [];
        this._appSystem = Shell.AppSystem.get_default();
        this._spectreSettings = new Gio.Settings({schema_id: SETTINGS_SCHEMA});
        this._shellSettings = new Gio.Settings({schema_id: 'org.gnome.shell'});
        this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});

        // Keep optional Shell integrations isolated. One private/upstream API
        // change must not put the whole Spectre panel into ERROR state.
        this._safeStep('native Activities visibility', () => this._hideNativeActivities());
        this._safeStep('Spectre Hub', () => this._buildSpectreHub());
        this._safeStep('Terminal menu', () => this._buildTerminalMenu());
        this._safeStep('workspace switcher', () => this._buildWorkspaceSwitcher());
        this._safeStep('Apps menu search', () => this._attachAppsSearch());
        this._safeStep('app-grid desktop actions', () => this._installAppGridDesktopActions());
        this._safeStep('Cinnamon-style directional tiling', () => this._installDirectionalTiling());

        this._safeStep('application index', () => this._cacheInstalledApps());
        this._safeStep('application grid initialization', () => this._initializeAppGridLayout());

        this._gridInitializedId = this._spectreSettings.connect(
            'changed::app-grid-initialized', () => {
                if (!this._spectreSettings.get_boolean('app-grid-initialized')) {
                    this._cacheInstalledApps();
                    this._initializeAppGridLayout();
                }
            }
        );

        this._safeStep('session-mode tracking', () => {
            this._sessionModeId = Main.sessionMode.connect(
                'updated', () => this._safeStep('session-mode refresh', () => this._syncSessionMode())
            );
        });
        this._safeStep('initial session-mode refresh', () => this._syncSessionMode());
        this._safeStep('appearance tracking', () => {
            this._appearanceId = this._interfaceSettings.connect('changed::color-scheme', () => this._syncAppearance());
            this._syncAppearance();
        });
    }

    _safeStep(label, callback) {
        try {
            return callback();
        } catch (e) {
            console.error(`[Spectre Panel] ${label} failed without disabling the panel: ${e}`);
            return null;
        }
    }

    _syncAppearance() {
        const light = this._interfaceSettings?.get_string('color-scheme') !== 'prefer-dark';
        this._spectreHubTitle?.set_style(
            light ? 'color: #172235;' : 'color: #f5f9ff;'
        );
        if (light)
            Main.panel.add_style_class_name('spectre-light-mode');
        else
            Main.panel.remove_style_class_name('spectre-light-mode');
    }

    _isUserDesktop() {
        return Main.sessionMode.currentMode === 'user' && !(Main.sessionMode.isLocked ?? false);
    }

    _desktopTargetForApp(appId) {
        if (!appId || !appId.endsWith('.desktop'))
            return null;
        const desktopDir = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
            ?? GLib.build_filenamev([GLib.get_home_dir(), 'Desktop']);
        return GLib.build_filenamev([desktopDir, appId]);
    }

    _spawnDesktopAction(appId) {
        try {
            GLib.spawn_async(
                null,
                ['/usr/local/bin/spectre-desktop-apps', '--toggle-desktop', appId],
                null,
                GLib.SpawnFlags.SEARCH_PATH,
                null
            );
        } catch (e) {
            console.error(`[Spectre Panel] Unable to toggle desktop pin for ${appId}: ${e}`);
            spawn('/usr/local/bin/spectre-desktop-apps');
        }
    }

    _appendDesktopActionForIcon(icon) {
        const app = icon?.app;
        const appId = app?.get_id?.();
        const menu = icon?._menu;
        const target = this._desktopTargetForApp(appId);
        if (!menu || !target)
            return false;

        // AppIconMenu is intentionally private in GNOME Shell 48, so Spectre
        // hooks the exported AppIcon popup path instead. GNOME rebuilds this
        // menu on each open; if the immediate and idle paths both run, keep
        // exactly one Spectre action in the current menu instance.
        const pinned = GLib.file_test(target, GLib.FileTest.EXISTS);
        const label = pinned ? 'Unpin from Desktop' : 'Pin to Desktop';
        const oldItem = menu._spectreDesktopActionItem;
        if (oldItem?.get_parent?.()) {
            // GNOME Shell keeps an AppIcon menu instance alive between opens.
            // Re-evaluate the file-backed pin state every time instead of
            // leaving the label from the first time the menu was created.
            oldItem.label?.set_text(label);
            return true;
        }

        const item = new PopupMenu.PopupMenuItem(label);
        item._spectreDesktopAction = true;
        item.connect('activate', () => {
            this._spawnDesktopAction(appId);

            // The helper toggles a real file in ~/Desktop. Refresh the visible
            // action shortly after activation so the same persistent menu
            // immediately reflects Pin <-> Unpin without needing a Shell
            // restart or a different application to be opened first.
            const refreshLabel = () => {
                try {
                    const nowPinned = GLib.file_test(target, GLib.FileTest.EXISTS);
                    item.label?.set_text(nowPinned ? 'Unpin from Desktop' : 'Pin to Desktop');
                } catch (e) {
                    // The menu may already have been destroyed after activation.
                    // The next popup always re-reads the file state anyway.
                    console.debug(`[Spectre Panel] Desktop pin label refresh deferred: ${e}`);
                }
                return GLib.SOURCE_REMOVE;
            };
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, refreshLabel);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 650, refreshLabel);
        });

        // Keep App Details last, matching GNOME's normal app-menu hierarchy.
        const items = menu._getMenuItems?.() ?? [];
        const position = items.length > 0 ? items.length - 1 : 0;
        menu.addMenuItem(item, position);
        menu._spectreDesktopActionItem = item;
        return true;
    }

    _installAppGridDesktopActions() {
        const proto = AppDisplay.AppIcon?.prototype;
        if (!proto || typeof proto.popupMenu !== 'function')
            throw new Error('GNOME AppIcon.popupMenu is unavailable');

        this._appMenuInjection = new InjectionManager();
        const extension = this;
        this._appMenuInjection.overrideMethod(proto, 'popupMenu', original => function (...args) {
            const result = original.apply(this, args);

            // The menu is created/rebuilt synchronously by popupMenu() in GNOME
            // Shell 48. Insert immediately, then repeat once at idle as a safe
            // compatibility fallback for menu rebuilds performed later in the
            // same main-loop turn. _appendDesktopActionForIcon de-duplicates it.
            try {
                extension._appendDesktopActionForIcon(this);
            } catch (e) {
                console.error(`[Spectre Panel] App desktop action failed safely: ${e}`);
            }

            const icon = this;
            GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                try {
                    extension._appendDesktopActionForIcon(icon);
                } catch (e) {
                    console.error(`[Spectre Panel] Deferred app desktop action failed safely: ${e}`);
                }
                return GLib.SOURCE_REMOVE;
            });

            return result;
        });
        console.log('[Spectre Panel] Desktop pin action hooked through AppIcon.popupMenu');
    }

    _removeAppGridDesktopActions() {
        this._appMenuInjection?.clear();
        this._appMenuInjection = null;
    }


    _hideNativeActivities() {
        // GNOME 45+ renders Activities as a workspace pill. Spectre already
        // provides its logo/hub on the left and numbered workspaces on the
        // right, so leaving the native pill creates a confusing duplicate.
        const item = Main.panel.statusArea.activities;
        const actor = item?.container ?? item;
        if (!actor)
            return;

        if (!this._nativeActivitiesActor) {
            this._nativeActivitiesActor = actor;
            this._nativeActivitiesWasVisible = actor.visible;
        }
        actor.hide();
    }

    _syncSessionMode() {
        const desktopActive = this._isUserDesktop();

        this._hideNativeActivities();

        for (const indicator of this._indicators ?? []) {
            indicator.visible = desktopActive;
            if (!desktopActive && indicator.menu)
                indicator.menu.close();
        }

        // Applications and Places are provided by GNOME extensions. Hide them
        // immediately while the session changes toward a lock/unlock dialog so
        // the authentication screen never exposes desktop launchers.
        for (const role of ['apps-menu', 'places-menu']) {
            const item = Main.panel.statusArea[role];
            if (item)
                item.visible = desktopActive;
        }
    }

    _buildSpectreHub() {
        this._logo = new PanelMenu.Button(0.0, 'Spectre Hub');
        this._logo.add_style_class_name('spectre-logo-button');

        const panelIcon = new St.Icon({
            gicon: Gio.icon_new_for_string('/usr/share/pixmaps/spectre-logo.png'),
            icon_size: 23,
            style_class: 'spectre-logo-icon',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._logo.add_child(panelIcon);

        const headerItem = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
            style_class: 'spectre-hub-header-item',
        });

        const header = new St.BoxLayout({
            vertical: false,
            style_class: 'spectre-hub-header',
            x_expand: true,
        });
        header.add_child(new St.Icon({
            gicon: Gio.icon_new_for_string('/usr/share/pixmaps/spectre-logo.png'),
            icon_size: 42,
            style_class: 'spectre-hub-logo',
            y_align: Clutter.ActorAlign.CENTER,
        }));

        const titles = new St.BoxLayout({
            vertical: true,
            style_class: 'spectre-hub-title-box',
            y_align: Clutter.ActorAlign.CENTER,
        });
        // SPECTRE_FINAL_TITLE_V1
        this._spectreHubTitle = new St.Label({
            text: 'SPECTRE OS',
            style_class: 'spectre-hub-title',
        });
        const titleScheme = new Gio.Settings({
            schema_id: 'org.gnome.desktop.interface',
        }).get_string('color-scheme');
        this._spectreHubTitle.set_style(
            titleScheme === 'prefer-dark'
                ? 'color: #f5f9ff;'
                : 'color: #172235;'
        );
        titles.add_child(this._spectreHubTitle);
        titles.add_child(new St.Label({
            text: 'GNOME • MODERN • SECURE',
            style_class: 'spectre-hub-subtitle',
        }));
        header.add_child(titles);
        headerItem.add_child(header);
        this._logo.menu.addMenuItem(headerItem);

        const quickItem = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
            style_class: 'spectre-quick-grid-item',
        });
        const quickGrid = new St.BoxLayout({
            vertical: false,
            style_class: 'spectre-quick-grid',
            x_expand: true,
        });
        const closeHub = () => this._logo.menu.close();
        quickGrid.add_child(makeQuickButton('Files', 'folder-symbolic', '/usr/local/bin/spectre-files', closeHub));
        quickGrid.add_child(makeQuickButton('Terminal', 'utilities-terminal-symbolic', 'gnome-terminal', closeHub));
        quickGrid.add_child(makeQuickButton('Settings', 'preferences-system-symbolic', 'gnome-control-center', closeHub));
        quickGrid.add_child(makeQuickButton('Monitor', 'utilities-system-monitor-symbolic', 'gnome-system-monitor', closeHub));
        quickItem.add_child(quickGrid);
        this._logo.menu.addMenuItem(quickItem);

        const infoItem = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
            style_class: 'spectre-info-card-item',
        });
        const infoCard = new St.BoxLayout({
            vertical: true,
            style_class: 'spectre-info-card',
            x_expand: true,
        });

        const prettyName = GLib.get_os_info('PRETTY_NAME') ?? 'Spectre OS';
        const hostName = GLib.get_host_name() ?? 'spectre';
        const sessionType = (GLib.getenv('XDG_SESSION_TYPE') ?? 'wayland').toUpperCase();
        const desktop = GLib.getenv('XDG_CURRENT_DESKTOP') ?? 'GNOME';

        infoCard.add_child(new St.Label({
            text: prettyName,
            style_class: 'spectre-info-primary',
            x_align: Clutter.ActorAlign.START,
        }));
        infoCard.add_child(new St.Label({
            text: `${hostName}  •  ${desktop}  •  ${sessionType}`,
            style_class: 'spectre-info-secondary',
            x_align: Clutter.ActorAlign.START,
        }));
        infoItem.add_child(infoCard);
        this._logo.menu.addMenuItem(infoItem);

        addLauncher(this._logo.menu, 'Spectre Center', 'spectre-center', 'preferences-system-symbolic');
        addLauncher(this._logo.menu, 'Welcome to Spectre', 'spectre-welcome', 'help-about-symbolic');
        addLauncher(
            this._logo.menu,
            'Spectre Diagnostics',
            "gnome-terminal -- bash -lc 'spectre-diagnostics; echo; read -rp \"Press Enter to close... \"'",
            'utilities-system-monitor-symbolic'
        );
        this._logo.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        addLauncher(
            this._logo.menu,
            'Check for Updates',
            'spectre-update-manager',
            'software-update-available-symbolic'
        );

        Main.panel.addToStatusArea(`${this.uuid}-logo`, this._logo, 0, 'left');
        this._indicators.push(this._logo);
    }

    _buildTerminalMenu() {
        this._terminal = new PanelMenu.Button(0.0, 'Spectre Terminal');
        this._terminal.add_style_class_name('spectre-terminal-button');

        const row = new St.BoxLayout({
            vertical: false,
            style_class: 'spectre-panel-app-button',
        });
        row.add_child(new St.Icon({
            icon_name: 'utilities-terminal-symbolic',
            icon_size: 15,
            style_class: 'spectre-panel-app-icon',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        row.add_child(new St.Label({
            text: 'Terminal',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'spectre-panel-label',
        }));
        this._terminal.add_child(row);

        addLauncher(this._terminal.menu, 'New Terminal', 'gnome-terminal', 'utilities-terminal-symbolic');
        addLauncher(this._terminal.menu, 'Files', '/usr/local/bin/spectre-files', 'folder-symbolic');
        addLauncher(this._terminal.menu, 'Spectre Center', 'spectre-center', 'preferences-system-symbolic');
        this._terminal.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        addLauncher(
            this._terminal.menu,
            'Diagnostics',
            "gnome-terminal -- bash -lc 'spectre-diagnostics; echo; read -rp \"Press Enter to close... \"'",
            'utilities-system-monitor-symbolic'
        );

        Main.panel.addToStatusArea(`${this.uuid}-terminal`, this._terminal, 3, 'left');
        this._indicators.push(this._terminal);
    }

    _buildWorkspaceSwitcher() {
        const manager = global.workspace_manager;
        // GNOME inserts each status item at the requested index. Add the
        // buttons in reverse at index zero so their visual order is always
        // 1, 2, 3, 4 instead of depending on the order of other indicators.
        for (let i = 3; i >= 0; i--) {
            const button = new PanelMenu.Button(0.0, `Workspace ${i + 1}`, true);
            button.add_style_class_name('spectre-workspace-button');
            button.add_child(new St.Label({
                text: `${i + 1}`,
                y_align: Clutter.ActorAlign.CENTER,
                x_align: Clutter.ActorAlign.CENTER,
                style_class: 'spectre-workspace-label',
            }));
            button.connect('button-press-event', () => {
                const ws = manager.get_workspace_by_index(i);
                if (ws)
                    ws.activate(global.get_current_time());
                return Clutter.EVENT_STOP;
            });
            Main.panel.addToStatusArea(`${this.uuid}-workspace-${i + 1}`, button, 0, 'right');
            this._workspaceButtons[i] = button;
            this._indicators.push(button);
        }

        this._workspaceChangedId = manager.connect(
            'active-workspace-changed',
            () => this._syncWorkspaceState()
        );
        this._syncWorkspaceState();
    }


    _attachAppsSearch() {
        if (this._appsSearchAttachSource || this._appsMenu)
            return;

        const tryAttach = () => {
            const appsMenu = Main.panel.statusArea['apps-menu'];
            if (!appsMenu?.menu?.box)
                return false;

            this._appsMenu = appsMenu;
            this._appsSearchItem = new PopupMenu.PopupBaseMenuItem({
                reactive: false,
                can_focus: false,
                style_class: 'spectre-app-search-item',
            });

            const searchIcon = new St.Icon({
                icon_name: 'system-search-symbolic',
                style_class: 'spectre-app-search-icon',
                icon_size: 16,
            });
            this._appsSearchEntry = new St.Entry({
                hint_text: 'Search applications…',
                track_hover: true,
                can_focus: true,
                x_expand: true,
                style_class: 'spectre-app-search-entry',
                primary_icon: searchIcon,
            });
            this._appsSearchItem.add_child(this._appsSearchEntry);

            this._appsResultsItem = new PopupMenu.PopupBaseMenuItem({
                reactive: false,
                can_focus: false,
                style_class: 'spectre-app-search-results-item',
            });
            this._appsResultsBox = new St.BoxLayout({
                vertical: true,
                x_expand: true,
                style_class: 'spectre-app-search-results',
            });
            this._appsResultsItem.add_child(this._appsResultsBox);
            this._appsResultsItem.hide();

            appsMenu.menu.addMenuItem(this._appsSearchItem, 0);
            appsMenu.menu.addMenuItem(this._appsResultsItem, 1);

            this._appsSearchTextId = this._appsSearchEntry.clutter_text.connect(
                'text-changed', () => this._updateAppsSearch()
            );
            this._appsSearchKeyId = this._appsSearchEntry.clutter_text.connect(
                'key-press-event', (_actor, event) => this._onAppsSearchKey(event)
            );
            this._appsMenuOpenId = appsMenu.menu.connect(
                'open-state-changed', (_menu, open) => this._onAppsMenuState(open)
            );
            this._appSystemChangedId = this._appSystem.connect(
                'installed-changed', () => this._cacheInstalledApps()
            );

            this._cacheInstalledApps();
            return true;
        };

        if (tryAttach())
            return;

        // apps-menu is another GNOME extension, so it can be enabled a little
        // later than Spectre Panel. Retry briefly instead of depending on a
        // particular extension enable order.
        this._appsSearchAttachSource = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            350,
            () => {
                if (tryAttach()) {
                    this._appsSearchAttachSource = 0;
                    return GLib.SOURCE_REMOVE;
                }
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    _cacheInstalledApps() {
        if (!this._appSystem)
            return;

        try {
            this._installedApps = this._appSystem.get_installed()
                .filter(appInfo => {
                    try {
                        return appInfo.should_show();
                    } catch (_e) {
                        return true;
                    }
                })
                .map(appInfo => {
                    const name = appInfo.get_display_name?.() || appInfo.get_name?.() || '';
                    const description = appInfo.get_description?.() || '';
                    const id = appInfo.get_id?.() || '';
                    return {
                        appInfo,
                        id,
                        name,
                        description,
                        haystack: `${name} ${description} ${id}`.toLocaleLowerCase(),
                    };
                })
                .filter(item => item.name)
                .sort((a, b) => a.name.localeCompare(b.name));
        } catch (e) {
            console.error(`[Spectre Panel] Unable to index applications: ${e}`);
            this._installedApps = [];
        }
    }

    _initializeAppGridLayout() {
        if (!this._spectreSettings ||
            this._spectreSettings.get_boolean('app-grid-initialized'))
            return;

        const appIds = [...new Set((this._installedApps ?? [])
            .map(item => item.id)
            .filter(id => typeof id === 'string' && id.endsWith('.desktop')))];

        // A partially initialized user session can briefly expose only a few
        // launchers. Wait for Shell.AppSystem instead of saving an incomplete
        // grid and calling that repair complete.
        if (appIds.length < 6) {
            console.warn(`[Spectre Panel] App grid initialization deferred; only ${appIds.length} visible launchers.`);
            return;
        }

        try {
            // Do not synthesize GNOME Shell's private aa{sv} app-picker layout.
            // Shell owns the default layout and will populate it from the real
            // AppSystem. A one-time reset removes stale/empty layouts while
            // preserving every later user rearrangement.
            this._shellSettings.reset('app-picker-layout');
            this._spectreSettings.set_boolean('app-grid-initialized', true);
            console.log(`[Spectre Panel] Reset application grid to GNOME-managed default for ${appIds.length} visible applications.`);
        } catch (e) {
            console.error(`[Spectre Panel] Unable to reset application grid: ${e}`);
        }
    }

    _onAppsMenuState(open) {
        if (!open) {
            this._clearAppsSearch();
            return;
        }

        this._cacheInstalledApps();
        this._rememberAppsMenuActors();

        // Put keyboard focus straight into search. The normal category menu is
        // still visible until the user starts typing.
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            if (this._appsSearchEntry?.mapped)
                this._appsSearchEntry.grab_key_focus();
            return GLib.SOURCE_REMOVE;
        });
    }

    _rememberAppsMenuActors() {
        if (!this._appsMenu?.menu?.box)
            return;
        const own = new Set([this._appsSearchItem, this._appsResultsItem]);
        this._appsOriginalActors = this._appsMenu.menu.box.get_children()
            .filter(actor => !own.has(actor));
    }

    _setAppsSearchMode(active) {
        this._rememberAppsMenuActors();

        if (active && !this._appsSavedVisibility) {
            this._appsSavedVisibility = new Map();
            for (const actor of this._appsOriginalActors ?? [])
                this._appsSavedVisibility.set(actor, actor.visible);
        }

        for (const actor of this._appsOriginalActors ?? []) {
            if (active)
                actor.hide();
            else if (this._appsSavedVisibility?.has(actor))
                actor.visible = this._appsSavedVisibility.get(actor);
            else
                actor.show();
        }

        if (active)
            this._appsResultsItem?.show();
        else
            this._appsResultsItem?.hide();

        if (!active)
            this._appsSavedVisibility = null;
    }

    _scoreApp(item, query, words) {
        const name = item.name.toLocaleLowerCase();
        let score = 0;

        if (name === query)
            score += 1000;
        else if (name.startsWith(query))
            score += 700;
        else if (name.includes(query))
            score += 450;

        for (const word of words) {
            if (!item.haystack.includes(word))
                return -1;
            if (name.startsWith(word))
                score += 120;
            else if (name.includes(word))
                score += 70;
            else
                score += 20;
        }
        return score;
    }

    _updateAppsSearch() {
        if (!this._appsSearchEntry || !this._appsResultsBox)
            return;

        const raw = this._appsSearchEntry.get_text().trim();
        const query = raw.toLocaleLowerCase();
        this._appsResultsBox.destroy_all_children();
        this._firstSearchResult = null;

        if (!query) {
            this._setAppsSearchMode(false);
            return;
        }

        this._setAppsSearchMode(true);
        const words = query.split(/\s+/).filter(Boolean);
        const matches = (this._installedApps ?? [])
            .map(item => ({item, score: this._scoreApp(item, query, words)}))
            .filter(result => result.score >= 0)
            .sort((a, b) => b.score - a.score || a.item.name.localeCompare(b.item.name))
            .slice(0, 9);

        if (matches.length === 0) {
            const empty = new St.BoxLayout({
                vertical: true,
                style_class: 'spectre-app-search-empty',
                x_expand: true,
            });
            empty.add_child(new St.Icon({
                icon_name: 'system-search-symbolic',
                icon_size: 24,
                x_align: Clutter.ActorAlign.CENTER,
            }));
            empty.add_child(new St.Label({
                text: `No applications found for “${raw}”`,
                x_align: Clutter.ActorAlign.CENTER,
            }));
            this._appsResultsBox.add_child(empty);
            return;
        }

        for (const {item} of matches) {
            const button = new St.Button({
                reactive: true,
                can_focus: true,
                track_hover: true,
                x_expand: true,
                style_class: 'spectre-app-search-result',
            });
            const row = new St.BoxLayout({
                vertical: false,
                x_expand: true,
                style_class: 'spectre-app-search-result-row',
            });

            const icon = item.appInfo.get_icon?.();
            row.add_child(icon
                ? new St.Icon({gicon: icon, icon_size: 28, style_class: 'spectre-app-search-result-icon'})
                : new St.Icon({icon_name: 'application-x-executable-symbolic', icon_size: 28}));

            const labels = new St.BoxLayout({
                vertical: true,
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
                style_class: 'spectre-app-search-result-labels',
            });
            labels.add_child(new St.Label({
                text: item.name,
                x_align: Clutter.ActorAlign.START,
                style_class: 'spectre-app-search-result-name',
            }));
            if (item.description) {
                labels.add_child(new St.Label({
                    text: item.description,
                    x_align: Clutter.ActorAlign.START,
                    style_class: 'spectre-app-search-result-description',
                }));
            }
            row.add_child(labels);
            button.set_child(row);
            button.connect('clicked', () => this._launchSearchApp(item));
            this._appsResultsBox.add_child(button);

            if (!this._firstSearchResult)
                this._firstSearchResult = item;
        }
    }

    _onAppsSearchKey(event) {
        const symbol = event.get_key_symbol();
        if (symbol === Clutter.KEY_Return || symbol === Clutter.KEY_KP_Enter) {
            if (this._firstSearchResult) {
                this._launchSearchApp(this._firstSearchResult);
                return Clutter.EVENT_STOP;
            }
        }
        if (symbol === Clutter.KEY_Escape) {
            const text = this._appsSearchEntry?.get_text() ?? '';
            if (text) {
                this._appsSearchEntry.set_text('');
                return Clutter.EVENT_STOP;
            }
        }
        return Clutter.EVENT_PROPAGATE;
    }

    _launchSearchApp(item) {
        try {
            this._appsMenu?.menu.close();
            const app = item.id ? this._appSystem?.lookup_app(item.id) : null;
            if (app)
                app.activate();
            else
                item.appInfo.launch([], null);
        } catch (e) {
            console.error(`[Spectre Panel] Unable to launch ${item.name}: ${e}`);
        }
    }

    _clearAppsSearch() {
        if (this._appsSearchEntry)
            this._appsSearchEntry.set_text('');
        this._setAppsSearchMode(false);
        this._appsResultsBox?.destroy_all_children();
        this._firstSearchResult = null;
    }

    _detachAppsSearch() {
        if (this._appsSearchAttachSource) {
            GLib.source_remove(this._appsSearchAttachSource);
            this._appsSearchAttachSource = 0;
        }
        if (this._appsMenuOpenId && this._appsMenu?.menu) {
            this._appsMenu.menu.disconnect(this._appsMenuOpenId);
            this._appsMenuOpenId = 0;
        }
        if (this._appSystemChangedId && this._appSystem) {
            this._appSystem.disconnect(this._appSystemChangedId);
            this._appSystemChangedId = 0;
        }
        if (this._appsSearchTextId && this._appsSearchEntry?.clutter_text) {
            this._appsSearchEntry.clutter_text.disconnect(this._appsSearchTextId);
            this._appsSearchTextId = 0;
        }
        if (this._appsSearchKeyId && this._appsSearchEntry?.clutter_text) {
            this._appsSearchEntry.clutter_text.disconnect(this._appsSearchKeyId);
            this._appsSearchKeyId = 0;
        }

        this._setAppsSearchMode(false);
        this._appsResultsItem?.destroy();
        this._appsSearchItem?.destroy();

        this._appsMenu = null;
        this._appSystem = null;
        this._installedApps = [];
        this._appsSearchItem = null;
        this._appsResultsItem = null;
        this._appsResultsBox = null;
        this._appsSearchEntry = null;
        this._appsOriginalActors = null;
        this._appsSavedVisibility = null;
        this._firstSearchResult = null;
    }

    _installDirectionalTiling() {
        // Spectre intentionally owns Super+Arrow so GNOME can offer the
        // Cinnamon-style directional sequence that Mutter does not expose as
        // a native quarter-tiling keybinding. A direction first selects a
        // half; an orthogonal direction then refines it to the matching quarter.
        // Examples: Super+Left, Super+Up => top-left quarter.
        this._tilingBindings = [
            ['tile-window-left', 'left'],
            ['tile-window-right', 'right'],
            ['tile-window-up', 'up'],
            ['tile-window-down', 'down'],
        ];
        for (const [name, direction] of this._tilingBindings) {
            Main.wm.addKeybinding(
                name,
                this._spectreSettings,
                Meta.KeyBindingFlags.NONE,
                Shell.ActionMode.NORMAL,
                () => this._tileFocusedWindow(direction)
            );
        }
    }

    _removeDirectionalTiling() {
        for (const [name] of this._tilingBindings ?? []) {
            try {
                Main.wm.removeKeybinding(name);
            } catch (e) {
                console.debug(`[Spectre Panel] Unable to remove tiling keybinding ${name}: ${e}`);
            }
        }
        this._tilingBindings = [];
    }

    _sameRect(rect, target, tolerance = 12) {
        return Math.abs(rect.x - target.x) <= tolerance &&
            Math.abs(rect.y - target.y) <= tolerance &&
            Math.abs(rect.width - target.width) <= tolerance &&
            Math.abs(rect.height - target.height) <= tolerance;
    }

    _tileRects(area) {
        const leftWidth = Math.floor(area.width / 2);
        const rightWidth = area.width - leftWidth;
        const topHeight = Math.floor(area.height / 2);
        const bottomHeight = area.height - topHeight;
        const rightX = area.x + leftWidth;
        const bottomY = area.y + topHeight;
        return {
            left: {x: area.x, y: area.y, width: leftWidth, height: area.height},
            right: {x: rightX, y: area.y, width: rightWidth, height: area.height},
            top: {x: area.x, y: area.y, width: area.width, height: topHeight},
            bottom: {x: area.x, y: bottomY, width: area.width, height: bottomHeight},
            topLeft: {x: area.x, y: area.y, width: leftWidth, height: topHeight},
            topRight: {x: rightX, y: area.y, width: rightWidth, height: topHeight},
            bottomLeft: {x: area.x, y: bottomY, width: leftWidth, height: bottomHeight},
            bottomRight: {x: rightX, y: bottomY, width: rightWidth, height: bottomHeight},
        };
    }

    _classifyTile(rect, targets) {
        for (const [name, target] of Object.entries(targets)) {
            if (this._sameRect(rect, target))
                return name;
        }
        return 'free';
    }

    _targetForDirection(direction, state, targets) {
        // Directional composition mirrors Cinnamon's practical behavior:
        // horizontal + vertical => corner quarter, regardless of order.
        if (direction === 'left') {
            if (state === 'top' || state === 'topRight' || state === 'topLeft')
                return targets.topLeft;
            if (state === 'bottom' || state === 'bottomRight' || state === 'bottomLeft')
                return targets.bottomLeft;
            return targets.left;
        }
        if (direction === 'right') {
            if (state === 'top' || state === 'topLeft' || state === 'topRight')
                return targets.topRight;
            if (state === 'bottom' || state === 'bottomLeft' || state === 'bottomRight')
                return targets.bottomRight;
            return targets.right;
        }
        if (direction === 'up') {
            if (state === 'left' || state === 'bottomLeft' || state === 'topLeft')
                return targets.topLeft;
            if (state === 'right' || state === 'bottomRight' || state === 'topRight')
                return targets.topRight;
            return targets.top;
        }
        if (direction === 'down') {
            if (state === 'left' || state === 'topLeft' || state === 'bottomLeft')
                return targets.bottomLeft;
            if (state === 'right' || state === 'topRight' || state === 'bottomRight')
                return targets.bottomRight;
            return targets.bottom;
        }
        return null;
    }

    _tileFocusedWindow(direction) {
        try {
            const win = global.display.focus_window ?? global.display.get_focus_window?.();
            if (!win || win.is_fullscreen?.())
                return;
            if (win.allows_resize && !win.allows_resize())
                return;

            const workspace = win.get_workspace?.() ?? global.workspace_manager.get_active_workspace();
            const monitor = win.get_monitor();
            const area = workspace.get_work_area_for_monitor(monitor);
            const current = win.get_frame_rect();
            const targets = this._tileRects(area);
            const state = this._classifyTile(current, targets);
            const target = this._targetForDirection(direction, state, targets);
            if (!target)
                return;

            // Clear maximize before applying exact work-area geometry. Shell
            // owns this operation, so it works under Wayland without xdotool.
            win.unmaximize(Meta.MaximizeFlags.BOTH);
            win.move_resize_frame(true, target.x, target.y, target.width, target.height);
        } catch (e) {
            console.error(`[Spectre Panel] Directional tiling failed safely: ${e}`);
        }
    }

    _syncWorkspaceState() {
        const active = global.workspace_manager.get_active_workspace_index();
        for (let i = 0; i < this._workspaceButtons.length; i++) {
            const button = this._workspaceButtons[i];
            if (i === active)
                button.add_style_class_name('spectre-workspace-active');
            else
                button.remove_style_class_name('spectre-workspace-active');
        }
    }

    disable() {
        if (this._appearanceId && this._interfaceSettings) {
            this._interfaceSettings.disconnect(this._appearanceId);
            this._appearanceId = 0;
        }
        Main.panel.remove_style_class_name('spectre-light-mode');
        if (this._gridInitializedId && this._spectreSettings) {
            this._spectreSettings.disconnect(this._gridInitializedId);
            this._gridInitializedId = 0;
        }
        this._removeAppGridDesktopActions();
        this._removeDirectionalTiling();
        this._detachAppsSearch();
        if (this._sessionModeId) {
            Main.sessionMode.disconnect(this._sessionModeId);
            this._sessionModeId = 0;
        }
        // Restore other left-side GNOME menus in case teardown happens during
        // an unlock transition.
        for (const role of ['apps-menu', 'places-menu']) {
            const item = Main.panel.statusArea[role];
            if (item)
                item.visible = true;
        }
        if (this._nativeActivitiesActor) {
            this._nativeActivitiesActor.visible = this._nativeActivitiesWasVisible ?? true;
            this._nativeActivitiesActor = null;
            this._nativeActivitiesWasVisible = null;
        }
        if (this._workspaceChangedId) {
            global.workspace_manager.disconnect(this._workspaceChangedId);
            this._workspaceChangedId = 0;
        }
        for (const indicator of this._indicators ?? [])
            indicator.destroy();
        this._workspaceButtons = [];
        this._indicators = [];
        this._logo = null;
        this._terminal = null;
        this._spectreSettings = null;
        this._shellSettings = null;
        this._interfaceSettings = null;
    }
}
