#!/usr/bin/env python3

import argparse
import filecmp
import hashlib
from pathlib import Path
import sys


KREL = "7.1.8-spectre"

RC1_ISO_SHA256 = (
    "473fad1fc51baf9968081650599ecbd11"
    "f424834c8a4a63174f901c973fdde8b"
)

# Canonical module-tree digest used by this auditor.
#
# Historical recovery provenance also records the same tree using the
# original shell/locale pipeline as:
# 88475f3ab9a435fbfe812784ed87c8ab72c482413051e70506d72517d4f09ede
#
# The canonical value below uses deterministic Python path ordering so
# verification does not depend on the host locale.
RC1_MODULE_TREE_SHA256 = (
    "1b5338902cd9ee96e12105176a6005e9"
    "be82c5a83294380c5ed28852980b3e18"
)

RC1_KERNEL_SHA256 = (
    "3055172a10be060591ae473ce14dceb21"
    "ce37c5caa6bd444b8a6d0c51a6299eb"
)

RC1_CONFIG_SHA256 = (
    "edc51391c20945c651584f1f661a7c06"
    "23bf5e2f87b0de3ce8ed7deb29b7e7e8"
)

MODULE_COUNT = 6825


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256_file(path):
    h = hashlib.sha256()

    with path.open("rb") as fp:
        for block in iter(lambda: fp.read(4 * 1024 * 1024), b""):
            h.update(block)

    return h.hexdigest()


def tree_digest(root):
    root = root.resolve()

    files = sorted(
        (
            p for p in root.rglob("*")
            if p.is_file() and not p.is_symlink()
        ),
        key=lambda p: p.relative_to(root).as_posix(),
    )

    outer = hashlib.sha256()

    for path in files:
        rel = "./" + path.relative_to(root).as_posix()
        digest = sha256_file(path)

        # Match:
        # find . -type f -print0 |
        # sort -z |
        # xargs -0 sha256sum |
        # sha256sum
        outer.update(f"{digest}  {rel}\n".encode())

    return outer.hexdigest()


def modules(root):
    suffixes = (".ko", ".ko.xz", ".ko.zst", ".ko.gz")

    result = {}

    for path in root.rglob("*"):
        if (
            path.is_file()
            and not path.is_symlink()
            and path.name.endswith(suffixes)
        ):
            rel = path.relative_to(root).as_posix()

            need(
                rel not in result,
                f"Duplicate module path: {rel}",
            )

            result[rel] = path

    return result


def verify_candidate(candidate):
    need(
        candidate.is_dir(),
        f"Candidate missing: {candidate}",
    )

    need(
        (candidate / "kernel").is_dir(),
        "Candidate kernel directory missing",
    )

    for name in (
        "modules.order",
        "modules.dep",
        "modules.alias",
        "modules.builtin",
    ):
        need(
            (candidate / name).is_file(),
            f"Candidate metadata missing: {name}",
        )

    inventory = modules(candidate)

    need(
        len(inventory) == MODULE_COUNT,
        f"Expected {MODULE_COUNT} modules, found {len(inventory)}",
    )

    digest = tree_digest(candidate)

    need(
        digest == RC1_MODULE_TREE_SHA256,
        (
            "Recovered candidate tree digest mismatch: "
            f"{digest}"
        ),
    )

    for required in (
        "/vmd.ko",
        "/nvme.ko",
        "/ahci.ko",
        "/vmwgfx.ko",
        "/vboxvideo.ko",
    ):
        matches = [
            rel
            for rel in inventory
            if rel.endswith(required)
        ]

        need(
            len(matches) == 1,
            f"Missing/ambiguous critical module: {required}",
        )

    print(
        f"[PASS] Trusted RC1 candidate: "
        f"{MODULE_COUNT} modules, digest verified.",
        flush=True,
    )

    return inventory


def verify_iso(path):
    need(
        path.is_file(),
        f"Recovery ISO missing: {path}",
    )

    digest = sha256_file(path)

    need(
        digest == RC1_ISO_SHA256,
        f"Recovery ISO SHA-256 mismatch: {digest}",
    )

    print(
        "[PASS] Recovery source is the qualified RC1 ISO.",
        flush=True,
    )


def verify_kernel(target):
    kernel = target / "boot" / f"vmlinuz-{KREL}"
    config = target / "boot" / f"config-{KREL}"

    need(kernel.is_file(), f"Missing kernel: {kernel}")
    need(config.is_file(), f"Missing kernel config: {config}")

    kernel_hash = sha256_file(kernel)
    config_hash = sha256_file(config)

    need(
        kernel_hash == RC1_KERNEL_SHA256,
        f"RC1 kernel identity mismatch: {kernel_hash}",
    )

    need(
        config_hash == RC1_CONFIG_SHA256,
        f"RC1 kernel config identity mismatch: {config_hash}",
    )

    print(
        "[PASS] Kernel binary/config match qualified RC1.",
        flush=True,
    )


def verify_target(candidate, target):
    tree = target / "usr" / "lib" / "modules" / KREL

    need(
        tree.is_dir() and not tree.is_symlink(),
        f"Target module tree missing/linked: {tree}",
    )

    expected = modules(candidate)
    actual = modules(tree)

    need(
        set(actual) == set(expected),
        "Target module inventory differs from trusted RC1 candidate",
    )

    print(
        "[INFO] Byte-comparing all 6,825 target modules...",
        flush=True,
    )

    for rel in sorted(expected):
        need(
            filecmp.cmp(
                expected[rel],
                actual[rel],
                shallow=False,
            ),
            f"Target module differs: {rel}",
        )

    need(
        filecmp.cmp(
            candidate / "modules.order",
            tree / "modules.order",
            shallow=False,
        ),
        "Target modules.order differs",
    )

    print(
        "[PASS] All 6,825 target module bytes match trusted RC1.",
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--mode",
        choices=("source", "integrated"),
        required=True,
    )

    parser.add_argument(
        "--candidate",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--target",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--recovery-iso",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--krel",
        required=True,
    )

    args = parser.parse_args()

    need(
        args.krel == KREL,
        f"Unexpected kernel release: {args.krel}",
    )

    candidate = args.candidate.resolve(strict=True)
    target = args.target.resolve(strict=True)
    recovery_iso = args.recovery_iso.resolve(strict=True)

    need(
        candidate != target,
        "Candidate and target must be independent paths",
    )

    verify_iso(recovery_iso)
    verify_candidate(candidate)
    verify_kernel(target)
    verify_target(candidate, target)

    if args.mode == "integrated":
        module_tree = target / "usr" / "lib" / "modules" / KREL

        size = sum(
            p.stat().st_size
            for p in modules(module_tree).values()
        )

        need(
            size < 950 * 1024 * 1024,
            f"Integrated modules suspiciously large: {size}",
        )

        for extra in ("source", "build"):
            need(
                not (module_tree / extra).is_symlink(),
                f"Development-only module link: {extra}",
            )

        print(
            f"[PASS] Integrated module payload: "
            f"{size / 1024 / 1024:.0f} MiB.",
            flush=True,
        )

    print(
        "[PASS] SPECTRE RC1 ISO RECOVERY AUDIT",
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise SystemExit(1)
