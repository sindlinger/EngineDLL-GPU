#!/usr/bin/env python3
"""Deploy GpuEngine.dll to multiple MT5 agent folders."""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def load_targets(file_path: Path) -> list[Path]:
    if not file_path.exists():
        raise FileNotFoundError(f"Targets file not found: {file_path}")

    targets: list[Path] = []
    for raw_line in file_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        targets.append(Path(line))
    return targets


def copy_dll(source: Path, target_root: Path) -> None:
    for dest in [target_root / "Libraries", target_root / "MQL5" / "Libraries"]:
        dest.mkdir(parents=True, exist_ok=True)
        dest_file = dest / "GpuEngine.dll"
        shutil.copy2(source, dest_file)
        print(f"  -> {dest_file}")


def main(argv: list[str] | None = None) -> int:
    script_root = Path(__file__).resolve().parent
    repo_root = script_root.parent

    parser = argparse.ArgumentParser(description="Deploy GpuEngine.dll to MT5 agents")
    parser.add_argument(
        "--source",
        default=repo_root / "bin" / "GpuEngine.dll",
        type=Path,
        help="Path to GpuEngine.dll (default: bin/GpuEngine.dll)",
    )
    parser.add_argument(
        "--targets",
        default=script_root / "targets.txt",
        type=Path,
        help="Targets list file (default: scripts/targets.txt)",
    )

    args = parser.parse_args(argv)

    source = args.source.resolve()
    if not source.exists():
        print(f"[ERROR] Source DLL not found: {source}", file=sys.stderr)
        return 1

    try:
        targets = load_targets(args.targets)
    except FileNotFoundError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    if not targets:
        print(f"[WARN] No targets found in {args.targets}. Nothing to do.")
        return 0

    print(f"Deploying {source} to {len(targets)} target(s)...")
    for target_root in targets:
        target_root = target_root.resolve()
        if not target_root.exists():
            print(f"[WARN] Target path not found: {target_root}")
            continue
        try:
            copy_dll(source, target_root)
        except Exception as exc:  # pylint: disable=broad-except
            print(f"[WARN] Failed to copy to {target_root}: {exc}")

    print("Deployment finished.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
