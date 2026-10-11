from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Iterable


@dataclass(frozen=True)
class Collection:
    package: str
    title: str
    category: str
    description: str
    weight: str = "standard"
    warning: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class PopularTool:
    package: str
    title: str
    category: str
    description: str
    icon: str

    def to_dict(self) -> dict:
        row = asdict(self)
        row.update({"popular": True, "installed": False, "available": True})
        return row


# Collections are deliberately secondary in v0.4.0. The primary catalog is
# dynamically discovered from Kali's kali-tools-* metapackages at runtime.
COLLECTIONS: tuple[Collection, ...] = (
    Collection("kali-tools-top10", "Kali Top 10", "Starter", "Kali's ten most prominent security tools."),
    Collection("kali-linux-headless", "Headless Default", "Starter", "Default command-line Kali toolset without a desktop environment.", "large"),
    Collection("kali-linux-default", "Kali Default", "Collections", "Toolset included with Kali's default official images.", "large"),
    Collection("kali-linux-large", "Kali Large", "Collections", "Extended Kali tool collection beyond the default set.", "very-large", "Downloads and installs many packages."),
    Collection("kali-linux-everything", "Kali Everything", "Collections", "Every Kali tool collection and additional tool package.", "huge", "Very large. Use only when you really want the full Kali toolset."),
    Collection("kali-tools-information-gathering", "Information Gathering", "Collections", "OSINT and information-gathering collection."),
    Collection("kali-tools-vulnerability", "Vulnerability Assessment", "Collections", "Vulnerability assessment collection."),
    Collection("kali-tools-web", "Web Applications", "Collections", "Web application assessment collection."),
    Collection("kali-tools-database", "Database", "Collections", "Database assessment collection."),
    Collection("kali-tools-passwords", "Passwords", "Collections", "Online and offline password-auditing collection.", "large"),
    Collection("kali-tools-wireless", "Wireless", "Collections", "Aggregate wireless collection covering Wi-Fi, Bluetooth, RFID and SDR."),
    Collection("kali-tools-reverse-engineering", "Reverse Engineering", "Collections", "Reverse engineering and binary-analysis collection.", "large"),
    Collection("kali-tools-exploitation", "Exploitation", "Collections", "Authorized exploitation-testing collection.", "large"),
    Collection("kali-tools-social-engineering", "Social Engineering", "Collections", "Social-engineering assessment collection."),
    Collection("kali-tools-sniffing-spoofing", "Sniffing & Spoofing", "Collections", "Packet inspection and spoofing-related collection."),
    Collection("kali-tools-post-exploitation", "Post Exploitation", "Collections", "Authorized post-exploitation collection.", "large"),
    Collection("kali-tools-forensics", "Forensics", "Collections", "Digital forensics collection.", "large"),
    Collection("kali-tools-reporting", "Reporting", "Collections", "Reporting and assessment-documentation collection."),
    Collection("kali-tools-identify", "Identify", "Collections", "Defensive identify-domain tools."),
    Collection("kali-tools-protect", "Protect", "Collections", "Defensive protect-domain tools."),
    Collection("kali-tools-detect", "Detect", "Collections", "Defensive detection tools."),
    Collection("kali-tools-respond", "Respond", "Collections", "Incident response and investigation collection."),
    Collection("kali-tools-recover", "Recover", "Collections", "Data and filesystem recovery collection."),
    Collection("kali-tools-crypto-stego", "Crypto & Steganography", "Collections", "Cryptography and steganography collection."),
    Collection("kali-tools-fuzzing", "Fuzzing", "Collections", "Protocol and application fuzzing collection."),
    Collection("kali-tools-gpu", "GPU", "Collections", "Tools that benefit from GPU acceleration."),
    Collection("kali-tools-hardware", "Hardware", "Collections", "Hardware hacking and embedded-device tools."),
    Collection("kali-tools-802-11", "802.11 / Wi-Fi", "Collections", "802.11 wireless assessment tools."),
    Collection("kali-tools-bluetooth", "Bluetooth", "Collections", "Bluetooth assessment tools."),
    Collection("kali-tools-rfid", "RFID", "Collections", "RFID assessment tools."),
    Collection("kali-tools-sdr", "Software Defined Radio", "Collections", "Software-defined radio tools."),
    Collection("kali-tools-voip", "VoIP", "Collections", "Voice-over-IP assessment tools."),
    Collection("kali-tools-windows-resources", "Windows Resources", "Collections", "Kali resources intended for Windows hosts."),
)

