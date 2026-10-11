from __future__ import annotations

import threading
from collections import Counter
from typing import Callable, Iterable

from .catalog import CATEGORY_ICONS, SIDEBAR_CATEGORY_ORDER, icon_for
from .runtime import RuntimeUnavailable, detect_runtime
from .service import ToolHubService

APP_ID = "com.spectre.KaliToolHub"
APP_TITLE = "Spectre ToolHub"

# RC8 adaptive layout: wide 3-panel workspace, compact full-width list.
# Breakpoint hides sidebar/details while exposing category/detail actions.
WINDOW_DEFAULT_WIDTH = 1080
WINDOW_DEFAULT_HEIGHT = 700
WINDOW_MIN_WIDTH = 640
WINDOW_MIN_HEIGHT = 440
SIDEBAR_WIDTH = 246
TOOLS_MIN_WIDTH = 0
DETAILS_MIN_WIDTH = 300
TOOLS_PANED_POSITION = 590
TOOL_CARD_DESCRIPTION_LIMIT = 118
DETAIL_DESCRIPTION_LIMIT = 460


def filter_cards(cards: Iterable[dict], query: str = "", category: str = "All Tools") -> list[dict]:
    """Pure filtering helper used by the GTK view and tests."""
    q = query.strip().casefold()
    cat = category.strip().casefold()
    result: list[dict] = []
    for card in cards:
        categories = [str(x).casefold() for x in card.get("categories", [])]
        primary = str(card.get("category", "")).casefold()
        if cat not in {"", "all", "all tools"}:
            if cat == "popular":
                if not card.get("popular"):
                    continue
            elif cat != primary and cat not in categories:
                continue
        haystack = " ".join(
            str(card.get(k, ""))
            for k in ("package", "title", "category", "description")
        ).casefold()
        haystack += " " + " ".join(categories)
        if q and q not in haystack:
            continue
        result.append(card)
    return result


def category_counts(cards: Iterable[dict]) -> dict[str, int]:
    """Return sidebar counts while de-duplicating category membership per tool."""
    rows = list(cards)
    counts: Counter[str] = Counter()
    counts["All Tools"] = len(rows)
    counts["Popular"] = sum(1 for row in rows if row.get("popular"))
    for row in rows:
        cats = set(str(x) for x in row.get("categories", []) if x)
        primary = str(row.get("category", "")).strip()
        if primary:
            cats.add(primary)
        for cat in cats:
            counts[cat] += 1
    return dict(counts)


def compact_description(text: str, limit: int = 180) -> str:
    """Normalize APT descriptions for a compact card/details presentation."""
    cleaned = " ".join(str(text or "").split())
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: max(0, limit - 1)].rstrip() + "…"


def tool_state(card: dict) -> tuple[str, str, str]:
    """Return (status label, status css class, action label) for a tool card."""
    installed = bool(card.get("installed"))
    available = bool(card.get("available", True))
    if installed:
        return "Installed", "installed-pill", "Remove"
    if available:
        return "Available", "available-pill", "Install"
    return "Preview", "preview-pill", "Initialize"


def gui_dependency_status() -> dict:
    """Return dependency status without requiring Gtk at module-import time."""
    try:
        import gi  # type: ignore
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gtk  # noqa: F401
        return {"ok": True, "missing": []}
    except Exception as exc:  # pragma: no cover - environment dependent
        return {
            "ok": False,
            "missing": ["python3-gi", "gir1.2-gtk-4.0", "gir1.2-adw-1"],
            "error": str(exc),
        }


