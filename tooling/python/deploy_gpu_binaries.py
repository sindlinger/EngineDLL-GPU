#!/usr/bin/env python3
"""Distribui os binários GPU para todas as instâncias do MT5."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Sequence

try:
    from colorama import Fore, Style, init as colorama_init
except ImportError:  # pragma: no cover - fallback sem cores
    class _Dummy:
        RED = ""
        GREEN = ""
        YELLOW = ""
        CYAN = ""
        RESET_ALL = ""

    Fore = Style = _Dummy()  # type: ignore

    def colorama_init() -> None:  # type: ignore
        return


colorama_init()


SCRIPT_PATH = Path(__file__).resolve()
ROOT = SCRIPT_PATH.parents[2]

if (ROOT / "WaveSpecGPU").exists():
    PROJECT_ROOT = ROOT / "WaveSpecGPU"
else:
    PROJECT_ROOT = ROOT

CANONICAL_BIN = PROJECT_ROOT / "bin"
RELEASE_DIR = CANONICAL_BIN / "Release"
LIB_DIR = (
    PROJECT_ROOT.parent / "Libraries"
    if (PROJECT_ROOT.parent / "Libraries").exists()
    else PROJECT_ROOT / "Libraries"
)

CORE_BINARIES: Sequence[str] = (
    "GpuEngine.dll",
    "GpuEngineClient.dll",
    "GpuEngineService.exe",
)
CUDA_BINARIES: Sequence[str] = (
    "cufft64_12.dll",
    "cufftw64_12.dll",
    "cudart64_13.dll",
)
LIB_BINARIES: Sequence[str] = ("cudadevrt.lib",)

ALL_BIN_FILES: Sequence[str] = (*CORE_BINARIES, *CUDA_BINARIES, *LIB_BINARIES)


def samefile_or_false(path: Path, other: Path) -> bool:
    try:
        return path.exists() and other.exists() and os.path.samefile(path, other)
    except FileNotFoundError:
        return False
    except OSError:
        return False


def report_link(path: Path, label: str) -> None:
    if not path.exists():
        print(colored("skip", f"{label}: caminho ausente ({path}). Rode setup_junctions.ps1."))
        return
    if samefile_or_false(path, CANONICAL_BIN):
        print(colored("ok", f"{label}: ok -> {path}"))
    else:
        print(colored("error", f"{label}: não aponta para {CANONICAL_BIN} (atual: {path})"))


@dataclass
class CopyResult:
    destination: Path
    filename: str
    status: str
    message: str
    size: int | None = None
    mtime: float | None = None

    def summary(self) -> str:
        size_str = f" | {self.size} bytes" if self.size is not None else ""
        ts = (
            datetime.fromtimestamp(self.mtime).strftime("%Y-%m-%d %H:%M:%S")
            if self.mtime is not None
            else ""
        )
        ts_str = f" | {ts}" if ts else ""
        return f"{self.filename}{size_str}{ts_str}"


def colored(status: str, text: str) -> str:
    palette = {
        "ok": Fore.GREEN,
        "skip": Fore.YELLOW,
        "error": Fore.RED,
        "info": Fore.CYAN,
    }
    return f"{palette.get(status, '')}{text}{Style.RESET_ALL}"


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def copy_if_present(src: Path, dest: Path) -> CopyResult:
    ensure_dir(dest.parent)
    if not src.exists():
        return CopyResult(dest, src.name, "error", f"arquivo inexistente na origem: {src}")
    if src.resolve() == dest.resolve():
        stat = dest.stat()
        return CopyResult(dest, src.name, "skip", "já sincronizado", size=stat.st_size, mtime=stat.st_mtime)
    shutil.copy2(src, dest)
    stat = dest.stat()
    return CopyResult(dest, src.name, "ok", "copiado", size=stat.st_size, mtime=stat.st_mtime)


def sync_dir(source: Path, dest: Path, filenames: Sequence[str]) -> List[CopyResult]:
    results: List[CopyResult] = []
    for name in filenames:
        results.append(copy_if_present(source / name, dest / name))
    return results


def verify_dir(source: Path, dest: Path, filenames: Sequence[str]) -> List[CopyResult]:
    results: List[CopyResult] = []
    for name in filenames:
        src = source / name
        tgt = dest / name
        if not tgt.exists():
            results.append(CopyResult(tgt, name, "error", "arquivo ausente"))
            continue
        src_stat = src.stat()
        tgt_stat = tgt.stat()
        if src_stat.st_size != tgt_stat.st_size:
            results.append(
                CopyResult(
                    tgt,
                    name,
                    "error",
                    f"tamanho divergente (ref={src_stat.st_size}, dest={tgt_stat.st_size})",
                    size=tgt_stat.st_size,
                    mtime=tgt_stat.st_mtime,
                )
            )
            continue
        results.append(CopyResult(tgt, name, "ok", "ok", size=tgt_stat.st_size, mtime=tgt_stat.st_mtime))
    return results


def print_results(title: str, results: Iterable[CopyResult]) -> None:
    print(colored("info", f"\n== {title} =="))
    for result in results:
        text = f"{result.destination}: {result.summary()} -> {result.message}"
        print(colored(result.status, text))


def stage_release_into_bin(release_dir: Path) -> List[str]:
    staged: List[str] = []
    if not release_dir.exists():
        return staged
    ensure_dir(CANONICAL_BIN)
    for name in ALL_BIN_FILES:
        src = release_dir / name
        if src.exists():
            shutil.copy2(src, CANONICAL_BIN / name)
            staged.append(name)
    return staged


def default_agent_roots() -> Sequence[Path]:
    user = os.environ.get("USERNAME") or Path.home().name
    appdata = Path(os.environ.get("APPDATA", rf"C:\\Users\\{user}\\AppData\\Roaming"))
    return (
        Path(r"C:\\Program Files\\MetaTrader 5\\Tester"),
        Path(r"C:\\Program Files\\Dukascopy MetaTrader 5\\Tester"),
        appdata / "MetaQuotes" / "Tester" / "3CA1B4AB7DFED5C81B1C7F1007926D06",
        appdata / "MetaQuotes" / "Tester" / "D0E8209F77C8CF37AD8BF550E51FF075",
    )


def discover_agents(bases: Sequence[Path]) -> List[Path]:
    agents: List[Path] = []
    for base in bases:
        if not base.exists():
            continue
        for item in base.iterdir():
            if item.is_dir() and item.name.lower().startswith("agent-"):
                agents.append(item)
    return agents


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Replica binários GPU para pastas MT5.")
    parser.add_argument(
        "--release-dir",
        type=Path,
        default=RELEASE_DIR,
        help="Diretório com artefatos recém-compilados (default: bin/Release)",
    )
    parser.add_argument(
        "--targets",
        nargs="*",
        type=Path,
        help="Destinos adicionais (apenas com --force-copy)",
    )
    parser.add_argument(
        "--skip-agents",
        action="store_true",
        help="Não replica para instâncias Agent-*",
    )
    parser.add_argument(
        "--force-copy",
        action="store_true",
        help="Permite copiar binários para destinos físicos (uso legacy)",
    )
    return parser.parse_args(list(argv) if argv is not None else None)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)

    ensure_dir(CANONICAL_BIN)

    staged = stage_release_into_bin(args.release_dir.resolve())
    if staged:
        print(colored("info", f"Promovidos de bin/Release: {', '.join(staged)}"))
    elif not args.release_dir.exists():
        print(colored("info", "bin/Release não encontrado; usando conteúdo já presente em bin"))

    missing = [name for name in ALL_BIN_FILES if not (CANONICAL_BIN / name).exists()]
    if missing:
        print(colored("error", "Arquivos ausentes na pasta bin:"), file=sys.stderr)
        for name in missing:
            print(f" - {CANONICAL_BIN / name}", file=sys.stderr)
        return 3

    print(colored("info", f"Fonte canônica: {CANONICAL_BIN}"))

    if args.force_copy:
        lib_results = sync_dir(CANONICAL_BIN, LIB_DIR, ALL_BIN_FILES)
        print_results("MQL5/Libraries", lib_results)
        print_results("Verificação MQL5/Libraries", verify_dir(CANONICAL_BIN, LIB_DIR, ALL_BIN_FILES))

        for extra in args.targets or []:
            extra = extra.resolve()
            ensure_dir(extra)
            print_results(f"Destino extra: {extra}", sync_dir(CANONICAL_BIN, extra, ALL_BIN_FILES))
            print_results(f"Verificação extra: {extra}", verify_dir(CANONICAL_BIN, extra, ALL_BIN_FILES))

        if not args.skip_agents:
            agents = discover_agents(default_agent_roots())
            if agents:
                print(colored("info", f"Agentes detectados: {len(agents)}"))
                for agent in agents:
                    for target in (agent / "Libraries", agent / "MQL5" / "Libraries"):
                        ensure_dir(target)
                        print_results(f"Agent {agent.name} -> {target}", sync_dir(CANONICAL_BIN, target, ALL_BIN_FILES))
                        print_results(
                            f"Verificação {agent.name} -> {target}",
                            verify_dir(CANONICAL_BIN, target, ALL_BIN_FILES),
                        )
            else:
                print(colored("info", "Nenhum agent-* encontrado."))
    else:
        print(colored("info", "Modo link: nenhuma cópia realizada; verificando junctions."))
        report_link(LIB_DIR, "MQL5/Libraries")

        if args.targets:
            print(colored("skip", "Destinos extras ignorados (use --force-copy para copiar)."))

        if not args.skip_agents:
            agents = discover_agents(default_agent_roots())
            if agents:
                print(colored("info", f"Agentes detectados: {len(agents)}"))
                for agent in agents:
                    report_link(agent / "Libraries", f"{agent.name} \Libraries")
                    report_link(agent / "MQL5" / "Libraries", f"{agent.name} MQL5\Libraries")
            else:
                print(colored("info", "Nenhum agent-* encontrado."))
    print(colored("info", "Processo concluído."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