# These give the GUI a useful real-tool view before/during discovery, and give
# prominent Kali tools nicer names/icons. The full catalog is not hardcoded.
POPULAR_TOOLS: tuple[PopularTool, ...] = (
    PopularTool("wireshark", "Wireshark", "Sniffing & Spoofing", "Network protocol analyzer and packet inspection suite.", "network-wired-symbolic"),
    PopularTool("nmap", "Nmap", "Information Gathering", "Network discovery and security auditing utility.", "network-transmit-receive-symbolic"),
    PopularTool("metasploit-framework", "Metasploit Framework", "Exploitation", "Penetration-testing and exploit-development framework.", "security-high-symbolic"),
    PopularTool("burpsuite", "Burp Suite", "Web Applications", "Integrated platform for web application security testing.", "web-browser-symbolic"),
    PopularTool("sqlmap", "sqlmap", "Database", "Automated SQL injection and database assessment tool.", "server-database-symbolic"),
    PopularTool("hydra", "Hydra", "Passwords", "Parallel network login auditing tool.", "dialog-password-symbolic"),
    PopularTool("john", "John the Ripper", "Passwords", "Password hash auditing and recovery tool.", "dialog-password-symbolic"),
    PopularTool("hashcat", "Hashcat", "Passwords", "Password recovery and hash-auditing tool.", "applications-system-symbolic"),
    PopularTool("responder", "Responder", "Sniffing & Spoofing", "LLMNR/NBT-NS/mDNS analysis and responder utility for authorized labs.", "network-workgroup-symbolic"),
    PopularTool("netexec", "NetExec", "Post Exploitation", "Network service assessment and authorized post-exploitation utility.", "network-server-symbolic"),
    PopularTool("nikto", "Nikto", "Web Applications", "Web server assessment scanner.", "system-search-symbolic"),
    PopularTool("gobuster", "Gobuster", "Web Applications", "Directory, DNS and virtual-host enumeration utility.", "folder-saved-search-symbolic"),
    PopularTool("wfuzz", "Wfuzz", "Fuzzing", "Web application fuzzing and discovery tool.", "system-search-symbolic"),
    PopularTool("zaproxy", "OWASP ZAP", "Web Applications", "Web application testing proxy and scanner.", "web-browser-symbolic"),
    PopularTool("ghidra", "Ghidra", "Reverse Engineering", "Software reverse-engineering framework.", "applications-engineering-symbolic"),
    PopularTool("radare2", "radare2", "Reverse Engineering", "Reverse engineering framework and command-line toolkit.", "utilities-terminal-symbolic"),
    PopularTool("binwalk", "Binwalk", "Hardware", "Firmware and embedded-file analysis utility.", "drive-harddisk-symbolic"),
    PopularTool("autopsy", "Autopsy", "Forensics", "Digital forensics platform and graphical investigation interface.", "edit-find-symbolic"),
    PopularTool("maltego", "Maltego", "Information Gathering", "Graph-based information gathering and link analysis tool.", "system-users-symbolic"),
    PopularTool("tcpdump", "tcpdump", "Sniffing & Spoofing", "Command-line packet analyzer.", "network-wired-symbolic"),
    PopularTool("aircrack-ng", "Aircrack-ng", "Hardware & Radio", "Wireless network assessment suite.", "network-wireless-symbolic"),
)

# Maps Kali metapackages to user-facing categories. Wireless-specific tools are
# intentionally de-emphasized under Hardware & Radio instead of having several
# dedicated Wi-Fi sidebar sections.
META_CATEGORY: dict[str, str] = {
    "kali-tools-information-gathering": "Information Gathering",
    "kali-tools-vulnerability": "Vulnerability Assessment",
    "kali-tools-web": "Web Applications",
    "kali-tools-database": "Database",
    "kali-tools-passwords": "Passwords",
    "kali-tools-reverse-engineering": "Reverse Engineering",
    "kali-tools-exploitation": "Exploitation",
    "kali-tools-social-engineering": "Social Engineering",
    "kali-tools-sniffing-spoofing": "Sniffing & Spoofing",
    "kali-tools-post-exploitation": "Post Exploitation",
    "kali-tools-forensics": "Forensics",
    "kali-tools-reporting": "Reporting",
    "kali-tools-identify": "Identify",
    "kali-tools-protect": "Protect",
    "kali-tools-detect": "Detect",
    "kali-tools-respond": "Respond",
    "kali-tools-recover": "Recover",
    "kali-tools-crypto-stego": "Crypto & Steganography",
    "kali-tools-fuzzing": "Fuzzing",
    "kali-tools-hardware": "Hardware & Radio",
    "kali-tools-gpu": "Hardware & Radio",
    "kali-tools-802-11": "Hardware & Radio",
    "kali-tools-bluetooth": "Hardware & Radio",
    "kali-tools-rfid": "Hardware & Radio",
    "kali-tools-sdr": "Hardware & Radio",
    "kali-tools-wireless": "Hardware & Radio",
    "kali-tools-voip": "VoIP",
    "kali-tools-windows-resources": "Windows Resources",
    "kali-linux-core": "Kali Core",
    "kali-linux-headless": "Kali Headless",
    "kali-linux-default": "Kali Default",
    "kali-linux-large": "Kali Extended",
    "kali-tools-top10": "Popular",
    "kali-linux-everything": "Other Kali Tools",
}

