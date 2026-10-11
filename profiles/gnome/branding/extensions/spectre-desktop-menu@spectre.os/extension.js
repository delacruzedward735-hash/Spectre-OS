import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const DOCK_SCHEMA = 'org.gnome.shell.extensions.dash-to-dock';
const SHELL_SCHEMA = 'org.gnome.shell';
const DING_UUID = 'ding@rastersoft.com';
const DING_RELOAD_HELPER = '/usr/local/bin/spectre-ding-reload';

function spawn(argv) {
    try {
        Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    } catch (e) {
        console.error(`[Spectre Desktop Menu] Unable to launch ${argv.join(' ')}: ${e}`);
    }
}

function desktopDirectory() {
    return GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP) ??
        GLib.build_filenamev([GLib.get_home_dir(), 'Desktop']);
}

function eventOriginatesFromClientWindow(event) {
    // RC5.6.1: DING desktop surfaces are client windows, but coordinate-only
    // global window hit-testing is not reliable for every Mutter/Wayland path.
    // Walk the actual event-source actor ancestry and refuse any event that
    // originated from a client window. This prevents the Shell fallback from
    // opening on top of DING's native GTK menu.
    let actor = null;
    try {
        actor = event.get_source?.() ?? null;
    } catch (_e) {
        actor = null;
    }

    while (actor) {
        try {
            if (typeof actor.get_meta_window === 'function' && actor.get_meta_window())
                return true;
        } catch (_e) {
            // Keep walking through intermediate Clutter actors.
        }
        try {
            actor = actor.get_parent?.() ?? null;
        } catch (_e) {
            actor = null;
        }
    }
    return false;
}

function pointInsideActor(actor, x, y) {
    if (!actor?.visible)
        return false;
    try {
        const [ax, ay] = actor.get_transformed_position();
        const [aw, ah] = actor.get_transformed_size();
        return x >= ax && x < ax + aw && y >= ay && y < ay + ah;
    } catch (_e) {
        return false;
    }
}

export default class SpectreDesktopMenuExtension extends Extension {
    enable() {
        this._menu = null;
        this._stageEventId = 0;
        this._overviewShowingId = 0;
        this._overviewHiddenId = 0;
        this._dockSettings = null;
        this._interfaceSettings = null;
        this._appearanceChangedId = 0;
        this._shellSettings = null;
        this._enabledExtensionsChangedId = 0;
        this._disabledExtensionsChangedId = 0;
        this._monitorsChangedId = 0;
        this._dingReloadSourceId = 0;

        try {
            this._dockSettings = new Gio.Settings({schema_id: DOCK_SCHEMA});
        } catch (_e) {
            // Dash-to-Dock is optional to this menu; background right-click
            // continues to work even if its schema disappears in a future image.
        }

        try {
            this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
            this._appearanceChangedId = this._interfaceSettings.connect('changed::color-scheme', () => this._syncTheme());
        } catch (_e) {
            this._interfaceSettings = null;
        }

        try {
            this._shellSettings = new Gio.Settings({schema_id: SHELL_SCHEMA});
            this._enabledExtensionsChangedId = this._shellSettings.connect(
                'changed::enabled-extensions', () => this._syncProvider()
            );
            this._disabledExtensionsChangedId = this._shellSettings.connect(
                'changed::disabled-extensions', () => this._syncProvider()
            );
        } catch (_e) {
            this._shellSettings = null;
        }

        this._buildMenu();
        this._syncTheme();
        this._syncProvider();

        // DING is a separate GTK desktop process. Mutter/QEMU monitor geometry
        // can change after login, so ask DING to restart after the final resize
        // event. Its GNOME extension relaunches it using the new geometry.
        this._monitorsChangedId = Main.layoutManager.connect(
            'monitors-changed', () => this._scheduleDingReload()
        );

        // A desktop menu must never survive into Overview/app-grid mode. Closing
        // on both transitions prevents the menu from visually floating over apps.
        this._overviewShowingId = Main.overview.connect('showing', () => this._menu?.close());
        this._overviewHiddenId = Main.overview.connect('hidden', () => this._menu?.close());
    }

    _dingIsEnabled() {
        // RC5.6.2 provider arbitration is global, not coordinate-based. DING's
        // extension owns the entire file-backed desktop whenever it is enabled.
        // In that state Spectre's Shell fallback must not subscribe to stage
        // right-clicks at all, which makes dual/overlapping menus impossible.
        if (!this._shellSettings)
            return true; // Fail closed: prefer no fallback over a duplicate menu.
        try {
            const enabled = this._shellSettings.get_strv('enabled-extensions');
            const disabled = this._shellSettings.get_strv('disabled-extensions');
            return enabled.includes(DING_UUID) && !disabled.includes(DING_UUID);
        } catch (e) {
            console.error(`[Spectre Desktop Menu] Unable to read DING state: ${e}`);
            return true;
        }
    }

