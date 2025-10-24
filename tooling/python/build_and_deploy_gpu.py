#!/usr/bin/env python3
"""Pipeline completo: compilar WaveSpecGPU e distribuir os binários.

Este utilitário foi pensado para rodar tanto no Windows quanto no WSL. Ele:

1. Executa o CMake (configure/build) para gerar os artefatos desejados;
2. Aciona o script ``deploy_gpu_binaries.py`` para copiar e verificar os
   binários em ``WaveSpecGPU/bin``, ``MQL5/Libraries`` e pastas Agent-*.

Use ``uv run`` ou o Python disponível no ambiente. Nenhuma dependência extra é
necessária; todas as saídas coloridas usam ANSI puro.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Sequence

SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]

# Permite rodar tanto a partir do repositório "MQL5" quanto de uma cópia
# localizada em "WaveSpecGPU". Se o repositório pai já for o projeto-alvo,
# usamos-o diretamente; caso contrário, assumimos que o projeto está em
# REPO_ROOT/WaveSpecGPU.
if (REPO_ROOT / "WaveSpecGPU").exists():
    PROJECT_ROOT = REPO_ROOT / "WaveSpecGPU"
else:
    PROJECT_ROOT = REPO_ROOT

BUILD_DIR = PROJECT_ROOT / "build"


class Ansi:
    BLUE = "\033[36m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    RESET = "\033[0m"


def info(msg: str) -> None:
    print(f"{Ansi.BLUE}[build]{Ansi.RESET} {msg}")


def success(msg: str) -> None:
    print(f"{Ansi.GREEN}{msg}{Ansi.RESET}")


def warn(msg: str) -> None:
    print(f"{Ansi.YELLOW}{msg}{Ansi.RESET}")


def error(msg: str) -> None:
    print(f"{Ansi.RED}{msg}{Ansi.RESET}", file=sys.stderr)


def run_cmd(cmd: Sequence[str], cwd: Path | None = None) -> None:
    info("Executando: " + " ".join(cmd))
    result = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
    if result.returncode != 0:
        raise RuntimeError(
            f"Comando {' '.join(cmd)} falhou (exit={result.returncode})."
        )


def ensure_project_structure() -> None:
    if not PROJECT_ROOT.exists():
        raise FileNotFoundError(
            f"Diretório WaveSpecGPU não encontrado em {PROJECT_ROOT}."
        )
    BUILD_DIR.mkdir(parents=True, exist_ok=True)


def cmake_configure(generator: str, toolset: str | None, defines: Iterable[str]) -> None:
    cmd: List[str] = [
        "cmake",
        "-S",
        str(PROJECT_ROOT),
        "-B",
        str(BUILD_DIR),
        "-G",
        generator,
    ]
    if toolset:
        cmd.extend(["-T", toolset])
    for definition in defines:
        cmd.extend(["-D", definition])
    run_cmd(cmd)


def cmake_build(configuration: str, target: str | None) -> None:
    cmd: List[str] = [
        "cmake",
        "--build",
        str(BUILD_DIR),
        "--config",
        configuration,
    ]
    if target:
        cmd.extend(["--target", target])
    run_cmd(cmd)


def deploy_binaries(
    configuration: str,
    skip_agents: bool,
    extra_targets: Sequence[Path],
) -> None:
    release_dir = PROJECT_ROOT / "bin" / configuration
    if not release_dir.exists():
        raise FileNotFoundError(
            f"Diretório de artefatos inexistente: {release_dir}."
        )

    # Importamos o módulo apenas aqui para evitar dependências circulares
    # caso este script seja reutilizado em outras automações.
    sys.path.insert(0, str(SCRIPT_PATH.parents[0]))
    import deploy_gpu_binaries  # noqa: WPS433, pylint: disable=import-error

    deploy_args: List[str] = ["--release-dir", str(release_dir)]
    if skip_agents:
        deploy_args.append("--skip-agents")
    for target in extra_targets:
        deploy_args.extend(["--targets", str(target)])

    info("Disparando deploy_gpu_binaries.py")
    exit_code = deploy_gpu_binaries.main(deploy_args)
    if exit_code != 0:
        raise RuntimeError(
            f"deploy_gpu_binaries retornou código {exit_code}. Verifique o log acima."
        )


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compila e distribui os binários GPU personalizados."
    )
    parser.add_argument(
        "--configuration",
        choices=("Release", "Debug"),
        default="Release",
        help="Configuração CMake a construir (default: Release)",
    )
    parser.add_argument(
        "--generator",
        default="Visual Studio 17 2022",
        help="Generator a ser utilizado pelo CMake (default Visual Studio 17 2022).",
    )
    parser.add_argument(
        "--toolset",
        help="Toolset opcional (ex.: v143, ClangCL).",
    )
    parser.add_argument(
        "--define",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Define adicional para passar ao CMake (pode repetir).",
    )
    parser.add_argument(
        "--target",
        help="Target específico a compilar (default: todos).",
    )
    parser.add_argument(
        "--skip-configure",
        action="store_true",
        help="Pula a etapa de configuração CMake (reusa cache existente).",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Não executa etapa de compilação; apenas deploy." ,
    )
    parser.add_argument(
        "--skip-deploy",
        action="store_true",
        help="Não roda o deploy após o build.",
    )
    parser.add_argument(
        "--skip-agents",
        action="store_true",
        help="Durante o deploy, não sincroniza as pastas Agent-*.",
    )
    parser.add_argument(
        "--extra-target",
        action="append",
        type=Path,
        default=[],
        help="Diretório adicional para receber as DLLs (pode repetir).",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Desativa sequências ANSI nas mensagens.",
    )
    return parser.parse_args(list(argv) if argv is not None else None)


def disable_colors() -> None:
    Ansi.BLUE = Ansi.GREEN = Ansi.YELLOW = Ansi.RED = Ansi.RESET = ""


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    if args.no_color or os.environ.get("NO_COLOR"):
        disable_colors()

    try:
        ensure_project_structure()

        if not args.skip_configure:
            info("Executando configuração do CMake")
            cmake_configure(args.generator, args.toolset, args.define)
        else:
            info("Pulando configuração (cache existente será reutilizado)")

        if not args.skip_build:
            info("Executando build")
            cmake_build(args.configuration, args.target)
        else:
            warn("Etapa de build ignorada por --skip-build; assumindo artefatos existentes")

        if not args.skip_deploy:
            deploy_binaries(args.configuration, args.skip_agents, args.extra_target)
        else:
            warn("Deploy não executado (--skip-deploy)")

    except FileNotFoundError as exc:
        error(str(exc))
        return 2
    except RuntimeError as exc:
        error(str(exc))
        return 3
    except KeyboardInterrupt:
        error("Execução interrompida pelo usuário.")
        return 130

    success("Pipeline concluído com sucesso.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