CATEGORY_ICONS: dict[str, str] = {
    "Popular": "starred-symbolic",
    "Information Gathering": "system-search-symbolic",
    "Vulnerability Assessment": "security-medium-symbolic",
    "Web Applications": "web-browser-symbolic",
    "Database": "server-database-symbolic",
    "Passwords": "dialog-password-symbolic",
    "Reverse Engineering": "applications-engineering-symbolic",
    "Exploitation": "security-high-symbolic",
    "Social Engineering": "system-users-symbolic",
    "Sniffing & Spoofing": "network-wired-symbolic",
    "Post Exploitation": "network-server-symbolic",
    "Forensics": "edit-find-symbolic",
    "Reporting": "x-office-document-symbolic",
    "Identify": "system-search-symbolic",
    "Protect": "security-high-symbolic",
    "Detect": "security-medium-symbolic",
    "Respond": "dialog-warning-symbolic",
    "Recover": "drive-harddisk-symbolic",
    "Crypto & Steganography": "changes-prevent-symbolic",
    "Fuzzing": "applications-system-symbolic",
    "Hardware & Radio": "applications-engineering-symbolic",
    "VoIP": "call-start-symbolic",
    "Windows Resources": "computer-symbolic",
    "Kali Core": "utilities-terminal-symbolic",
    "Kali Headless": "utilities-terminal-symbolic",
    "Kali Default": "applications-system-symbolic",
    "Kali Extended": "package-x-generic-symbolic",
    "Other Kali Tools": "package-x-generic-symbolic",
}

# Hardware & Radio remains available through All Tools/search but is not given a
# dedicated primary-sidebar button, matching the requested less Wi-Fi-centric UI.
SIDEBAR_CATEGORY_ORDER: tuple[str, ...] = (
    "Popular",
    "Information Gathering",
    "Vulnerability Assessment",
    "Web Applications",
    "Database",
    "Passwords",
    "Exploitation",
    "Post Exploitation",
    "Sniffing & Spoofing",
    "Forensics",
    "Reverse Engineering",
    "Crypto & Steganography",
    "Fuzzing",
    "Social Engineering",
    "Identify",
    "Protect",
    "Detect",
    "Respond",
    "Recover",
    "Reporting",
    "VoIP",
    "Windows Resources",
    "Other Kali Tools",
)

POPULAR_BY_PACKAGE = {t.package: t for t in POPULAR_TOOLS}


def collections() -> list[dict]:
    return [item.to_dict() for item in COLLECTIONS]


def collection_categories() -> list[str]:
    return sorted({g.category for g in COLLECTIONS})


def get_collection(package: str) -> Collection | None:
    return next((g for g in COLLECTIONS if g.package == package), None)


def filter_collections(query: str = "", category: str = "") -> Iterable[Collection]:
    q = query.casefold().strip()
    cat = category.casefold().strip()
    for item in COLLECTIONS:
        if cat and item.category.casefold() != cat:
            continue
        haystack = " ".join((item.package, item.title, item.category, item.description)).casefold()
        if q and q not in haystack:
            continue
        yield item


def meta_category(meta: str) -> str:
    return META_CATEGORY.get(meta, "Other Kali Tools")


def collection_title(package: str) -> str:
    known = get_collection(package)
    if known:
        return known.title
    if package == "kali-tools-top10":
        return "Kali Top 10"
    if package.startswith("kali-tools-"):
        suffix = package.removeprefix("kali-tools-")
        special = {
            "802-11": "802.11 / Wi-Fi",
            "crypto-stego": "Crypto & Steganography",
            "sniffing-spoofing": "Sniffing & Spoofing",
            "post-exploitation": "Post Exploitation",
            "reverse-engineering": "Reverse Engineering",
            "information-gathering": "Information Gathering",
            "windows-resources": "Windows Resources",
            "social-engineering": "Social Engineering",
        }
        return special.get(suffix, suffix.replace("-", " ").title())
    special = {
        "kali-linux-core": "Kali Core",
        "kali-linux-headless": "Kali Headless",
        "kali-linux-default": "Kali Default",
        "kali-linux-large": "Kali Large",
        "kali-linux-everything": "Kali Everything",
    }
    return special.get(package, package.replace("-", " ").title())


def title_for(package: str) -> str:
    known = POPULAR_BY_PACKAGE.get(package)
    if known:
        return known.title
    return package.replace("-", " ").replace("_", " ").strip().title()


def icon_for(package: str, category: str) -> str:
    known = POPULAR_BY_PACKAGE.get(package)
    if known:
        return known.icon
    return CATEGORY_ICONS.get(category, "package-x-generic-symbolic")


def decorate_tool(package: str, description: str, categories: list[str], installed: bool = False) -> dict:
    unique_categories = sorted(set(categories)) or ["Other Kali Tools"]
    known = POPULAR_BY_PACKAGE.get(package)
    primary = known.category if known else unique_categories[0]
    return {
        "package": package,
        "title": title_for(package),
        "category": primary,
        "categories": unique_categories,
        "description": description or (known.description if known else "Kali security tool package."),
        "icon": icon_for(package, primary),
        "popular": package in POPULAR_BY_PACKAGE,
        "installed": installed,
        "available": True,
        "warning": "",
        "weight": "standard",
    }


# Backward-compatible aliases used by the v0.2 web UI/tests.
ToolGroup = Collection
TOOL_GROUPS = COLLECTIONS
categories = collection_categories
get_group = get_collection
filter_groups = filter_collections