    _syncProvider() {
        if (this._dingIsEnabled()) {
            this._menu?.close();
            if (this._stageEventId) {
                global.stage.disconnect(this._stageEventId);
                this._stageEventId = 0;
            }
            return;
        }

        // DING has been explicitly disabled/unavailable: only now activate the
        // Spectre Shell fallback. There is exactly one captured-event listener.
        if (!this._stageEventId) {
            this._stageEventId = global.stage.connect(
                'captured-event', (_stage, event) => this._onCapturedEvent(event)
            );
        }
    }

    _scheduleDingReload() {
        if (!this._dingIsEnabled())
            return;
        if (this._dingReloadSourceId) {
            GLib.Source.remove(this._dingReloadSourceId);
            this._dingReloadSourceId = 0;
        }
        this._dingReloadSourceId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            900,
            () => {
                this._dingReloadSourceId = 0;
                spawn([DING_RELOAD_HELPER, '--reason', 'monitors-changed']);
                return GLib.SOURCE_REMOVE;
            }
        );
    }

    _buildMenu() {
        this._menu = new PopupMenu.PopupMenu(
            Main.layoutManager.dummyCursor,
            0.0,
            St.Side.TOP
        );
        this._menu.actor.add_style_class_name('spectre-desktop-context-menu');
        Main.uiGroup.add_child(this._menu.actor);
        this._menu.actor.hide();

        // Keep the Shell-background fallback deliberately aligned with the
        // DING desktop menu. DING still owns files/icons; this menu only appears
        // in uncovered Shell background regions during monitor/QEMU resizes.
        this._addItem('Refresh', 'view-refresh-symbolic', () => {
            spawn(['/usr/local/bin/spectre-desktop-refresh']);
        });

        this._addItem('New Folder', 'folder-new-symbolic', () => {
            this._createNewFolder();
        });

        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._addItem('Show Desktop in Files', 'folder-symbolic', () => {
            spawn(['/usr/local/bin/spectre-files', desktopDirectory()]);
        });

        this._addItem('Open in Terminal', 'utilities-terminal-symbolic', () => {
            spawn(['gnome-terminal', `--working-directory=${desktopDirectory()}`]);
        });

        this._addItem('Change Background…', 'preferences-desktop-wallpaper-symbolic', () => {
            spawn(['gnome-control-center', 'background']);
        });

        this._addItem('Desktop Icons Settings', 'user-desktop-symbolic', () => {
            spawn(['gnome-extensions', 'prefs', 'ding@rastersoft.com']);
        });

        this._addItem('Desktop Apps & Icons', 'view-app-grid-symbolic', () => {
            spawn(['/usr/local/bin/spectre-desktop-apps']);
        });

        this._addItem('Display Settings', 'preferences-desktop-display-symbolic', () => {
            spawn(['gnome-control-center', 'display']);
        });

        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._addItem('Taskbar Settings', 'view-grid-symbolic', () => {
            spawn(['/usr/local/bin/spectre-taskbar-settings']);
        });

        this._addItem('Keyboard Shortcuts', 'input-keyboard-symbolic', () => {
            spawn(['/usr/local/bin/spectre-shortcuts']);
        });

        this._addItem('Spectre Center', 'preferences-system-symbolic', () => {
            spawn(['/usr/local/bin/spectre-center']);
        });
    }

    _syncTheme() {
        if (!this._menu?.actor)
            return;
        let light = false;
        try {
            light = this._interfaceSettings?.get_string('color-scheme') !== 'prefer-dark';
        } catch (_e) {
            light = false;
        }
        if (light)
            this._menu.actor.add_style_class_name('spectre-desktop-context-menu-light');
        else
            this._menu.actor.remove_style_class_name('spectre-desktop-context-menu-light');
    }

    _addItem(label, iconName, callback) {
        const item = new PopupMenu.PopupImageMenuItem(label, iconName);
        item.connect('activate', () => {
            this._menu?.close();
            try {
                callback();
            } catch (e) {
                console.error(`[Spectre Desktop Menu] ${label} failed: ${e}`);
            }
        });
        this._menu.addMenuItem(item);
    }

    _createNewFolder() {
        const parent = Gio.File.new_for_path(desktopDirectory());
        try {
            parent.make_directory_with_parents(null);
        } catch (_e) {
            // Existing Desktop directory is the normal case.
        }

        for (let n = 1; n < 1000; n++) {
            const name = n === 1 ? 'New Folder' : `New Folder (${n})`;
            const candidate = parent.get_child(name);
            if (candidate.query_exists(null))
                continue;
            try {
                candidate.make_directory(null);
                Main.notify('Spectre Desktop', `${name} created`);
                return;
            } catch (e) {
                console.error(`[Spectre Desktop Menu] Unable to create ${name}: ${e}`);
                Main.notifyError('Spectre Desktop', 'Unable to create a new folder');
                return;
            }
        }
    }

    _onCapturedEvent(event) {
        const type = event.type();

        // Match normal desktop-menu behavior: any mouse click outside an open
        // Spectre menu dismisses it, while the original click continues to the
        // application/desktop underneath. A new background right-click is then
        // allowed to reopen the menu at the new pointer position.
        if (type === Clutter.EventType.BUTTON_PRESS && this._menu?.actor?.visible) {
            const [x, y] = event.get_coords();
            if (!pointInsideActor(this._menu.actor, x, y))
                this._menu.close();
        }

        if (type !== Clutter.EventType.BUTTON_PRESS || event.get_button() !== 3)
            return Clutter.EVENT_PROPAGATE;

        if (!this._isUserDesktop() || Main.overview.visible)
            return Clutter.EVENT_PROPAGATE;

        // Defensive guard in addition to disconnecting the handler globally.
        // If a settings transition races one captured event, DING still wins.
        if (this._dingIsEnabled())
            return Clutter.EVENT_PROPAGATE;

        // DING remains the authoritative file-backed desktop provider. If the
        // click came from DING (or any other client surface), leave it alone.
        if (eventOriginatesFromClientWindow(event))
            return Clutter.EVENT_PROPAGATE;

        const [x, y] = event.get_coords();
        if (!this._isDesktopBackgroundPoint(x, y))
            return Clutter.EVENT_PROPAGATE;

        this._menu.close();
        Main.layoutManager.setDummyCursorGeometry(Math.round(x), Math.round(y), 1, 1);
        this._menu.open();
        return Clutter.EVENT_STOP;
    }

    _isUserDesktop() {
        return Main.sessionMode.currentMode === 'user' && !(Main.sessionMode.isLocked ?? false);
    }

    _isDesktopBackgroundPoint(x, y) {
        if (pointInsideActor(this._menu?.actor, x, y))
            return false;

        // Never intercept a normal application window. The event is captured at
        // the stage only so Spectre can provide a desktop menu without placing a
        // transparent actor over windows or relying on Nautilus private APIs.
        try {
            for (const actor of global.get_window_actors()) {
                if (pointInsideActor(actor, x, y))
                    return false;
            }
        } catch (e) {
            console.debug(`[Spectre Desktop Menu] Window hit-test fallback: ${e}`);
            return false;
        }

        // Do not steal right clicks from the top panel.
        if (pointInsideActor(Main.panel, x, y))
            return false;

        // Reserve the active taskbar edge for Dash-to-Dock's own menus and
        // reveal behavior. This remains safe even if the dock actor hierarchy
        // changes upstream.
        const monitor = Main.layoutManager.primaryMonitor;
        if (monitor && this._dockSettings) {
            const icon = this._dockSettings.get_int('dash-max-icon-size');
            const edge = Math.max(64, Math.min(icon + 28, 88));
            const position = this._dockSettings.get_string('dock-position');
            if (position === 'LEFT' && x <= monitor.x + edge)
                return false;
            if (position === 'RIGHT' && x >= monitor.x + monitor.width - edge)
                return false;
            if (position === 'BOTTOM' && y >= monitor.y + monitor.height - edge)
                return false;
            if (position === 'TOP' && y <= monitor.y + edge)
                return false;
        }

        return true;
    }

    disable() {
        if (this._stageEventId) {
            global.stage.disconnect(this._stageEventId);
            this._stageEventId = 0;
        }
        if (this._overviewShowingId) {
            Main.overview.disconnect(this._overviewShowingId);
            this._overviewShowingId = 0;
        }
        if (this._overviewHiddenId) {
            Main.overview.disconnect(this._overviewHiddenId);
            this._overviewHiddenId = 0;
        }
        if (this._monitorsChangedId) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
        if (this._dingReloadSourceId) {
            GLib.Source.remove(this._dingReloadSourceId);
            this._dingReloadSourceId = 0;
        }
        if (this._enabledExtensionsChangedId && this._shellSettings) {
            this._shellSettings.disconnect(this._enabledExtensionsChangedId);
            this._enabledExtensionsChangedId = 0;
        }
        if (this._disabledExtensionsChangedId && this._shellSettings) {
            this._shellSettings.disconnect(this._disabledExtensionsChangedId);
            this._disabledExtensionsChangedId = 0;
        }
        if (this._menu) {
            this._menu.close();
            this._menu.destroy();
            this._menu = null;
        }
        if (this._appearanceChangedId && this._interfaceSettings) {
            this._interfaceSettings.disconnect(this._appearanceChangedId);
            this._appearanceChangedId = 0;
        this._shellSettings = null;
        this._enabledExtensionsChangedId = 0;
        this._disabledExtensionsChangedId = 0;
        this._monitorsChangedId = 0;
        this._dingReloadSourceId = 0;
        }
        this._interfaceSettings = null;
        this._shellSettings = null;
        this._dockSettings = null;
    }
}