def run_native_gui(runtime_name: str | None = None, dry_run: bool = False) -> int:
    try:
        import gi  # type: ignore
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gio, GLib, Gtk  # type: ignore
    except Exception as exc:
        raise RuntimeUnavailable(
            "Native GUI dependencies are missing. Install: "
            "sudo apt install -y python3-gi gir1.2-gtk-4.0 gir1.2-adw-1"
        ) from exc

    runtime = detect_runtime(runtime_name, dry_run=dry_run)
    service = ToolHubService(runtime)

    class ToolHubApp(Adw.Application):
        def __init__(self):
            super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
            self.window = None
            self.tools_rows: list[dict] = []
            self.collections_rows: list[dict] = []
            self.installed_packages: list[dict] = []
            self.selected_category = "All Tools"
            self.selected_package: str | None = None
            self.busy = False
            self.progress_indeterminate = True
            self.selected_packages: set[str] = set()
            self.queue_log_lines: list[str] = []
            self.preserve_operation = False
            self.sidebar_buttons: dict[str, object] = {}
            self.row_cards: dict[object, dict] = {}
            self.runtime_label = "unknown"
            self.connect("activate", self.on_activate)

        # ---------- construction ----------
        def on_activate(self, app):
            if self.window is not None:
                self.window.present()
                return

            self.window = Adw.ApplicationWindow(application=app)
            self.window.set_title(APP_TITLE)
            self.window.set_default_size(WINDOW_DEFAULT_WIDTH, WINDOW_DEFAULT_HEIGHT)
            self.window.set_size_request(WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

            root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            self.window.set_content(root)

            header = Adw.HeaderBar()
            title = Adw.WindowTitle(
                title=APP_TITLE,
                subtitle="Real Kali tools · isolated from the host OS",
            )
            header.set_title_widget(title)
            root.append(header)

            self.status_button = Gtk.Button(label="Checking…")
            self.status_button.add_css_class("flat")
            self.status_button.add_css_class("status-button")
            self.status_button.set_tooltip_text("Toolbox status · click to refresh")
            self.status_button.connect("clicked", lambda *_: self.refresh_all())
            header.pack_start(self.status_button)

            shell_button = Gtk.Button.new_from_icon_name("utilities-terminal-symbolic")
            shell_button.set_tooltip_text("Open Kali shell")
            shell_button.add_css_class("flat")
            shell_button.connect("clicked", self.open_shell)
            header.pack_end(shell_button)

            self.init_button = Gtk.Button(label="Initialize")
            self.init_button.add_css_class("suggested-action")
            self.init_button.connect(
                "clicked",
                lambda *_: self.run_action(
                    "Initializing Kali toolbox",
                    service.init,
                    lambda: self.refresh_all(refresh_tools=True),
                ),
            )
            header.pack_end(self.init_button)

            # BreakpointBin evaluates actual available width, not startup size.
            self.layout_bin = Adw.BreakpointBin()
            self.layout_bin.set_size_request(600, 300)
            self.layout_bin.set_hexpand(True)
            self.layout_bin.set_vexpand(True)
            root.append(self.layout_bin)
            main = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
            main.set_vexpand(True)
            self.layout_bin.set_child(main)

            # Sidebar
            sidebar_shell = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            sidebar_shell.set_size_request(SIDEBAR_WIDTH, -1)
            # Prevent descendant expanding labels from stretching navigation.
            sidebar_shell.set_hexpand(False)
            sidebar_shell.set_halign(Gtk.Align.START)
            self.sidebar_shell = sidebar_shell
            sidebar_shell.add_css_class("sidebar-shell")
            main.append(sidebar_shell)

            discover = Gtk.Label(label="DISCOVER")
            discover.set_xalign(0)
            discover.add_css_class("sidebar-heading")
            discover.set_margin_top(18)
            discover.set_margin_start(16)
            discover.set_margin_end(12)
            sidebar_shell.append(discover)

            sidebar_scroll = Gtk.ScrolledWindow()
            sidebar_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            sidebar_scroll.set_propagate_natural_width(False)
            sidebar_scroll.set_min_content_width(0)
            sidebar_scroll.set_max_content_width(SIDEBAR_WIDTH - 20)
            sidebar_scroll.set_vexpand(True)
            sidebar_shell.append(sidebar_scroll)

            self.sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            self.sidebar.set_margin_start(10)
            self.sidebar.set_margin_end(10)
            self.sidebar.set_margin_bottom(14)
            sidebar_scroll.set_child(self.sidebar)

            self.sidebar_separator = Gtk.Separator(orientation=Gtk.Orientation.VERTICAL)
            main.append(self.sidebar_separator)

            # Main content
            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            content.set_hexpand(True)
            content.set_vexpand(True)
            content.set_margin_top(16)
            content.set_margin_bottom(16)
            content.set_margin_start(18)
            content.set_margin_end(18)
            main.append(content)

            self.stack = Adw.ViewStack()
            self.stack.set_vexpand(True)

            switcher = Adw.ViewSwitcher()
            switcher.set_stack(self.stack)
            switcher.set_policy(Adw.ViewSwitcherPolicy.WIDE)
            content.append(switcher)

            # Dashboard/stat strip
            self.stats_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            content.append(self.stats_box)
            self.stat_catalog = self.make_stat_chip("applications-system-symbolic", "Catalog", "—")
            self.stat_installed = self.make_stat_chip("emblem-default-symbolic", "Installed", "—")
            self.stat_runtime = self.make_stat_chip("computer-symbolic", "Runtime", "—")
            for chip in (self.stat_catalog, self.stat_installed, self.stat_runtime):
                self.stats_box.append(chip[0])

            # Global search/refresh toolbar
            toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            content.append(toolbar)

            self.search = Gtk.SearchEntry()
            self.search.set_placeholder_text("Search tools, packages, categories, descriptions…")
            self.search.set_hexpand(True)
            self.search.connect("search-changed", lambda *_: self.render_all_views())
            toolbar.append(self.search)

            self.result_label = Gtk.Label(label="")
            self.result_label.add_css_class("dim-label")
            toolbar.append(self.result_label)

            refresh_catalog = Gtk.Button.new_from_icon_name("view-refresh-symbolic")
            refresh_catalog.set_tooltip_text("Refresh catalog from current Kali APT metadata")
            refresh_catalog.connect("clicked", lambda *_: self.refresh_all(refresh_tools=True))
            toolbar.append(refresh_catalog)

            # The compact navigation gets its OWN row, so it never fights the
            # bulk-install buttons for horizontal space at smaller VM sizes.
            self.compact_nav_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            self.compact_nav_bar.set_visible(False)
            content.append(self.compact_nav_bar)

            # Persistent multi-select controls; state survives filtering/reloads.
            selection_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            selection_bar.set_halign(Gtk.Align.FILL)
            content.append(selection_bar)
            self.compact_categories_button = Gtk.MenuButton(label="Categories")
            self.compact_categories_button.set_tooltip_text("Choose a tool category")
            self.compact_categories_popover = Gtk.Popover()
            self.compact_categories_button.set_popover(self.compact_categories_popover)
            self.compact_categories_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            self.compact_categories_box.set_margin_start(10)
            self.compact_categories_box.set_margin_end(10)
            self.compact_categories_box.set_margin_top(10)
            self.compact_categories_box.set_margin_bottom(10)
            self.compact_categories_scroll = Gtk.ScrolledWindow()
            self.compact_categories_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            self.compact_categories_scroll.set_min_content_height(200)
            self.compact_categories_scroll.set_max_content_height(360)
            self.compact_categories_scroll.set_child(self.compact_categories_box)
            self.compact_categories_popover.set_child(self.compact_categories_scroll)
            self.compact_nav_bar.append(self.compact_categories_button)

            self.compact_details_button = Gtk.Button(label="Details")
            self.compact_details_button.connect("clicked", self.show_compact_details)
            self.compact_nav_bar.append(self.compact_details_button)

            self.selection_count = Gtk.Label(label="0 selected")
            self.selection_count.add_css_class("dim-label")
            selection_bar.append(self.selection_count)

            self.clear_selection_button = Gtk.Button(label="Clear")
            self.clear_selection_button.add_css_class("flat")
            self.clear_selection_button.connect("clicked", self.clear_selection)
            selection_bar.append(self.clear_selection_button)

            self.install_selected_button = Gtk.Button(label="Install selected (0)")
            self.install_selected_button.add_css_class("suggested-action")
            self.install_selected_button.connect("clicked", self.confirm_multi_install)
            selection_bar.append(self.install_selected_button)
            self.update_selection_controls()

            content.append(self.stack)

            # Tools page with split details pane
            tools_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            tools_stack_page = self.stack.add_titled(tools_page, "tools", "All Tools")
            tools_stack_page.set_icon_name("applications-system-symbolic")

            self.tools_notice = Gtk.Label(label="")
            self.tools_notice.set_xalign(0)
            self.tools_notice.set_wrap(True)
            self.tools_notice.add_css_class("catalog-note")
            tools_page.append(self.tools_notice)

            self.tools_paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
            self.tools_paned.set_wide_handle(True)
            self.tools_paned.set_position(TOOLS_PANED_POSITION)
            self.tools_paned.set_vexpand(True)
            self.tools_paned.set_resize_start_child(True)
            self.tools_paned.set_resize_end_child(False)
            self.tools_paned.set_shrink_start_child(True)
            # Never collapse the details pane below its readable width.
            # The tool list absorbs resize pressure first.
            self.tools_paned.set_shrink_end_child(True)
            tools_page.append(self.tools_paned)

            tools_scroll = Gtk.ScrolledWindow()
            tools_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            tools_scroll.set_min_content_width(TOOLS_MIN_WIDTH)
            tools_scroll.set_vexpand(True)
            self.tools_paned.set_start_child(tools_scroll)

            self.tools_list = Gtk.ListBox()
            self.tools_list.set_selection_mode(Gtk.SelectionMode.SINGLE)
            self.tools_list.set_activate_on_single_click(True)
            self.tools_list.add_css_class("tool-list")
            self.tools_list.connect("row-selected", self.on_tool_selected)
            tools_scroll.set_child(self.tools_list)

            details_scroll = Gtk.ScrolledWindow()
            details_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            details_scroll.set_min_content_width(DETAILS_MIN_WIDTH)
            details_scroll.add_css_class("details-scroll")
            self.details_panel = self.build_details_panel(Gtk)
            details_scroll.set_child(self.details_panel)
            self.tools_paned.set_end_child(details_scroll)
            self.details_scroll = details_scroll

            # The old 1150sp trigger left the three panes visible in a
            # ~1280px VirtualBox guest, clipping the details actions offscreen.
            # Two stages preserve the familiar sidebar until it too is cramped:
            #   wide:    sidebar + tool list + details pane
            #   medium:  sidebar + full-width list; Details opens a dialog
            #   compact: full-width list; Categories and Details in their own row
            # Each breakpoint explicitly sets every affected visibility property.
            # libadwaita uses the LAST matching breakpoint, so the compact
            # setters must not depend on inherited medium-mode state.
            medium = Adw.Breakpoint.new(
                Adw.BreakpointCondition.parse("max-width: 1520sp")
            )
            for widget, visible in (
                (self.details_scroll, False),
                (self.compact_nav_bar, True),
                (self.compact_categories_button, False),
            ):
                medium.add_setter(widget, "visible", visible)
            medium.add_setter(switcher, "policy", Adw.ViewSwitcherPolicy.NARROW)
            self.layout_bin.add_breakpoint(medium)

            compact = Adw.Breakpoint.new(
                Adw.BreakpointCondition.parse("max-width: 980sp")
            )
            for widget, visible in (
                (self.sidebar_shell, False),
                (self.sidebar_separator, False),
                (self.details_scroll, False),
                (self.compact_nav_bar, True),
                (self.compact_categories_button, True),
            ):
                compact.add_setter(widget, "visible", visible)
            compact.add_setter(switcher, "policy", Adw.ViewSwitcherPolicy.NARROW)
            self.layout_bin.add_breakpoint(compact)

            # Collections page
            collections_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            collections_stack_page = self.stack.add_titled(collections_page, "collections", "Collections")
            collections_stack_page.set_icon_name("view-grid-symbolic")

            collection_info = Gtk.Label(
                label="Bulk-install Kali metapackages. Use All Tools for individual applications."
            )
            collection_info.set_xalign(0)
            collection_info.set_wrap(True)
            collection_info.add_css_class("catalog-note")
            collections_page.append(collection_info)

            collections_scroll = Gtk.ScrolledWindow()
            collections_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            collections_scroll.set_vexpand(True)
            collections_page.append(collections_scroll)

            self.collections_list = Gtk.ListBox()
            self.collections_list.set_selection_mode(Gtk.SelectionMode.NONE)
            self.collections_list.add_css_class("tool-list")
            collections_scroll.set_child(self.collections_list)

            # Installed page
            installed_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            installed_stack_page = self.stack.add_titled(installed_page, "installed", "Installed Tools")
            installed_stack_page.set_icon_name("emblem-default-symbolic")

            installed_intro = Gtk.Label(
                label="Tools installed inside the isolated Kali toolbox. Host packages remain untouched."
            )
            installed_intro.set_xalign(0)
            installed_intro.set_wrap(True)
            installed_intro.add_css_class("catalog-note")
            installed_page.append(installed_intro)

            installed_scroll = Gtk.ScrolledWindow()
            installed_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            installed_scroll.set_vexpand(True)
            installed_page.append(installed_scroll)

            self.installed_list = Gtk.ListBox()
            self.installed_list.set_selection_mode(Gtk.SelectionMode.NONE)
            self.installed_list.add_css_class("tool-list")
            installed_scroll.set_child(self.installed_list)

            # Bottom progress/log panel
            self.progress_revealer = Gtk.Revealer()
            self.progress_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
            root.append(self.progress_revealer)

            progress_frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            progress_frame.add_css_class("operation-panel")
            progress_frame.set_margin_start(16)
            progress_frame.set_margin_end(16)
            progress_frame.set_margin_top(8)
            progress_frame.set_margin_bottom(12)
            self.progress_revealer.set_child(progress_frame)

            progress_heading = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            progress_frame.append(progress_heading)
            self.progress_label = Gtk.Label(label="")
            self.progress_label.set_xalign(0)
            self.progress_label.set_hexpand(True)
            self.progress_label.set_wrap(True)
            progress_heading.append(self.progress_label)
            self.progress_percent_label = Gtk.Label(label="")
            self.progress_percent_label.add_css_class("stat-value")
            progress_heading.append(self.progress_percent_label)

            self.progress = Gtk.ProgressBar()
            progress_frame.append(self.progress)

            self.log_expander = Gtk.Expander(label="Operation details")
            progress_frame.append(self.log_expander)

            log_scroll = Gtk.ScrolledWindow()
            log_scroll.set_min_content_height(100)
            self.log_expander.set_child(log_scroll)

            self.log_view = Gtk.TextView()
            self.log_view.set_editable(False)
            self.log_view.set_monospace(True)
            self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            log_scroll.set_child(self.log_view)

            self.apply_css(Gtk)
            self.rebuild_sidebar({})
            self.show_empty_details()
            self.window.present()
            self.refresh_all()

        def apply_css(self, Gtk):
            css = b"""
            .sidebar-shell {
                background-color: alpha(@window_fg_color, 0.028);
                border-right: 1px solid alpha(@window_fg_color, 0.045);
            }
            .sidebar-heading {
                font-size: 0.78em;
                font-weight: 700;
                letter-spacing: 0.08em;
                color: alpha(@window_fg_color, 0.55);
            }
            .sidebar-button {
                border-radius: 10px;
                padding: 3px 7px;
                min-height: 31px;
            }
            .sidebar-button-selected {
                background-color: alpha(@accent_bg_color, 0.20);
                color: @window_fg_color;
                font-weight: 700;
            }
            .sidebar-count {
                border-radius: 10px;
                padding: 2px 7px;
                background-color: alpha(@window_fg_color, 0.08);
                color: alpha(@window_fg_color, 0.72);
                font-size: 0.85em;
            }
            .stat-chip {
                border-radius: 12px;
                padding: 7px 10px;
                background-color: alpha(@window_fg_color, 0.035);
                border: 1px solid alpha(@window_fg_color, 0.05);
            }
            .stat-title { font-size: 0.82em; color: alpha(@window_fg_color, 0.58); }
            .stat-value { font-weight: 700; }
            .catalog-note {
                border-radius: 10px;
                padding: 7px 10px;
                background-color: alpha(@accent_bg_color, 0.045);
                color: alpha(@window_fg_color, 0.66);
            }
            .tool-list { background: transparent; }
            .tool-list row {
                border-radius: 13px;
                margin: 0 3px 7px 0;
                background-color: alpha(@window_fg_color, 0.036);
                border: 1px solid alpha(@window_fg_color, 0.050);
            }
            .tool-list row:hover {
                background-color: alpha(@window_fg_color, 0.067);
                border-color: alpha(@window_fg_color, 0.085);
            }
            .tool-list row:selected {
                background-color: alpha(@accent_bg_color, 0.145);
                border-color: alpha(@accent_bg_color, 0.34);
            }
            .tool-card { padding: 10px 12px; }
            .tool-title { font-size: 1.02em; font-weight: 700; }
            .tool-package { font-family: monospace; font-size: 0.86em; color: alpha(@window_fg_color, 0.55); }
            .tool-description { color: alpha(@window_fg_color, 0.68); }
            .tool-icon-tile {
                border-radius: 12px;
                min-width: 44px;
                min-height: 44px;
                background-color: alpha(@accent_bg_color, 0.14);
                border: 1px solid alpha(@accent_bg_color, 0.12);
            }
            .category-pill {
                border-radius: 10px;
                padding: 2px 7px;
                background-color: alpha(@window_fg_color, 0.07);
                color: alpha(@window_fg_color, 0.68);
                font-size: 0.82em;
            }
            .installed-pill {
                border-radius: 10px;
                padding: 2px 7px;
                background-color: alpha(@success_bg_color, 0.18);
                color: @success_color;
                font-size: 0.82em;
                font-weight: 700;
            }
            .available-pill {
                border-radius: 10px;
                padding: 2px 7px;
                background-color: alpha(@accent_bg_color, 0.10);
                color: alpha(@window_fg_color, 0.70);
                font-size: 0.82em;
                font-weight: 600;
            }
            .preview-pill {
                border-radius: 10px;
                padding: 2px 7px;
                background-color: alpha(@warning_bg_color, 0.16);
                color: @warning_color;
                font-size: 0.82em;
                font-weight: 700;
            }
            .details-scroll {
                margin-left: 12px;
                background: transparent;
            }
            .details-shell {
                border-radius: 15px;
                padding: 17px;
                background-color: alpha(@window_fg_color, 0.030);
                border: 1px solid alpha(@window_fg_color, 0.050);
            }
            .details-title { font-size: 1.30em; font-weight: 800; }
            .details-package { font-family: monospace; color: alpha(@window_fg_color, 0.58); }
            .details-description { color: alpha(@window_fg_color, 0.76); }
            .details-section { font-size: 0.78em; font-weight: 700; letter-spacing: 0.05em; color: alpha(@window_fg_color, 0.52); }
            .details-meta { color: alpha(@window_fg_color, 0.62); }
            .details-actions { margin-top: 2px; }
            .isolation-note {
                border-radius: 10px;
                padding: 9px 10px;
                background-color: alpha(@window_fg_color, 0.035);
                color: alpha(@window_fg_color, 0.60);
            }
            .operation-panel {
                border-radius: 12px;
                padding: 10px;
                background-color: alpha(@window_fg_color, 0.045);
            }
            """
            provider = Gtk.CssProvider()
            provider.load_from_data(css)
            Gtk.StyleContext.add_provider_for_display(
                self.window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        def make_stat_chip(self, icon_name: str, title: str, value: str):
            shell = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            shell.add_css_class("stat-chip")
            shell.append(Gtk.Image.new_from_icon_name(icon_name))
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            title_label = Gtk.Label(label=title)
            title_label.set_xalign(0)
            title_label.add_css_class("stat-title")
            value_label = Gtk.Label(label=value)
            value_label.set_xalign(0)
            value_label.add_css_class("stat-value")
            text.append(title_label)
            text.append(value_label)
            shell.append(text)
            return shell, value_label

        def build_details_panel(self, Gtk):
            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=13)
            outer.set_size_request(DETAILS_MIN_WIDTH, -1)
            outer.add_css_class("details-shell")

            # Compact identity header keeps icon, title and state visually grouped.
            header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            outer.append(header)

            self.details_icon_tile = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            self.details_icon_tile.set_halign(Gtk.Align.START)
            self.details_icon_tile.set_valign(Gtk.Align.START)
            self.details_icon_tile.add_css_class("tool-icon-tile")
            self.details_icon = Gtk.Image.new_from_icon_name("applications-system-symbolic")
            self.details_icon.set_pixel_size(34)
            self.details_icon.set_margin_top(7)
            self.details_icon.set_margin_bottom(7)
            self.details_icon.set_margin_start(7)
            self.details_icon.set_margin_end(7)
            self.details_icon_tile.append(self.details_icon)
            header.append(self.details_icon_tile)

            identity = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            identity.set_hexpand(True)
            header.append(identity)

            self.details_title = Gtk.Label(label="Select a tool")
            self.details_title.set_xalign(0)
            self.details_title.set_wrap(True)
            self.details_title.add_css_class("details-title")
            identity.append(self.details_title)

            self.details_package = Gtk.Label(label="")
            self.details_package.set_xalign(0)
            self.details_package.set_selectable(True)
            self.details_package.set_ellipsize(3)
            self.details_package.add_css_class("details-package")
            identity.append(self.details_package)

            self.details_status = Gtk.Label(label="")
            self.details_status.set_xalign(0)
            self.details_status.set_halign(Gtk.Align.START)
            self.details_status.add_css_class("available-pill")
            identity.append(self.details_status)

            outer.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

            desc_heading = Gtk.Label(label="ABOUT")
            desc_heading.set_xalign(0)
            desc_heading.add_css_class("details-section")
            outer.append(desc_heading)

            self.details_description = Gtk.Label(label="Choose a tool from the list to view its package details.")
            self.details_description.set_xalign(0)
            self.details_description.set_wrap(True)
            self.details_description.set_selectable(True)
            self.details_description.add_css_class("details-description")
            outer.append(self.details_description)

            cat_heading = Gtk.Label(label="CATEGORIES")
            cat_heading.set_xalign(0)
            cat_heading.add_css_class("details-section")
            outer.append(cat_heading)

            self.details_categories = Gtk.FlowBox()
            self.details_categories.set_selection_mode(Gtk.SelectionMode.NONE)
            self.details_categories.set_max_children_per_line(2)
            self.details_categories.set_row_spacing(6)
            self.details_categories.set_column_spacing(6)
            outer.append(self.details_categories)

            outer.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

            self.details_action = Gtk.Button(label="Install")
            self.details_action.add_css_class("suggested-action")
            self.details_action.set_sensitive(False)
            self.details_action.connect("clicked", self.details_action_clicked)
            outer.append(self.details_action)

            actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            actions.add_css_class("details-actions")
            outer.append(actions)

            copy_button = Gtk.Button(label="Copy package")
            copy_button.set_hexpand(True)
            copy_button.add_css_class("flat")
            copy_button.connect("clicked", self.copy_selected_package)
            actions.append(copy_button)

            shell_button = Gtk.Button(label="Kali Shell")
            shell_button.set_hexpand(True)
            shell_button.add_css_class("flat")
            shell_button.connect("clicked", self.open_shell)
            actions.append(shell_button)

            isolation = Gtk.Label(label="Isolated install: Kali packages stay inside the toolbox; host APT sources are unchanged.")
            isolation.set_xalign(0)
            isolation.set_wrap(True)
            isolation.add_css_class("isolation-note")
            outer.append(isolation)

            spacer = Gtk.Box()
            spacer.set_vexpand(True)
            outer.append(spacer)
            return outer

        # ---------- helpers ----------
        def clear_box(self, box):
            child = box.get_first_child()
            while child:
                nxt = child.get_next_sibling()
                box.remove(child)
                child = nxt

        def clear_flowbox(self, flowbox):
            child = flowbox.get_first_child()
            while child:
                nxt = child.get_next_sibling()
                flowbox.remove(child)
                child = nxt

        def clear_list(self, listbox):
            child = listbox.get_first_child()
            while child:
                nxt = child.get_next_sibling()
                listbox.remove(child)
                child = nxt

        def category_button(self, category: str, count: int):
            icon_name = "view-grid-symbolic" if category == "All Tools" else CATEGORY_ICONS.get(category)
            content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=9)
            if icon_name:
                content.append(Gtk.Image.new_from_icon_name(icon_name))
            label = Gtk.Label(label=category)
            label.set_xalign(0)
            label.set_hexpand(True)
            # Long category labels must not inflate the entire sidebar.
            label.set_ellipsize(3)  # Pango.EllipsizeMode.END
            label.set_max_width_chars(23)
            content.append(label)
            count_label = Gtk.Label(label=str(count))
            count_label.add_css_class("sidebar-count")
            content.append(count_label)
            btn = Gtk.Button()
            btn.set_child(content)
            btn.set_halign(Gtk.Align.FILL)
            btn.add_css_class("flat")
            btn.add_css_class("sidebar-button")
            if category == self.selected_category:
                btn.add_css_class("sidebar-button-selected")
            btn.connect("clicked", lambda _b, c=category: self.select_category(c))
            self.sidebar_buttons[category] = btn
            return btn

        def rebuild_sidebar(self, counts: dict[str, int]):
            self.clear_box(self.sidebar)
            self.sidebar_buttons = {}
            self.clear_box(self.compact_categories_box)
            names = ["All Tools", "Popular"] + [
                c for c in SIDEBAR_CATEGORY_ORDER if c != "Popular" and counts.get(c, 0)
            ]
            for category in names:
                count = counts.get(category, 0)
                self.sidebar.append(self.category_button(category, count))
                btn = Gtk.Button(label=f"{category}  ({count})")
                btn.add_css_class("flat")
                btn.connect("clicked", lambda _b, c=category: self.select_category(c))
                self.compact_categories_box.append(btn)

        def select_category(self, category: str):
            self.selected_category = category
            self.compact_categories_popover.popdown()
            self.stack.set_visible_child_name("tools")
            self.rebuild_sidebar(category_counts(self.tools_rows))
            self.render_tools()

        def set_log(self, text: str):
            self.log_view.get_buffer().set_text(text or "")

        def set_busy(self, busy: bool, label: str = ""):
            self.busy = busy
            self.init_button.set_sensitive(not busy)
            self.update_selection_controls()
            self.progress_revealer.set_reveal_child(busy or bool(label))
            self.progress_label.set_text(label)
            self.progress_percent_label.set_text("")
            self.progress_indeterminate = busy
            if busy:
                self.progress.set_fraction(0.0)
                self.progress.pulse()

        def pulse(self):
            if self.busy:
                if self.progress_indeterminate:
                    self.progress.pulse()
                GLib.timeout_add(180, self.pulse)
            return False

        def hide_progress_later(self):
            if not self.busy:
                self.progress_revealer.set_reveal_child(False)
            return False

        # ---------- async actions ----------
        def run_action(self, label: str, fn: Callable, after: Callable | None = None):
            if self.busy:
                return
            self.set_busy(True, label)
            self.set_log("")
            self.pulse()

            def worker():
                try:
                    result = fn()
                    GLib.idle_add(self.action_done, label, result, after, None)
                except Exception as exc:
                    GLib.idle_add(self.action_done, label, None, after, exc)

            threading.Thread(target=worker, daemon=True).start()

        def action_done(self, label, result, after, error):
            self.busy = False
            self.progress_indeterminate = False
            self.progress.set_fraction(1.0 if error is None else 0.0)
            self.update_selection_controls()
            if error is not None:
                self.progress_label.set_text(f"Failed: {error}")
                self.set_log(str(error))
            else:
                self.progress_label.set_text(f"Completed: {label}")
                if isinstance(result, dict):
                    self.set_log(str(result.get("output") or result))
                else:
                    self.set_log(str(result or "Done"))
                if after:
                    after()
                GLib.timeout_add_seconds(4, self.hide_progress_later)
            return False

        def refresh_all(self, refresh_tools: bool = False, preserve_operation: bool = False):
            if self.busy:
                return
            self.preserve_operation = preserve_operation
            self.set_busy(True, "Loading Kali tool catalog")
            self.pulse()

            def worker():
                try:
                    status = service.status()
                    tools = service.refresh_tools() if refresh_tools else service.tools()
                    collections = service.catalog()
                    installed = service.installed() if status.get("running") else {"packages": []}
                    GLib.idle_add(self.refresh_done, status, tools, collections, installed, None)
                except Exception as exc:
                    GLib.idle_add(self.refresh_done, None, None, None, None, exc)

            threading.Thread(target=worker, daemon=True).start()

        def refresh_done(self, status, tools, collections, installed, error):
            self.busy = False
            if error:
                self.status_button.set_label("Unavailable")
                self.progress_label.set_text(f"Refresh failed: {error}")
                self.progress_revealer.set_reveal_child(True)
                self.set_log(str(error))
                self.update_selection_controls()
                self.preserve_operation = False
                return False

            running = bool(status.get("running"))
            exists = bool(status.get("exists"))
            runtime = status.get("runtime", "unknown")
            self.runtime_label = runtime
            if running:
                self.status_button.set_label(f"● Kali running · {runtime}")
            elif exists:
                self.status_button.set_label(f"○ Kali stopped · {runtime}")
            else:
                self.status_button.set_label(f"Not initialized · {runtime}")

            self.tools_rows = tools.get("tools", [])
            installed_now = {r.get("package") for r in self.tools_rows if r.get("installed")}
            self.selected_packages.difference_update(installed_now)
            self.update_selection_controls()
            self.collections_rows = collections.get("groups", [])
            self.installed_packages = installed.get("packages", [])

            installed_names = {row.get("package", "").split(":", 1)[0] for row in self.installed_packages}
            installed_count = sum(1 for row in self.tools_rows if row.get("package") in installed_names or row.get("installed"))

            self.stat_catalog[1].set_text(str(len(self.tools_rows)))
            self.stat_installed[1].set_text(str(installed_count))
            self.stat_runtime[1].set_text(runtime)
            self.rebuild_sidebar(category_counts(self.tools_rows))

            source = tools.get("source", "preview")
            if source == "kali-apt":
                self.tools_notice.set_text(
                    f"Full current Kali catalog: {tools.get('count', len(self.tools_rows))} tool packages "
                    f"from {tools.get('metapackage_count', 0)} official kali-tools-* collections."
                )
            elif source == "bundled-snapshot":
                self.tools_notice.set_text(
                    f"Bundled verified Kali catalog: {tools.get('count', len(self.tools_rows))} tool packages. "
                    "Browse offline; installing a tool initializes the Kali container and refreshes its repositories. "
                    "Catalog snapshot may differ from current Kali Rolling."
                )
            elif source == "mock-preview":
                self.tools_notice.set_text(
                    f"Mock UI preview: {tools.get('count', len(self.tools_rows))} representative real Kali packages. "
                    "Initialize the real Kali toolbox to load the complete current catalog."
                )
            else:
                self.tools_notice.set_text(
                    "Preview mode: showing well-known real Kali packages. Initialize the toolbox to discover the complete current Kali catalog."
                )

            self.render_all_views()
            if not self.preserve_operation:
                self.progress_revealer.set_reveal_child(False)
            else:
                self.progress_revealer.set_reveal_child(True)
                self.show_queue_summary()
            self.preserve_operation = False
            return False

        # ---------- rendering ----------
        def render_all_views(self):
            self.render_tools()
            self.render_collections()
            self.render_installed()

        def make_icon_tile(self, icon_name: str, pixel_size: int = 28):
            tile = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            tile.add_css_class("tool-icon-tile")
            tile.set_valign(Gtk.Align.CENTER)
            image = Gtk.Image.new_from_icon_name(icon_name)
            image.set_pixel_size(pixel_size)
            image.set_margin_top(7)
            image.set_margin_bottom(7)
            image.set_margin_start(7)
            image.set_margin_end(7)
            tile.append(image)
            return tile

        def make_pill(self, text: str, css_class: str = "category-pill"):
            label = Gtk.Label(label=text)
            label.set_use_markup(False)
            label.set_max_width_chars(26)
            label.set_ellipsize(3)
            label.add_css_class(css_class)
            return label

        def make_tool_row(self, card: dict, *, selectable: bool = True):
            row = Gtk.ListBoxRow()
            row.set_activatable(selectable)
            row.set_selectable(selectable)
            card_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            card_box.add_css_class("tool-card")
            row.set_child(card_box)

            package = str(card.get("package", ""))
            category = str(card.get("category", "Kali Tool"))
            icon_name = str(card.get("icon") or icon_for(package, category))
            if selectable and not card.get("installed"):
                checkbox = Gtk.CheckButton()
                checkbox.set_tooltip_text(f"Select {package} for batch installation")
                checkbox.set_active(package in self.selected_packages)
                checkbox.connect("toggled", lambda btn, name=package: self.toggle_package(name, btn.get_active()))
                card_box.append(checkbox)
            card_box.append(self.make_icon_tile(icon_name))

            info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            info.set_hexpand(True)
            card_box.append(info)

            title_line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            title = Gtk.Label(label=str(card.get("title") or package))
            title.set_use_markup(False)
            title.set_xalign(0)
            title.set_max_width_chars(32)
            title.set_ellipsize(3)
            title.add_css_class("tool-title")
            title_line.append(title)
            if card.get("popular"):
                star = Gtk.Image.new_from_icon_name("starred-symbolic")
                star.set_tooltip_text("Popular Kali tool")
                title_line.append(star)
            title_line.append(self.make_pill(category))
            info.append(title_line)

            pkg = Gtk.Label(label=package)
            pkg.set_use_markup(False)
            pkg.set_xalign(0)
            pkg.add_css_class("tool-package")
            info.append(pkg)

            desc = Gtk.Label(label=compact_description(str(card.get("description", "")), TOOL_CARD_DESCRIPTION_LIMIT))
            desc.set_use_markup(False)
            desc.set_xalign(0)
            desc.set_wrap(True)
            desc.set_lines(2)
            desc.add_css_class("tool-description")
            info.append(desc)

            installed = bool(card.get("installed"))
            available = bool(card.get("available", True))
            state_text, state_class, action_text = tool_state(card)
            action_rail = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            action_rail.set_valign(Gtk.Align.CENTER)
            action_rail.set_halign(Gtk.Align.END)

            state = self.make_pill(state_text, state_class)
            state.set_halign(Gtk.Align.END)
            action_rail.append(state)

            action = Gtk.Button(label=action_text)
            action.set_halign(Gtk.Align.END)
            action.set_size_request(78, -1)
            action.add_css_class("destructive-action" if installed else "suggested-action")
            action.connect("clicked", lambda _b, p=package, i=installed, c=card: self.package_action(p, i, c))
            action_rail.append(action)
            card_box.append(action_rail)

            return row

        def make_collection_row(self, card: dict):
            row = Gtk.ListBoxRow()
            row.set_selectable(False)
            row.set_activatable(False)
            shell = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            shell.add_css_class("tool-card")
            row.set_child(shell)

            shell.append(self.make_icon_tile("view-grid-symbolic"))
            info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            info.set_hexpand(True)
            shell.append(info)

            title_line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            title = Gtk.Label(label=str(card.get("title") or card.get("package", "Collection")))
            title.set_xalign(0)
            title.set_use_markup(False)
            title.add_css_class("tool-title")
            title_line.append(title)
            weight = str(card.get("weight") or "standard")
            if weight in {"large", "very-large", "huge"}:
                title_line.append(self.make_pill(weight.replace("-", " ").title(), "preview-pill"))
            info.append(title_line)

            pkg = Gtk.Label(label=str(card.get("package", "")))
            pkg.set_xalign(0)
            pkg.set_use_markup(False)
            pkg.add_css_class("tool-package")
            info.append(pkg)

            desc = Gtk.Label(label=compact_description(str(card.get("description", "")), 180))
            desc.set_xalign(0)
            desc.set_use_markup(False)
            desc.set_wrap(True)
            desc.set_lines(2)
            desc.add_css_class("tool-description")
            info.append(desc)

            installed = bool(card.get("installed"))
            available = bool(card.get("available", True))
            action = Gtk.Button(label="Remove" if installed else ("Install" if available else "Initialize"))
            action.set_valign(Gtk.Align.CENTER)
            action.add_css_class("destructive-action" if installed else "suggested-action")
            action.connect("clicked", lambda _b, p=card.get("package", ""), i=installed, c=card: self.package_action(p, i, c))
            shell.append(action)
            return row

        def render_tools(self):
            self.clear_list(self.tools_list)
            self.row_cards = {}
            rows = filter_cards(self.tools_rows, self.search.get_text(), self.selected_category)
            self.result_label.set_text(f"{len(rows)} tool{'s' if len(rows) != 1 else ''}")

            if not rows:
                empty_row = Gtk.ListBoxRow()
                empty_row.set_selectable(False)
                empty = Adw.StatusPage(title="No matching tools", description="Try another category or search term.")
                empty.set_icon_name("system-search-symbolic")
                empty_row.set_child(empty)
                self.tools_list.append(empty_row)
                self.show_empty_details()
                return

            preferred_row = None
            for card in rows:
                row = self.make_tool_row(card, selectable=True)
                self.row_cards[row] = card
                self.tools_list.append(row)
                if card.get("package") == self.selected_package:
                    preferred_row = row

            if preferred_row is None:
                preferred_row = self.tools_list.get_row_at_index(0)
            if preferred_row is not None:
                self.tools_list.select_row(preferred_row)

        def render_collections(self):
            self.clear_list(self.collections_list)
            query = self.search.get_text().strip().casefold()
            visible = []
            for card in self.collections_rows:
                blob = " ".join(str(card.get(k, "")) for k in ("package", "title", "description", "category")).casefold()
                if query and query not in blob:
                    continue
                visible.append(card)
            if not visible:
                row = Gtk.ListBoxRow()
                row.set_selectable(False)
                empty = Adw.StatusPage(title="No matching collections", description="Try another search term.")
                empty.set_icon_name("system-search-symbolic")
                row.set_child(empty)
                self.collections_list.append(row)
                return
            for card in visible:
                self.collections_list.append(self.make_collection_row(card))

        def render_installed(self):
            self.clear_list(self.installed_list)
            installed_names = {row.get("package", "").split(":", 1)[0] for row in self.installed_packages}
            tools = [
                dict(row, installed=True)
                for row in self.tools_rows
                if row.get("package") in installed_names or row.get("installed")
            ]
            tools = filter_cards(tools, self.search.get_text(), "All Tools")
            if not tools:
                row = Gtk.ListBoxRow()
                row.set_selectable(False)
                empty = Adw.StatusPage(
                    title="No installed Kali tools",
                    description="Install tools from All Tools or use an optional Collection.",
                )
                empty.set_icon_name("package-x-generic-symbolic")
                row.set_child(empty)
                self.installed_list.append(row)
                return
            for card in tools:
                self.installed_list.append(self.make_tool_row(card, selectable=False))

        # ---------- details ----------
        def on_tool_selected(self, _listbox, row):
            if row is None:
                self.show_empty_details()
                return
            card = self.row_cards.get(row)
            if not card:
                self.show_empty_details()
                return
            self.selected_package = str(card.get("package") or "")
            self.show_details(card)

        def show_empty_details(self):
            self.selected_package = None
            self.details_icon.set_from_icon_name("applications-system-symbolic")
            self.details_title.set_text("Select a tool")
            self.details_package.set_text("")
            self.details_status.set_text("Ready")
            for css_class in ("installed-pill", "preview-pill"):
                self.details_status.remove_css_class(css_class)
            self.details_status.add_css_class("available-pill")
            self.details_description.set_text("Choose a Kali tool to see its package, categories, installation state, and available actions.")
            self.clear_flowbox(self.details_categories)
            self.details_action.set_sensitive(False)
            self.details_action.set_label("Install")
            self.details_action.remove_css_class("destructive-action")
            self.details_action.add_css_class("suggested-action")

        def show_details(self, card: dict):
            package = str(card.get("package", ""))
            category = str(card.get("category", "Kali Tool"))
            self.details_icon.set_from_icon_name(str(card.get("icon") or icon_for(package, category)))
            self.details_title.set_text(str(card.get("title") or package))
            self.details_package.set_text(package)
            installed = bool(card.get("installed"))
            available = bool(card.get("available", True))
            state_text, state_class, _action_text = tool_state(card)
            self.details_status.set_text(state_text)
            for css_class in ("installed-pill", "available-pill", "preview-pill"):
                self.details_status.remove_css_class(css_class)
            self.details_status.add_css_class(state_class)
            self.details_description.set_text(compact_description(str(card.get("description", "Kali security tool package.")), DETAIL_DESCRIPTION_LIMIT))

            self.clear_flowbox(self.details_categories)
            categories = list(dict.fromkeys(card.get("categories") or [category]))
            for cat in categories:
                self.details_categories.insert(self.make_pill(str(cat)), -1)

            self.details_action.set_sensitive(True)
            self.details_action.set_label("Remove" if installed else ("Install" if available else "Initialize Toolbox"))
            self.details_action.remove_css_class("destructive-action")
            self.details_action.remove_css_class("suggested-action")
            self.details_action.add_css_class("destructive-action" if installed else "suggested-action")

        def details_action_clicked(self, *_args):
            if not self.selected_package:
                return
            card = next((row for row in self.tools_rows if row.get("package") == self.selected_package), None)
            if card:
                self.package_action(self.selected_package, bool(card.get("installed")), card)

        def show_compact_details(self, *_args):
            card = next((r for r in self.tools_rows if r.get("package") == self.selected_package), None)
            if not card:
                return
            dlg = Adw.MessageDialog(
                transient_for=self.window,
                heading=str(card.get("title") or card.get("package")),
                body=(str(card.get("package", "")) + "\n\n" +
                      compact_description(str(card.get("description", "")), 1200)),
            )
            dlg.add_response("close", "Close")
            dlg.set_default_response("close")
            dlg.present()

        def copy_selected_package(self, *_args):
            if not self.selected_package:
                return
            clipboard = self.window.get_clipboard()
            clipboard.set_text(self.selected_package)
            self.progress_revealer.set_reveal_child(True)
            self.progress_label.set_text(f"Copied package name: {self.selected_package}")
            self.progress.set_fraction(1.0)
            GLib.timeout_add_seconds(2, self.hide_progress_later)

        # ---------- selection and streamed install queue ----------
        def update_selection_controls(self):
            if not hasattr(self, "install_selected_button"):
                return
            n = len(self.selected_packages)
            self.selection_count.set_text(f"{n} selected")
            self.install_selected_button.set_label(f"Install selected ({n})")
            self.install_selected_button.set_sensitive(n > 0 and not self.busy)
            self.clear_selection_button.set_sensitive(n > 0 and not self.busy)

        def toggle_package(self, package: str, enabled: bool):
            if self.busy:
                return
            if enabled:
                if len(self.selected_packages) >= 25:
                    self.progress_revealer.set_reveal_child(True)
                    self.progress_label.set_text("Maximum 25 tools per batch; install this set first")
                    self.render_tools()
                    return
                self.selected_packages.add(package)
            else:
                self.selected_packages.discard(package)
            self.update_selection_controls()

        def clear_selection(self, *_args):
            if self.busy:
                return
            self.selected_packages.clear()
            self.update_selection_controls()
            self.render_tools()

        def confirm_multi_install(self, *_args):
            if self.busy or not self.selected_packages:
                return
            packages = sorted(self.selected_packages)
            dlg = Adw.MessageDialog(
                transient_for=self.window,
                heading=f"Install {len(packages)} selected Kali tools?",
                body=("Install selected tools sequentially inside rootless Podman. "
                      "Package dependencies, downloads and disk usage depend on Kali. "
                      "Check available guest storage before large batches.\n\n" +
                      ", ".join(packages[:10]) +
                      (f" … (+{len(packages)-10})" if len(packages) > 10 else "")),
            )
            dlg.add_response("cancel", "Cancel")
            dlg.add_response("install", "Install selected")
            dlg.set_default_response("cancel")
            dlg.set_close_response("cancel")
            dlg.set_response_appearance("install", Adw.ResponseAppearance.SUGGESTED)
            dlg.connect("response", lambda _d, response: self.install_packages(packages) if response == "install" else None)
            dlg.present()

        def show_queue_summary(self):
            if hasattr(self, "queue_summary"):
                result = self.queue_summary
                self.progress_label.set_text(
                    f"Queue finished: {result['completed']}/{result['total']} verified; "
                    f"{len(result['failed'])} failed"
                )
                self.progress_percent_label.set_text("")
                self.progress_indeterminate = False
                self.progress.set_fraction(result['completed'] / max(1, result['total']))
                summary = [f"Verified: {', '.join(result['installed']) or '(none)'}"]
                for pkg, err in result['failed'].items():
                    summary.append(f"FAILED {pkg}: {err}")
                self.set_log("\n".join(summary + self.queue_log_lines[-90:]))
                del self.queue_summary

        def queue_progress(self, event: dict):
            # Called only on GTK main thread via GLib.idle_add from worker.
            stage = event.get("stage", "prepare")
            package = event.get("package") or "Kali"
            number, total = event.get("index", 0), event.get("total", 0)
            message = str(event.get("message", ""))
            pct = event.get("percent")
            if stage == "log":
                if message.strip():
                    self.queue_log_lines.append(message[:300])
                    if len(self.queue_log_lines) > 150:
                        self.queue_log_lines = self.queue_log_lines[-150:]
                return False
            self.progress_revealer.set_reveal_child(True)
            self.progress_label.set_text(
                f"{number}/{total} · {package} · {stage.replace('-', ' ').title()}" +
                (f" · {message[:95]}" if message else "")
            )
            self.progress_indeterminate = pct is None
            if pct is None:
                self.progress_percent_label.set_text("Working…")
            else:
                pct = min(100.0, max(0.0, float(pct)))
                self.progress.set_fraction(pct / 100.0)
                self.progress_percent_label.set_text(f"{pct:.0f}% {stage}")
            if stage in {"complete", "already-installed", "error"}:
                self.queue_log_lines.append(f"{package}: {stage} {message[:200]}")
            return False

        def install_packages(self, packages: list[str]):
            if self.busy or not packages:
                return
            self.queue_log_lines = []
            self.set_log("")
            self.set_busy(True, f"Preparing {len(packages)} queued tool(s)")
            self.pulse()
            def worker():
                try:
                    result = service.install_many(
                        packages,
                        progress=lambda ev: GLib.idle_add(self.queue_progress, ev),
                    )
                    GLib.idle_add(self.queue_done, result, None)
                except Exception as exc:
                    GLib.idle_add(self.queue_done, None, exc)
            threading.Thread(target=worker, daemon=True).start()

        def queue_done(self, result, error):
            self.busy = False
            self.progress_indeterminate = False
            self.update_selection_controls()
            if error:
                self.progress_revealer.set_reveal_child(True)
                self.progress_label.set_text(f"Queue stopped: {error}")
                self.progress_percent_label.set_text("")
                self.set_log(str(error))
            else:
                self.queue_summary = result
                self.selected_packages.difference_update(result['installed'])
                self.update_selection_controls()
                # Always refresh actual dpkg states; retain queue summary in panel.
                self.refresh_all(preserve_operation=True)
            return False

        # ---------- package actions ----------
        def package_action(self, package: str, installed: bool, card: dict):
            if not card.get("available", True):
                self.run_action("Initializing Kali toolbox", service.init, lambda: self.refresh_all(refresh_tools=True))
                return
            if installed:
                self.run_action(f"Removing {package}", lambda: service.remove(package), self.refresh_all)
                return

            warning = str(card.get("warning") or "")
            weight = str(card.get("weight") or "")
            if warning or weight in {"very-large", "huge"}:
                dialog = Adw.MessageDialog(
                    transient_for=self.window,
                    heading=f"Install {card.get('title') or package}?",
                    body=(warning or "This collection may install a large number of packages.")
                    + "\n\nKali packages stay inside the isolated toolbox.",
                )
                dialog.add_response("cancel", "Cancel")
                dialog.add_response("install", "Install")
                dialog.set_response_appearance("install", Adw.ResponseAppearance.SUGGESTED)
                dialog.set_default_response("cancel")
                dialog.set_close_response("cancel")
                dialog.connect("response", lambda _d, response: self._confirmed_install(response, package))
                dialog.present()
            else:
                self.install_packages([package])

        def _confirmed_install(self, response: str, package: str):
            if response == "install":
                self.install_packages([package])

        def open_shell(self, *_args):
            self.run_action("Opening Kali shell", service.open_shell, None)

    return int(ToolHubApp().run(None))
